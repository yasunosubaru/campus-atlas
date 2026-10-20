import 'calendar.dart';
import 'timetable_models.dart';

/// A class that has not finished yet, with its clock times resolved.
class ClassReminder {
  const ClassReminder({
    required this.course,
    required this.startsAt,
    required this.endsAt,
  });

  final Course course;
  final DateTime startsAt;
  final DateTime endsAt;

  Duration timeUntil(DateTime now) => startsAt.difference(now);

  bool isRunning(DateTime now) =>
      !startsAt.isAfter(now) && endsAt.isAfter(now);
}

/// The next class that has not ended yet, or null.
///
/// Only courses with a clock time can be reminded: an imported timetable
/// carries `08:00`-style times, a hand-entered course may not. Inventing a
/// period-to-clock table would put a confidently wrong time in front of someone
/// hurrying to class, so a course without a time is skipped rather than guessed.
///
/// [horizonDays] bounds the search: a week is enough to always find the next
/// meeting of a weekly course, and it keeps the answer meaningful when the
/// timetable holds stale weeks from a past term.
ClassReminder? nextClass({
  required DateTime now,
  required DateTime firstWeekStart,
  required List<Course> courses,
  int horizonDays = 7,
}) {
  final today = DateTime(now.year, now.month, now.day);

  for (var offset = 0; offset <= horizonDays; offset++) {
    final date = DateTime(today.year, today.month, today.day + offset);
    final dayCourses = coursesOnDate(courses, date, firstWeekStart);

    ClassReminder? best;
    for (final course in dayCourses) {
      final start = clockOn(date, course.startTime);
      if (start == null) continue;
      final end = clockOn(date, course.endTime) ??
          start.add(const Duration(minutes: 45));
      if (!end.isAfter(now)) continue;
      if (best == null || start.isBefore(best.startsAt)) {
        best = ClassReminder(course: course, startsAt: start, endsAt: end);
      }
    }
    // The first day that has anything left is by definition the earliest one;
    // a later day cannot hold an earlier class.
    if (best != null) return best;
  }
  return null;
}

/// [date] at [clock] (`HH:mm`), or null when [clock] is absent or unparsable.
DateTime? clockOn(DateTime date, String clock) {
  final minutes = parseClockMinutes(clock);
  if (minutes == null) return null;
  return DateTime(
    date.year,
    date.month,
    date.day,
    minutes ~/ 60,
    minutes % 60,
  );
}

/// Minutes after midnight for an `HH:mm` string, or null.
int? parseClockMinutes(String clock) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(clock.trim());
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  if (hour > 23 || minute > 59) return null;
  return hour * 60 + minute;
}

/// Parses `08:00-09:40` (also `~` or `–` as the separator) into the two clock
/// strings, normalising each to `HH:mm`.
({String start, String end})? parseClassTimeRange(String text) {
  final parts = text.trim().split(RegExp(r'[-–~—]'));
  if (parts.length != 2) return null;
  final start = _normaliseClock(parts[0]);
  final end = _normaliseClock(parts[1]);
  if (start == null || end == null) return null;
  if (parseClockMinutes(start)! >= parseClockMinutes(end)!) return null;
  return (start: start, end: end);
}

String? _normaliseClock(String raw) {
  final minutes = parseClockMinutes(raw);
  if (minutes == null) return null;
  final hour = (minutes ~/ 60).toString().padLeft(2, '0');
  final minute = (minutes % 60).toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// `08:00` for a date-time, for display.
String formatClock(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';
