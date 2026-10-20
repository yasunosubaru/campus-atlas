import 'package:campus_atlas/features/courses/conflict.dart';
import 'package:campus_atlas/features/courses/course_models.dart';
import 'package:campus_atlas/features/timetable/timetable_models.dart';
import 'package:flutter_test/flutter_test.dart';

MasterCourse _master({
  int day = 1,
  int start = 1,
  int end = 2,
  String weeks = '1-16',
}) =>
    MasterCourse(
      id: 1,
      name: '蹭课候选',
      dayOfWeek: day,
      startSection: start,
      endSection: end,
      weeks: weeks,
    );

Course _mine({
  int weekday = 1,
  int start = 1,
  int count = 2,
  Set<int> weeks = const {1, 2, 3},
}) =>
    Course(
      id: 'own',
      name: '我的课',
      weekday: weekday,
      startPeriod: start,
      periodCount: count,
      weeks: weeks,
    );

void main() {
  group('conflictWithMyTimetable', () {
    test('a different weekday never clashes', () {
      expect(
        conflictWithMyTimetable(_master(day: 2), [_mine(weekday: 1)]),
        ConflictStatus.free,
      );
    });

    test('adjacent period ranges do not clash', () {
      expect(
        conflictWithMyTimetable(
          _master(start: 7, end: 8),
          [_mine(start: 5, count: 2)],
        ),
        ConflictStatus.free,
      );
    });

    test('sharing a single boundary period is a clash', () {
      expect(
        conflictWithMyTimetable(
          _master(start: 5, end: 6),
          [_mine(start: 6, count: 2)],
        ),
        ConflictStatus.clash,
      );
    });

    test('the same day and periods on disjoint weeks do not clash', () {
      expect(
        conflictWithMyTimetable(
          _master(weeks: '1-4'),
          [
            _mine(weeks: {6, 7, 8})
          ],
        ),
        ConflictStatus.free,
      );
    });

    test('one shared week between otherwise separate ranges is a clash', () {
      expect(
        conflictWithMyTimetable(
          _master(weeks: '1-4,6'),
          [
            _mine(weeks: {5, 6})
          ],
        ),
        ConflictStatus.clash,
      );
    });

    test('an unparsable week expression is unknown when the rest overlaps', () {
      expect(
        conflictWithMyTimetable(_master(weeks: ''), [_mine()]),
        ConflictStatus.unknown,
      );
    });

    test('an unparsable week expression is still free without an overlap', () {
      expect(
        conflictWithMyTimetable(_master(day: 3, weeks: 'n/a'), [_mine()]),
        ConflictStatus.free,
      );
    });

    test('no local timetable means nothing can clash', () {
      expect(
        conflictWithMyTimetable(_master(), const <Course>[]),
        ConflictStatus.free,
      );
    });

    test('one clashing entry among many is enough', () {
      final mine = [
        _mine(weekday: 2),
        _mine(weekday: 3, start: 9),
        _mine(weekday: 1, start: 1, weeks: {2}),
      ];
      expect(conflictWithMyTimetable(_master(), mine), ConflictStatus.clash);
    });
  });
}
