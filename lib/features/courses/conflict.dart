import '../timetable/timetable_models.dart';
import 'course_models.dart';

/// How a master-timetable row relates to the user's own timetable — the
/// "蹭课匹配" question of whether the class can be attended without a clash.
enum ConflictStatus {
  /// Proven clash-free: no shared weekday, no shared period, or no shared week.
  free,

  /// Proven to clash on weekday, period and at least one teaching week.
  clash,

  /// The week expression could not be parsed, so a clash can be neither
  /// confirmed nor ruled out. A filter must drop these rather than present
  /// them as safe to attend.
  unknown,
}

/// Classifies [master] against every class in [mine].
///
/// Weekday and period ranges are compared first: when they cannot overlap, no
/// week expression can create a clash, so an unparsable [MasterCourse.weeks]
/// still yields [ConflictStatus.free] in that case. Weeks only matter once
/// weekday and periods already overlap.
ConflictStatus conflictWithMyTimetable(
  MasterCourse master,
  Iterable<Course> mine,
) {
  final overlapping = <Course>[];
  for (final course in mine) {
    if (course.weekday != master.dayOfWeek) continue;
    if (!_periodsOverlap(
      master.startSection,
      master.endSection,
      course.startPeriod,
      course.endPeriod,
    )) {
      continue;
    }
    overlapping.add(course);
  }
  if (overlapping.isEmpty) return ConflictStatus.free;

  final masterWeeks = parseWeeks(master.weeks).dataOrNull;
  if (masterWeeks == null) return ConflictStatus.unknown;

  for (final course in overlapping) {
    for (final week in course.weeks) {
      if (masterWeeks.contains(week)) return ConflictStatus.clash;
    }
  }
  return ConflictStatus.free;
}

/// True when `[aStart]-[aEnd]` intersects `[bStart]-[bEnd]`, endpoints
/// included: periods 5-6 and 6-7 do overlap because both meet on period 6.
bool _periodsOverlap(int aStart, int aEnd, int bStart, int bEnd) =>
    aStart <= bEnd && bStart <= aEnd;
