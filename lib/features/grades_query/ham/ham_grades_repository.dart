/// Reads 给分 through Ham's MCP service.
///
/// The chain, from public artefacts rather than from guesswork:
///
/// ```
/// this client ──MCP/JSON──→ mcp.ham.nowcent.cn
///                              │
///                              ├─ (Ham's own backend, not public)
///                              └─ per ham-gateway: gRPC → open-api.ham.nowcent.cn:4443
/// ```
///
/// What the tool is *called* is unknown — the backend is closed — so it is chosen
/// from `tools/list` by what it says it does, and its arguments are taken from the
/// tool's own input schema. A hardcoded identifier would fail silently the day the
/// server renames one, and the failure would look like a bad API key.
library;

import '../../../core/result.dart';
import 'ham_mcp_client.dart';
import 'ham_score_models.dart';

/// Which way a query is keyed.
///
/// The feature is described as "输入课程名**或授课人姓名**", so the caller has to
/// say which one it is typing — sending a teacher's name as a course name is
/// answered with zero results, which reads as "this teacher has no data".
enum HamScoreQueryKind {
  byCourse,
  byInstructor,
}

class HamGradesRepository {
  HamGradesRepository({required this.client});

  final HamMcpClient client;

  /// The tools the server offered on the last successful discovery.
  ///
  /// Kept for the diagnostics panel: when a query returns nothing, the first
  /// question is whether the right tool was even found.
  List<HamMcpTool> discoveredTools = const <HamMcpTool>[];

  /// The tool this repository chose to use.
  HamMcpTool? chosenTool;

  /// The last arguments actually sent.
  Map<String, Object?> lastArguments = const <String, Object?>{};

  /// Queries the score distribution.
  Future<Result<List<HamCourseScore>>> search({
    required String query,
    HamScoreQueryKind kind = HamScoreQueryKind.byCourse,
  }) async {
    final text = query.trim();
    if (text.isEmpty) {
      return Failure<List<HamCourseScore>>.reason(
        FailureKind.validation,
        message: kind == HamScoreQueryKind.byCourse ? '请输入课程名' : '请输入授课人姓名',
      );
    }

    final tools = await client.listTools();
    if (tools.isFailure) {
      return Failure<List<HamCourseScore>>(tools.errorOrNull!);
    }
    discoveredTools = tools.requireValue;

    final candidates =
        discoveredTools.where((t) => t.looksLikeScoreLookup).toList();
    if (candidates.isEmpty) {
      return Failure<List<HamCourseScore>>.reason(
        FailureKind.unsupported,
        message: 'Ham 没有提供与给分相关的工具。可用工具：'
            '${discoveredTools.map((t) => t.name).join(", ")}',
        endpoint: HamMcpClient.endpoint,
      );
    }

    // Rank by what the tool is *for*, not by whether its arguments happen to
    // mention a course.
    //
    // An earlier version scored candidates by argument names, and on the live
    // service that picked `get_course_detail` — whose Chinese description says
    // 「成绩统计」, so it passed the semantic filter — and then filled its
    // `course_table_id` with the course *name*. The query returned nothing and
    // looked like "no contributions".
    //
    // The right tool announces itself twice: it is named for grade stats, and it
    // takes a free-text `keyword` plus a `type` selector. Both are checked.
    candidates
        .sort((a, b) => _relevance(b, kind).compareTo(_relevance(a, kind)));

    final tool = candidates.first;
    chosenTool = tool;

    // ---- 1. exact query, with pagination -------------------------------------
    //
    // `next_cursor` is the only paging signal the service sends — there is no
    // `has_more`. A course with more teaching teams than one page would otherwise
    // look like a course with fewer of them.
    final exact = await _collect(tool, text, kind, maxPages: 3);
    if (exact.isFailure) {
      return Failure<List<HamCourseScore>>(exact.errorOrNull!);
    }
    if (exact.requireValue.isNotEmpty) return Success(exact.requireValue);

    // ---- 2. resolve the name, then ask again ---------------------------------
    //
    // Ham stores 高等数学 as 高等数学A…H, so a student typing the name they know
    // gets nothing back. The service has a lookup for exactly this, and its
    // `keyword_type` vocabulary is different from the stats tool's `type`:
    // only `all` matches a prefix, while `course_name` wants the full name.
    final resolved = await _resolve(text, kind);
    if (resolved.isEmpty) {
      return Failure<List<HamCourseScore>>.reason(
        FailureKind.invalidData,
        message: '没有找到「$text」对应的课程或教师，也没有给分记录。'
            '换一个更完整的名称试试。',
        endpoint: HamMcpClient.endpoint,
      );
    }

    final merged = <HamCourseScore>[];
    final tried = <String>[];
    for (final name in resolved.take(3)) {
      tried.add(name);
      final page = await _collect(tool, name, kind, maxPages: 1);
      if (page.isSuccess) merged.addAll(page.requireValue);
    }

    if (merged.isEmpty) {
      return Failure<List<HamCourseScore>>.reason(
        FailureKind.invalidData,
        message: '找到了「${tried.join("、")}」，但这些课程/教师还没有人贡献过成绩。',
        endpoint: HamMcpClient.endpoint,
      );
    }
    return Success(merged);
  }

  /// One tool call plus any further pages, as far as [maxPages].
  Future<Result<List<HamCourseScore>>> _collect(
    HamMcpTool tool,
    String query,
    HamScoreQueryKind kind, {
    required int maxPages,
  }) async {
    final out = <HamCourseScore>[];
    Object? cursor;

    for (var page = 0; page < maxPages; page++) {
      final args = _buildArguments(tool, query, kind);
      if (args.containsKey('cursor')) args['cursor'] = cursor;
      lastArguments = args;

      final missing = _missingRequired(tool, args);
      if (missing.isNotEmpty) {
        return Failure<List<HamCourseScore>>.reason(
          FailureKind.validation,
          message: '工具 ${tool.name} 需要这些参数，但当前查询填不了：'
              '${missing.join(", ")}。',
          endpoint: HamMcpClient.endpoint,
        );
      }

      final called = await client.callTool(tool.name, args);
      if (called.isFailure) {
        return Failure<List<HamCourseScore>>(called.errorOrNull!);
      }

      final payload = called.requireValue;
      out.addAll(HamCourseScore.listFrom(payload));

      // `next_cursor` is present only when there is another page.
      final next = payload is Map
          ? (payload['next_cursor'] ?? payload['nextCursor'])
          : null;
      if (next is! String || next.isEmpty) break;
      cursor = next;
    }

    return Success(out);
  }

  /// Exact course or instructor names for a fuzzy keyword.
  ///
  /// Returns the values the service itself would accept in the stats tool's
  /// `keyword`, which is what makes a second query possible at all.
  Future<List<String>> _resolve(String keyword, HamScoreQueryKind kind) async {
    HamMcpTool? lookup;
    for (final t in discoveredTools) {
      if (t.looksLikeCourseSearch) {
        lookup = t;
        break;
      }
    }
    if (lookup == null) return const <String>[];

    // `all` is the only value that matches a prefix. Asking the search tool for
    // `course_name` returns nothing for 高等数学 while `all` returns fifty hits.
    final args = _buildArguments(lookup, keyword, kind);
    for (final key in lookup.argumentNames) {
      if (key.toLowerCase().contains('keyword_type') ||
          key.toLowerCase() == 'type') {
        args[key] = 'all';
      }
    }

    final called = await client.callTool(lookup.name, args);
    if (called.isFailure) return const <String>[];

    final payload = called.requireValue;
    if (payload is! Map) return const <String>[];
    final hits = payload['hits'];
    if (hits is! List) return const <String>[];

    final wanted =
        kind == HamScoreQueryKind.byCourse ? 'course_name' : 'instructor_name';
    final out = <String>[];
    for (final h in hits) {
      if (h is! Map) continue;
      final type = '${h['type'] ?? ''}';
      final value = '${h['value'] ?? ''}'.trim();
      if (value.isEmpty) continue;
      if (type.isNotEmpty && type != wanted) continue;
      if (!out.contains(value)) out.add(value);
    }
    return out;
  }

  /// Fills the tool's own parameters from the query.
  ///
  /// Built from [HamMcpTool.argumentNames] rather than from guessed keys, so a
  /// renamed argument still works as long as it still means the same thing. The
  /// vocabulary below is taken from the **live** schemas, not invented:
  ///
  /// ```
  /// get_course_grade_stats      keyword, type(course_name|instructor_name),
  ///                             order(score_desc|total_desc|median_desc),
  ///                             cursor(null = first page)
  /// get_course_detail_by_match  course_name, instructor
  /// search_courses              keyword, keyword_type(all|course_name|instructor_name)
  /// ```
  Map<String, Object?> _buildArguments(
    HamMcpTool tool,
    String query,
    HamScoreQueryKind kind,
  ) {
    final args = <String, Object?>{};
    final byCourse = kind == HamScoreQueryKind.byCourse;

    for (final n in tool.argumentNames) {
      final lower = n.toLowerCase();

      // The text being searched for.
      if (lower == 'keyword' || lower == 'q' || lower == 'query') {
        args[n] = query;
        continue;
      }

      // Which field a keyword is matched against.
      //
      // Two different vocabularies, and conflating them broke the lookup:
      //   * the stats tool's `type`           → course_name | instructor_name
      //   * the search tool's `keyword_type`  → all | course_name | instructor_name
      // Only `all` matches a prefix, so asking the *search* tool for
      // `course_name` returns nothing for 高等数学 while `all` returns fifty hits.
      if (lower == 'keyword_type') {
        args[n] = 'all';
        continue;
      }
      if (lower == 'type') {
        args[n] = byCourse ? 'course_name' : 'instructor_name';
        continue;
      }

      // Sorting. `total_desc` lists the teaching team with the most marks first,
      // which is the representative answer — sorting by score would put the
      // smallest sample on top.
      if (lower == 'order') {
        args[n] = 'total_desc';
        continue;
      }

      // Pagination cursor. `null` means "first page", and the schema says so by
      // declaring the type as `["null","string"]`.
      if (lower == 'cursor') {
        args[n] = null;
        continue;
      }

      if (lower.contains('page_num') || lower.contains('pagenum')) {
        args[n] = 1;
        continue;
      }
      if (lower.contains('page_size') || lower.contains('pagesize')) {
        args[n] = 50;
        continue;
      }

      // Fields a tool takes directly rather than through keyword+type.
      if (lower.contains('course_name') || lower.contains('coursename')) {
        if (byCourse) args[n] = query;
        continue;
      }
      if (lower.contains('instructor') || lower.contains('teacher')) {
        if (!byCourse) args[n] = query;
        continue;
      }
    }

    // Nothing matched: send the single declared string parameter, because a tool
    // with exactly one required string is a search box whatever it is called —
    // but never an identifier.
    //
    // `course_table_id` is not a course name. Filling it with one produced a
    // query that returned nothing while looking exactly like "nobody has
    // contributed this course".
    if (args.isEmpty) {
      final props = tool.inputSchema['properties'];
      if (props is Map) {
        for (final n in tool.argumentNames) {
          final lower = n.toLowerCase();
          if (lower.endsWith('id') ||
              lower.endsWith('_id') ||
              lower.contains('idx') ||
              lower.contains('cursor')) {
            continue;
          }
          final schema = props[n];
          if (schema is Map && schema['type'] == 'string') {
            args[n] = query;
            break;
          }
        }
      }
    }

    return args;
  }

  /// How well a candidate tool answers the question being asked.
  ///
  /// Signals are weighted, and every one is checked against text the server
  /// itself wrote — never against a guessed identifier:
  ///
  ///   * named for grade statistics (`grade_stats`, `成绩统计列表`) — the strongest
  ///   * takes a free-text `keyword` plus a `type` selector — a search endpoint
  ///   * takes `course_name` and `instructor` together — an exact-pair lookup
  ///   * can actually be filled for [kind] — a tiebreaker, not a reason
  ///
  /// The last one alone is what went wrong before: `get_course_detail` takes a
  /// `course_table_id`, which mentions "course", and it outranked the tool that
  /// was actually named for grade statistics.
  static int _relevance(HamMcpTool tool, HamScoreQueryKind kind) {
    final text = '${tool.name} ${tool.description}'.toLowerCase();
    final args = tool.argumentNames.map((n) => n.toLowerCase()).toList();
    var score = 0;

    if (text.contains('grade_stats') ||
        text.contains('grade statistics') ||
        text.contains('成绩统计列表') ||
        text.contains('成绩统计')) {
      score += 5;
    }
    if (args.contains('keyword')) score += 3;
    if (args.contains('type') || args.contains('keyword_type')) score += 2;
    if (args.contains('course_name') && args.contains('instructor')) score += 2;

    // A tool that cannot be filled for this query is still a candidate, just a
    // worse one — the required-argument check reports the reason if it is picked.
    final byCourse = kind == HamScoreQueryKind.byCourse;
    if (byCourse &&
        (args.contains('keyword') || args.contains('course_name'))) {
      score += 1;
    }
    if (!byCourse &&
        (args.contains('keyword') || args.contains('instructor'))) {
      score += 1;
    }
    return score;
  }

  /// Required parameters left unfilled by [_buildArguments].
  ///
  /// An argument set to **null** counts as filled when its schema allows null:
  /// `cursor` is declared `["null","string"]` and null is the documented way to
  /// ask for the first page. Treating that as missing would refuse the exact call
  /// the service is asking for.
  static List<String> _missingRequired(
    HamMcpTool tool,
    Map<String, Object?> args,
  ) {
    final props = tool.inputSchema['properties'];
    final required = tool.inputSchema['required'];
    if (required is! List) return const <String>[];

    bool allowsNull(String key) {
      if (props is! Map) return false;
      final schema = props[key];
      if (schema is! Map) return false;
      final type = schema['type'];
      if (type == 'null') return true;
      return type is List && type.contains('null');
    }

    final missing = <String>[];
    for (final name in required) {
      final key = '$name';
      if (!args.containsKey(key)) {
        missing.add(key);
        continue;
      }
      final value = args[key];
      if (value == null) {
        if (!allowsNull(key)) missing.add(key);
        continue;
      }
      if ('$value'.trim().isEmpty) missing.add(key);
    }
    return missing;
  }
}
