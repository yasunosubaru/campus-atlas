import 'dart:convert';

import '../../../core/result.dart';
import '../../whu_auth/whu_endpoints.dart' show WhuTerm;
import '../timetable_models.dart';
import 'jwgl_timetable_parser.dart';

/// What one read of the rendered timetable page produced.
class JwglTimetablePage {
  const JwglTimetablePage({
    required this.courses,
    this.skipped = 0,
    this.problems = const [],
    this.year,
    this.term,
  });

  final List<Course> courses;

  /// Rows that could not be placed on the grid. Counted, never dropped
  /// silently.
  final int skipped;

  /// A few human-readable reasons, capped.
  final List<String> problems;

  /// The academic year the page was showing (`2026` for 2026-2027).
  ///
  /// It is read off the page rather than taken from the import sheet's own
  /// field: the person may have chosen a different year in the page, and the
  /// week anchor that follows the import has to match the courses that were
  /// actually read.
  final String? year;

  /// The term the page was showing.
  final WhuTerm? term;

  bool get isEmpty => courses.isEmpty;
}

/// Parses the rows the in-app browser scrapes from 正方's rendered N2151 list.
///
/// The data endpoint behind the page now answers an empty `kbList` unless the
/// person has just cleared the page's slider challenge. The rendered list is
/// the honest fallback: the person clears the challenge, the page draws the
/// table, and this parser turns the already-visible rows into the same
/// `kbList`-shaped maps [parseJwglTimetable] already understands.
///
/// The browser script runs synchronously and returns:
///
/// ```json
/// {"ok": true, "year": "2026", "term": "3",
///  "rows": [{"day": "星期一", "periods": "3-4",
///    "text": "大学物理A（下）周数：1-4周,6-16周上课地点：1区5-403教师：黄慧明…"}]}
/// ```
///
/// The course text is the page's flattened `innerText`; labels are the ones
/// the page itself prints (`周数：`, `上课地点：`, `教师：`). Anything that does
/// not carry a name and a week range is counted as skipped, never guessed.
Result<JwglTimetablePage> parseJwglTimetableList(Object? payload) {
  Object? decoded = payload;
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } on FormatException catch (e) {
      return Failure<JwglTimetablePage>.reason(
        FailureKind.invalidData,
        message: 'The timetable page answer was not JSON: ${e.message}',
        endpoint: 'N2151 (rendered list)',
      );
    }
  }
  if (decoded is! Map) {
    return Failure<JwglTimetablePage>.reason(
      FailureKind.invalidData,
      message: 'The timetable page answer was not a JSON object',
      endpoint: 'N2151 (rendered list)',
    );
  }

  if (decoded['ok'] != true && decoded['ok'] != 'true') {
    final reason = '${decoded['reason'] ?? ''}'.trim();
    return Failure<JwglTimetablePage>.reason(
      FailureKind.invalidData,
      message: reason.isEmpty
          ? 'The timetable page did not contain a readable list'
          : reason,
      endpoint: 'N2151 (rendered list)',
    );
  }

  final rawRows = decoded['rows'];
  if (rawRows is! List) {
    return Failure<JwglTimetablePage>.reason(
      FailureKind.invalidData,
      message: 'The timetable page answer carried no rows',
      endpoint: 'N2151 (rendered list)',
    );
  }

  final maps = <Map<String, Object?>>[];
  final problems = <String>[];
  var skipped = 0;

  for (final raw in rawRows) {
    if (raw is! Map) {
      skipped++;
      continue;
    }
    final row = <String, Object?>{
      for (final e in raw.entries) '${e.key}': e.value,
    };
    final day = '${row['day'] ?? ''}'.trim();
    final periods = '${row['periods'] ?? ''}'.trim();
    final text = '${row['text'] ?? ''}'.trim();
    if (day.isEmpty || periods.isEmpty || text.isEmpty) {
      skipped++;
      continue;
    }

    final kb = _kbRowFromText(day: day, periods: periods, text: text);
    if (kb == null) {
      skipped++;
      if (problems.length < 5) {
        problems.add('第 ${maps.length + skipped} 行：缺少课程名或周次');
      }
      continue;
    }
    maps.add(kb);
  }

  final parsed = parseJwglTimetable({'kbList': maps});
  final failure = parsed.errorOrNull;
  if (failure != null) return Failure<JwglTimetablePage>(failure);

  final result = parsed.requireValue;
  return Success<JwglTimetablePage>(
    JwglTimetablePage(
      courses: result.courses,
      skipped: result.skipped + skipped,
      problems: [...problems, ...result.problems].take(5).toList(),
      year: _yearOf(decoded),
      term: WhuTerm.fromCode('${decoded['term'] ?? ''}'.trim()),
    ),
  );
}

/// The page's own `xnm` value (`2026` for 2026-2027), when it has one.
String? _yearOf(Map<Object?, Object?> payload) {
  final raw = '${payload['year'] ?? ''}'.trim();
  if (raw.isEmpty) return null;
  return raw;
}

/// Flattens one page row into the keys [parseJwglTimetable] expects.
///
/// The page prints one course per row. Its text is split by the labels the page
/// itself uses; the name is whatever precedes the first `周数：`.
Map<String, Object?>? _kbRowFromText({
  required String day,
  required String periods,
  required String text,
}) {
  final weeksMatch = RegExp(
    r'周数\s*[：:]\s*(.*?)(?=\s*(?:上课地点|教师|教学班|选课备注|学分|重修标记|$))',
  ).firstMatch(text);
  if (weeksMatch == null) return null;
  final weeks = (weeksMatch.group(1) ?? '').trim();
  if (weeks.isEmpty) return null;

  var name = text.substring(0, weeksMatch.start).trim();
  // 正方 marks rescheduled slots with a leading 【调】 (and similar tags).
  name = name.replaceFirst(RegExp(r'^【[^】]*】\s*'), '').trim();
  if (name.isEmpty) return null;

  final locationMatch = RegExp(
    r'上课地点\s*[：:]\s*(.*?)(?=\s*(?:教师|教学班|选课备注|学分|重修标记|$))',
  ).firstMatch(text);
  var location = (locationMatch?.group(1) ?? '').trim();
  if (location == '未排地点' || location == '无') location = '';

  final teacherMatch = RegExp(
    r'教师\s*[：:]\s*(.*?)(?=\s*(?:教学班|选课备注|学分|重修标记|$))',
  ).firstMatch(text);
  final teacher = (teacherMatch?.group(1) ?? '').trim();

  return {
    'kcmc': name,
    'xqj': day,
    'jcs': periods,
    'zcd': weeks,
    'xm': teacher,
    'cdmc': location,
  };
}
