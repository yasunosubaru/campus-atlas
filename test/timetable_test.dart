import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/features/timetable/timetable_models.dart';
import 'package:campus_atlas/features/timetable/timetable_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseWeeks', () {
    test('parses a closed range', () {
      final r = parseWeeks('1-16');
      expect(r.isSuccess, isTrue);
      expect(r.requireValue.length, 16);
      expect(r.requireValue.contains(1), isTrue);
      expect(r.requireValue.contains(16), isTrue);
      expect(r.requireValue.contains(17), isFalse);
    });

    test('parses a comma list of individual weeks', () {
      final r = parseWeeks('3,5,7');
      expect(r.requireValue, {3, 5, 7});
    });

    test('parses a mixture of ranges and singles', () {
      final r = parseWeeks('1-8,10');
      expect(r.requireValue.length, 9);
      expect(r.requireValue.contains(9), isFalse);
      expect(r.requireValue.contains(10), isTrue);
    });

    test('tolerates whitespace between tokens', () {
      final r = parseWeeks(' 1 , 2 , 4-6 ');
      expect(r.requireValue, {1, 2, 4, 5, 6});
    });

    test('expands the odd keyword against the ceiling', () {
      final r = parseWeeks('odd', throughWeek: 10);
      expect(r.requireValue, {1, 3, 5, 7, 9});
    });

    test('expands the even keyword against the ceiling', () {
      final r = parseWeeks('even', throughWeek: 10);
      expect(r.requireValue, {2, 4, 6, 8, 10});
    });

    test('rejects an empty specification', () {
      final r = parseWeeks('   ');
      expect(r.isSuccess, isFalse);
      expect(r.errorOrNull?.kind, FailureKind.validation);
    });

    test('rejects a non-numeric token', () {
      final r = parseWeeks('one-four');
      expect(r.errorOrNull?.kind, FailureKind.validation);
    });

    test('rejects an inverted range', () {
      final r = parseWeeks('8-2');
      expect(r.errorOrNull?.kind, FailureKind.validation);
    });

    test('rejects a bare zero week', () {
      final r = parseWeeks('0');
      expect(r.errorOrNull?.kind, FailureKind.validation);
    });
  });

  group('formatWeeks', () {
    test('collapses a contiguous run to a range', () {
      expect(formatWeeks({for (var w = 1; w <= 16; w++) w}), '1-16');
    });

    test('keeps isolated weeks as singles', () {
      expect(formatWeeks({3, 5, 7}), '3,5,7');
    });

    test('emits a range followed by a single', () {
      expect(formatWeeks({1, 2, 3, 4, 5, 6, 7, 8, 10}), '1-8,10');
    });

    test('round-trips through parseWeeks', () {
      const specs = ['1-16', '3,5,7', '1-8,10', '2,4,6-9,15'];
      for (final spec in specs) {
        final parsed = parseWeeks(spec);
        expect(parsed.isSuccess, isTrue, reason: spec);
        expect(
          parseWeeks(formatWeeks(parsed.requireValue)).requireValue,
          parsed.requireValue,
          reason: 'round trip failed for $spec',
        );
      }
    });

    test('returns empty for an empty set', () {
      expect(formatWeeks(<int>{}), '');
    });
  });

  group('Course', () {
    Course sample() => const Course(
          id: 'c1',
          name: 'Linear Algebra',
          weekday: 3,
          startPeriod: 3,
          periodCount: 2,
          weeks: {1, 2, 3, 4},
          teacher: 'Wang',
          location: 'Room 101',
        );

    test('endPeriod is the last period covered', () {
      expect(sample().endPeriod, 4);
    });

    test('occursInWeek respects the stored week set', () {
      final c = sample();
      expect(c.occursInWeek(1), isTrue);
      expect(c.occursInWeek(4), isTrue);
      expect(c.occursInWeek(5), isFalse);
    });

    test('JSON round-trip preserves every field', () {
      final c = sample();
      final parsed = Course.fromJson(c.toJson());
      expect(parsed.isSuccess, isTrue);
      expect(parsed.requireValue, c);
    });

    test('fromJson rejects a payload with wrong field types', () {
      final parsed = Course.fromJson(const {'id': 1, 'name': 'x'});
      expect(parsed.isSuccess, isFalse);
      expect(parsed.errorOrNull?.kind, FailureKind.invalidData);
    });
  });

  group('weekNumberFor', () {
    final termStart = DateTime(2026, 2, 23); // a Monday

    test('the term start date is week 1', () {
      expect(weekNumberFor(DateTime(2026, 2, 23), termStart), 1);
    });

    test('the last day of week 1 is still week 1', () {
      expect(weekNumberFor(DateTime(2026, 3, 1), termStart), 1);
    });

    test('the first day of week 2 is week 2', () {
      expect(weekNumberFor(DateTime(2026, 3, 2), termStart), 2);
    });

    test('week 8 starts seven weeks in', () {
      expect(weekNumberFor(DateTime(2026, 4, 13), termStart), 8);
    });

    test('dates before the term report week 0, never a negative', () {
      expect(weekNumberFor(DateTime(2026, 2, 20), termStart), 0);
    });

    test('ignores the time of day', () {
      expect(
        weekNumberFor(DateTime(2026, 3, 2, 23, 59), termStart),
        2,
      );
    });
  });

  group('isoWeekday', () {
    test('is 1 for Monday and 7 for Sunday', () {
      expect(isoWeekday(DateTime(2026, 3, 2)), 1); // Monday
      expect(isoWeekday(DateTime(2026, 3, 8)), 7); // Sunday
    });
  });
}
