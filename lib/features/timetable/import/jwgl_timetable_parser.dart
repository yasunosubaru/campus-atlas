import 'dart:convert';

import '../../../core/result.dart';
import '../../whu_auth/whu_endpoints.dart' show JwglOrigin;
import '../reminders.dart' show parseClockMinutes;
import '../timetable_models.dart';

/// One import's result: what was understood, and what was not.
class TimetableImport {
  const TimetableImport({
    required this.courses,
    this.skipped = 0,
    this.problems = const [],
  });

  final List<Course> courses;

  /// Rows that could not be placed on the grid (missing name, weekday, periods
  /// or weeks). Counted rather than silently dropped.
  final int skipped;

  /// A few human-readable reasons, capped so a broken response cannot flood the
  /// screen.
  final List<String> problems;

  bool get isEmpty => courses.isEmpty;
}

/// Parses the 正方教务 N2151 timetable answer.
///
/// ## Where the shape comes from
///
/// `POST /kbcx/xskbcx_cxXsKb.html?gnmkdm=N2151` with `xnm` (academic year) and
/// `xqm` (term code) answers with a JSON object whose `kbList` is one row per
/// scheduled meeting:
///
/// ```json
/// {"kbList":[{"kcmc":"高等数学A1","xqj":"1","jcs":"1-2节","zcd":"1-16周",
///             "xm":"张三","cdmc":"教五-101","qsjsj":"08:00","jssj":"09:40"}]}
/// ```
///
/// That is 正方's documented convention, **not** a response captured from this
/// deployment — no live session was available when this was written. The parser
/// is therefore tolerant on purpose: aliases are accepted, and anything it
/// cannot place is counted as skipped instead of being guessed at. A real
/// capture should tighten these aliases rather than widen them further.
///
/// ## Why rows are merged
///
/// 正方 lists one course once per week range — `1-8周` and `9-16周` arrive as two
/// rows in the same slot. The weekly grid positions a block by weekday and
/// period only, so two rows would draw on top of each other. Rows that agree on
/// course, slot, teacher and room are merged with the **union** of their weeks,
/// which is exactly what the two rows mean.
Result<TimetableImport> parseJwglTimetable(Object? payload) {
  Object? decoded = payload;
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } on FormatException catch (e) {
      return Failure<TimetableImport>.reason(
        FailureKind.invalidData,
        message: 'The timetable answer was not JSON: ${e.message}',
        endpoint: JwglOrigin.timetableData,
      );
    }
  }
  if (decoded is! Map) {
    return Failure<TimetableImport>.reason(
      FailureKind.invalidData,
      message: 'The timetable answer was not a JSON object',
      endpoint: JwglOrigin.timetableData,
    );
  }

  final rows = _rowsOf(decoded);
  if (rows == null) {
    return Failure<TimetableImport>.reason(
      FailureKind.invalidData,
      message: 'The answer has no kbList array — this is probably not the '
          'timetable endpoint, or the session is not valid',
      endpoint: JwglOrigin.timetableData,
    );
  }

  final problems = <String>[];
  var skipped = 0;
  final merged = <String, Course>{};

  for (var index = 0; index < rows.length; index++) {
    final row = rows[index];
    if (row is! Map) {
      skipped++;
      continue;
    }
    final parsed = _courseFromRow(Map<String, Object?>.from(row));
    if (parsed == null) {
      skipped++;
      if (problems.length < 5) {
        problems.add('第 ${index + 1} 行：缺少课程名、星期、节次或周次');
      }
      continue;
    }

    final key = [
      parsed.name,
      parsed.weekday,
      parsed.startPeriod,
      parsed.periodCount,
      parsed.teacher,
      parsed.location,
    ].join('|');
    final existing = merged[key];
    merged[key] = existing == null
        ? parsed
        : existing.copyWith(weeks: {...existing.weeks, ...parsed.weeks});
  }

  final courses = merged.values.toList()
    ..sort((a, b) {
      final byDay = a.weekday.compareTo(b.weekday);
      if (byDay != 0) return byDay;
      final byPeriod = a.startPeriod.compareTo(b.startPeriod);
      if (byPeriod != 0) return byPeriod;
      return a.name.compareTo(b.name);
    });

  return Success(
    TimetableImport(courses: courses, skipped: skipped, problems: problems),
  );
}

List<Object?>? _rowsOf(Map<Object?, Object?> payload) {
  final list = payload['kbList'] ?? payload['kbList'.toLowerCase()];
  if (list is List) return list;
  // Some wrappers put the payload under `data`.
  final data = payload['data'];
  if (data is List) return data;
  if (data is Map && data['kbList'] is List) {
    return data['kbList'] as List;
  }
  return null;
}

Course? _courseFromRow(Map<String, Object?> row) {
  final name = _text(row, const ['kcmc', 'courseName', 'kcmc']);
  if (name.isEmpty) return null;

  final weekday = parseJwglWeekday(row['xqj'] ?? row['weekday']);
  if (weekday == null) return null;

  final periods = parseJwglPeriods(
    _text(row, const ['jcs', 'jc', 'periods', 'jcor']),
  );
  if (periods == null) return null;

  final weeks = parseJwglWeeks(_text(row, const ['zcd', 'weeks', 'zcmc']));
  if (weeks == null || weeks.isEmpty) return null;

  final startTime = _clock(_text(row, const ['qsjsj', 'startTime']));
  final endTime = _clock(_text(row, const ['jssj', 'endTime']));

  return Course(
    id: 'j${_stableHash('$name|$weekday|${periods.start}'
        '|${periods.count}|${_text(row, const ['xm', 'jsxm'])}'
        '|${_text(row, const ['cdmc', 'jxdd', 'location'])}')}',
    name: name,
    weekday: weekday,
    startPeriod: periods.start,
    periodCount: periods.count,
    weeks: weeks,
    teacher: _text(row, const ['xm', 'jsxm', 'teacher']),
    location: _text(row, const ['cdmc', 'jxdd', 'location']),
    startTime: startTime,
    endTime: endTime,
  );
}

String _text(Map<String, Object?> row, List<String> keys) {
  for (final key in keys) {
    final value = row[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is num) return '$value';
  }
  return '';
}

/// `08:00` from `08:00`, `8:00` or `08:00:00`; empty when unparsable.
String _clock(String raw) {
  final minutes = parseClockMinutes(raw.split(':').take(2).join(':'));
  if (minutes == null) return '';
  final hour = (minutes ~/ 60).toString().padLeft(2, '0');
  final minute = (minutes % 60).toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// 1 = Monday … 7 = Sunday, from `1`..`7` or `星期一`/`周一`/`一`.
int? parseJwglWeekday(Object? raw) {
  final text = '$raw'.trim();
  if (text.isEmpty) return null;

  final number = int.tryParse(text);
  if (number != null) return number >= 1 && number <= 7 ? number : null;

  const numerals = '一二三四五六日';
  for (var i = 0; i < numerals.length; i++) {
    if (text.contains(numerals[i])) return i + 1;
  }
  if (text.contains('天')) return 7;
  return null;
}

/// `1-2节` → start 1, count 2. Null when no period numbers are present.
({int start, int count})? parseJwglPeriods(String raw) {
  final numbers = RegExp(r'\d+')
      .allMatches(raw)
      .map((m) => int.parse(m.group(0)!))
      .toList();
  if (numbers.isEmpty) return null;
  final start = numbers.first;
  final end = numbers.length > 1 ? numbers[1] : numbers.first;
  if (start < 1 || end < start) return null;
  return (start: start, count: end - start + 1);
}

/// `1-16周` / `1-15周(单)` / `1-8周,10-16周` / `1-16周(双)` → week set.
///
/// Null when nothing parses. A token like `1-16周(单双)` (both parities) is read
/// as every week, which is what it means.
Set<int>? parseJwglWeeks(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;

  text = text
      .replaceAll('周', ' ')
      .replaceAll('，', ',')
      .replaceAll('、', ',')
      .replaceAll('；', ',')
      .replaceAll(';', ',');

  final weeks = <int>{};
  var understood = false;

  for (var token in text.split(',')) {
    token = token.trim();
    if (token.isEmpty) continue;

    final odd = token.contains('单');
    final even = token.contains('双');
    // Drop the parity marker and any parentheses so the numbers stand alone.
    token = token
        .replaceAll(RegExp(r'[（(][^)）]*[)）]'), '')
        .replaceAll('单', '')
        .replaceAll('双', '')
        .replaceAll('第', '')
        .replaceAll('节', '')
        .trim();

    final range = RegExp(r'^(\d+)\s*[-~—]\s*(\d+)$').firstMatch(token);
    if (range != null) {
      final from = int.parse(range.group(1)!);
      final to = int.parse(range.group(2)!);
      if (from < 1 || to < from) return null;
      for (var week = from; week <= to; week++) {
        if (odd && !even && week.isEven) continue;
        if (even && !odd && week.isOdd) continue;
        weeks.add(week);
      }
      understood = true;
      continue;
    }

    final single = int.tryParse(token);
    if (single == null || single < 1) return null;
    if (odd && !even && single.isEven) continue;
    if (even && !odd && single.isOdd) continue;
    weeks.add(single);
    understood = true;
  }

  if (!understood || weeks.isEmpty) return null;
  return weeks;
}

/// A stable 32-bit hash, so an imported course keeps the same id between runs.
/// `String.hashCode` is not guaranteed stable across Dart versions.
int _stableHash(String text) {
  var hash = 2166136261;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 16777619) & 0xFFFFFFFF;
  }
  return hash;
}
