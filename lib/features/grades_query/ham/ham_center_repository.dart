/// Reads the account-level Ham data (profile, rank, want list, comments,
/// semester statistics) through the same MCP service the 给分 screen uses.
///
/// ## Why a gateway interface
///
/// The tools are called through a one-method seam so the parsing can be tested
/// without a token or a network. [HamMcpGateway] is the production adapter; a
/// test implements [HamToolGateway] with fixture payloads.
///
/// ## What is deliberately not here
///
/// `get_course_detail` and `get_course_detail_by_match` answered
/// `isError: true / 请重新登录` on 2026-10-20 with a valid 30-day token, while
/// every read below answered. They are not called: the course sheet composes
/// what works (statistics + comments + semester statistics) instead of building
/// on a tool that needs a web login.
///
/// The want-list **writes** (`create_course_want` / `remove_course_want`) are
/// also absent. Their arguments are known but their response and their login
/// requirements are not, and a write is not something to guess at.
library;

import '../../../core/result.dart';
import 'ham_center_models.dart';
import 'ham_mcp_client.dart';

/// The two MCP operations this feature needs, as an interface.
abstract class HamToolGateway {
  Future<Result<List<HamMcpTool>>> listTools();

  Future<Result<Object?>> call(
    String name, [
    Map<String, Object?> arguments = const {},
  ]);

  void close();
}

/// Production adapter over [HamMcpClient].
class HamMcpGateway implements HamToolGateway {
  HamMcpGateway(this._client);

  final HamMcpClient _client;

  @override
  Future<Result<List<HamMcpTool>>> listTools() => _client.listTools();

  @override
  Future<Result<Object?>> call(
    String name, [
    Map<String, Object?> arguments = const {},
  ]) =>
      _client.callTool(name, arguments);

  @override
  void close() => _client.close();
}

/// Account-level reads, parsed into models.
class HamCenterRepository {
  HamCenterRepository({required this.gateway});

  final HamToolGateway gateway;

  List<HamMcpTool> _tools = const [];

  void close() => gateway.close();

  /// The authenticated user's nickname and avatar.
  Future<Result<HamUserInfo>> userInfo() async {
    final payload = await _call('get_user_info', const {});
    if (payload is Failure<Map<String, Object?>>) {
      return Failure<HamUserInfo>(payload.errorOrNull!);
    }
    final info = HamUserInfo.tryParse(payload.requireValue);
    if (info == null) {
      return Failure<HamUserInfo>.reason(
        FailureKind.invalidData,
        message: 'Ham 的用户信息里没有昵称。',
        endpoint: HamMcpClient.endpoint,
      );
    }
    return Success(info);
  }

  /// One page of comments on a course.
  Future<Result<HamCommentPage>> comments(
    String courseTableId, {
    String? cursor,
  }) async {
    final id = courseTableId.trim();
    if (id.isEmpty) {
      return Failure<HamCommentPage>.reason(
        FailureKind.validation,
        message: '缺少课程标识（course_table_id），无法读取评论。',
        endpoint: HamMcpClient.endpoint,
      );
    }
    final payload = await _call('get_course_comments', {
      'course_table_id': id,
      'cursor': cursor,
    });
    if (payload is Failure<Map<String, Object?>>) {
      return Failure<HamCommentPage>(payload.errorOrNull!);
    }
    return Success(HamCommentPage.from(payload.requireValue));
  }

  /// One page of the user's own comments.
  Future<Result<HamCommentPage>> myComments({String? cursor}) async {
    final payload = await _call('get_my_comments', {'cursor': cursor});
    if (payload is Failure<Map<String, Object?>>) {
      return Failure<HamCommentPage>(payload.errorOrNull!);
    }
    return Success(HamCommentPage.from(payload.requireValue));
  }

  /// One course's statistics for one term.
  Future<Result<HamSemesterStat>> semesterStat({
    required String courseTableId,
    required int year,
    required int semester,
  }) async {
    final id = courseTableId.trim();
    if (id.isEmpty) {
      return Failure<HamSemesterStat>.reason(
        FailureKind.validation,
        message: '缺少课程标识（course_table_id），无法读取学期统计。',
        endpoint: HamMcpClient.endpoint,
      );
    }
    final payload = await _call('get_semester_grade_stats', {
      'course_table_id': id,
      'year': year,
      'semester': semester,
    });
    if (payload is Failure<Map<String, Object?>>) {
      return Failure<HamSemesterStat>(payload.errorOrNull!);
    }
    final stat = HamSemesterStat.tryParse(payload.requireValue);
    if (stat == null) {
      return Failure<HamSemesterStat>.reason(
        FailureKind.invalidData,
        message: '学期统计缺少学年或学期字段。',
        endpoint: HamMcpClient.endpoint,
      );
    }
    return Success(stat);
  }

  /// The user's score-rank entries.
  ///
  /// The item shape was empty on the capturing account, so the section keeps
  /// loose records rather than pretending to know the fields.
  Future<Result<HamLooseSection>> scoreRank({String? cursor}) =>
      _section('get_score_rank', const ['rank_items'], cursor: cursor);

  /// The user's want-to-take list. Same caveat as [scoreRank] for the items.
  Future<Result<HamLooseSection>> wantList({String? cursor}) =>
      _section('get_course_want_list', const ['items'], cursor: cursor);

  // ------------------------------------------------------------------ plumbing

  Future<Result<HamLooseSection>> _section(
    String toolName,
    List<String> itemKeys, {
    String? cursor,
  }) async {
    final payload = await _call(toolName, {'cursor': cursor});
    if (payload is Failure<Map<String, Object?>>) {
      return Failure<HamLooseSection>(payload.errorOrNull!);
    }
    return Success(
      HamLooseSection.from(payload.requireValue, itemKeys: itemKeys),
    );
  }

  Future<Result<Map<String, Object?>>> _call(
    String name,
    Map<String, Object?> wanted,
  ) async {
    final tool = await _find(name);
    if (tool is Failure<HamMcpTool>) {
      return Failure<Map<String, Object?>>(tool.errorOrNull!);
    }
    final chosen = tool.requireValue;

    // Fill the tool's own argument names from what the caller knows. Using the
    // schema's spelling rather than hardcoded keys keeps a renamed argument
    // working as long as it still means the same thing.
    final args = <String, Object?>{};
    for (final key in chosen.argumentNames) {
      final lower = key.toLowerCase();
      if (wanted.containsKey(lower)) args[key] = wanted[lower];
    }

    final required = chosen.inputSchema['required'];
    final missing = <String>[];
    if (required is List) {
      for (final key in required) {
        if (key is String && !args.containsKey(key)) missing.add(key);
      }
    }
    if (missing.isNotEmpty) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.validation,
        message: '工具 ${chosen.name} 需要这些参数，但当前查询填不了：'
            '${missing.join(", ")}。',
        endpoint: HamMcpClient.endpoint,
      );
    }

    final called = await gateway.call(chosen.name, args);
    if (called is Failure<Object?>) {
      return Failure<Map<String, Object?>>(called.errorOrNull!);
    }
    final payload = called.requireValue;
    if (payload is! Map) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.invalidData,
        message: '工具 ${chosen.name} 的响应不是 JSON 对象。',
        endpoint: HamMcpClient.endpoint,
      );
    }
    return Success(Map<String, Object?>.from(payload));
  }

  Future<Result<HamMcpTool>> _find(String name) async {
    if (_tools.isEmpty) {
      final listed = await gateway.listTools();
      if (listed is Failure<List<HamMcpTool>>) {
        return Failure<HamMcpTool>(listed.errorOrNull!);
      }
      _tools = listed.requireValue;
    }

    for (final tool in _tools) {
      if (tool.name == name) return Success(tool);
    }
    for (final tool in _tools) {
      if (tool.name.toLowerCase().contains(name.toLowerCase())) {
        return Success(tool);
      }
    }
    return Failure<HamMcpTool>.reason(
      FailureKind.unsupported,
      message: 'Ham 没有提供 $name。可用工具：'
          '${_tools.map((t) => t.name).join(", ")}',
      endpoint: HamMcpClient.endpoint,
    );
  }
}
