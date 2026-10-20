import 'package:campus_atlas/features/agenda/agenda_repository.dart';
import 'package:campus_atlas/features/timetable/calendar.dart';
import 'package:campus_atlas/features/timetable/reminders.dart';
import 'package:campus_atlas/features/timetable/timetable_models.dart';
import 'package:flutter_test/flutter_test.dart';

Course course({
  String id = 'c1',
  String name = '高等数学',
  int weekday = 1,
  int start = 1,
  int count = 2,
  Set<int> weeks = const {1, 2, 3, 4},
  String startTime = '08:00',
  String endTime = '09:40',
}) =>
    Course(
      id: id,
      name: name,
      weekday: weekday,
      startPeriod: start,
      periodCount: count,
      weeks: weeks,
      startTime: startTime,
      endTime: endTime,
    );

void main() {
  final termStart = DateTime(2026, 9, 7); // a Monday

  group('monthGrid', () {
    test('starts on the Monday of the week holding the 1st', () {
      final days = monthGrid(DateTime(2026, 10));
      expect(days, hasLength(42));
      expect(days.first.date, DateTime(2026, 9, 28));
      expect(days.first.inMonth, isFalse);
      expect(days[3].date, DateTime(2026, 10, 1));
      expect(days[3].inMonth, isTrue);
    });

    test('a month starting on Monday needs no leading days', () {
      // 2026-06-01 is a Monday.
      final days = monthGrid(DateTime(2026, 6));
      expect(days.first.date, DateTime(2026, 6, 1));
      expect(days.first.inMonth, isTrue);
    });

    test('always six weeks, so the grid height never jumps', () {
      for (var month = 1; month <= 12; month++) {
        expect(monthGrid(DateTime(2026, month)), hasLength(42));
      }
    });

    test('the last cell belongs to the week after the month ends', () {
      final days = monthGrid(DateTime(2026, 10));
      expect(days.last.date, DateTime(2026, 11, 8));
    });
  });

  group('coursesOnDate', () {
    test('keeps the class on a matching weekday inside its weeks', () {
      final result = coursesOnDate(
        [course()],
        DateTime(2026, 9, 7), // Monday, week 1
        termStart,
      );
      expect(result, hasLength(1));
    });

    test('drops it outside the week set', () {
      final result = coursesOnDate(
        [course()],
        DateTime(2026, 9, 28), // Monday, week 4? 21 days later = week 4
        termStart,
      );
      // 2026-09-07 + 21 days = 2026-09-28, week 4 — still inside {1..4}.
      expect(result, hasLength(1));

      final later = coursesOnDate(
        [course()],
        DateTime(2026, 10, 5), // week 5
        termStart,
      );
      expect(later, isEmpty);
    });

    test('drops everything before the term starts', () {
      final result = coursesOnDate(
        [course()],
        DateTime(2026, 9, 1),
        termStart,
      );
      expect(result, isEmpty);
    });

    test('orders by start period', () {
      final result = coursesOnDate(
        [course(id: 'b', start: 5), course(id: 'a', start: 1)],
        DateTime(2026, 9, 7),
        termStart,
      );
      expect(result.map((c) => c.id), ['a', 'b']);
    });
  });

  group('agendaOnDate', () {
    AgendaItem item({
      DateTime? due,
      RepeatRule repeat = RepeatRule.none,
      DateTime? until,
    }) =>
        AgendaItem(
          id: 'a',
          title: 't',
          dueDate: due,
          repeat: repeat,
          repeatUntil: until,
        );

    test('a one-off item appears only on its date', () {
      final due = DateTime(2026, 10, 20);
      expect(
          agendaOnDate([item(due: due)], DateTime(2026, 10, 20)), hasLength(1));
      expect(agendaOnDate([item(due: due)], DateTime(2026, 10, 21)), isEmpty);
    });

    test('a weekly item appears on the same weekday until it ends', () {
      final due = DateTime(2026, 10, 20); // Tuesday
      final list = [
        item(due: due, repeat: RepeatRule.weekly, until: DateTime(2026, 11, 3)),
      ];
      expect(agendaOnDate(list, DateTime(2026, 10, 27)), hasLength(1));
      expect(agendaOnDate(list, DateTime(2026, 11, 3)), hasLength(1));
      expect(agendaOnDate(list, DateTime(2026, 11, 10)), isEmpty);
    });

    test('an undated item never appears', () {
      expect(agendaOnDate([item()], DateTime(2026, 10, 20)), isEmpty);
    });
  });

  group('nextClass', () {
    test('finds the next class later today', () {
      final next = nextClass(
        now: DateTime(2026, 9, 7, 7, 30),
        firstWeekStart: termStart,
        courses: [course()],
      );
      expect(next, isNotNull);
      expect(next!.startsAt, DateTime(2026, 9, 7, 8, 0));
      expect(next.timeUntil(DateTime(2026, 9, 7, 7, 30)).inMinutes, 30);
    });

    test('a class in progress is the answer, not the next week', () {
      final next = nextClass(
        now: DateTime(2026, 9, 7, 8, 30),
        firstWeekStart: termStart,
        courses: [course()],
      );
      expect(next!.startsAt, DateTime(2026, 9, 7, 8, 0));
      expect(next.isRunning(DateTime(2026, 9, 7, 8, 30)), isTrue);
    });

    test('after it ends, the following week is next', () {
      final next = nextClass(
        now: DateTime(2026, 9, 7, 9, 45),
        firstWeekStart: termStart,
        courses: [course()],
      );
      expect(next!.startsAt, DateTime(2026, 9, 14, 8, 0));
    });

    test('a course without a clock time is skipped, not guessed', () {
      final next = nextClass(
        now: DateTime(2026, 9, 7, 7, 30),
        firstWeekStart: termStart,
        courses: [course(startTime: '', endTime: '')],
      );
      expect(next, isNull);
    });

    test('the end time falls back to a plausible duration', () {
      final next = nextClass(
        now: DateTime(2026, 9, 7, 8, 30),
        firstWeekStart: termStart,
        courses: [course(endTime: '')],
      );
      expect(next!.endsAt, DateTime(2026, 9, 7, 8, 45));
    });

    test('a horizon of zero days ignores next week', () {
      final next = nextClass(
        now: DateTime(2026, 9, 7, 9, 45),
        firstWeekStart: termStart,
        courses: [course()],
        horizonDays: 0,
      );
      expect(next, isNull);
    });
  });

  group('clock helpers', () {
    test('parseClassTimeRange accepts common separators', () {
      expect(
          parseClassTimeRange('08:00-09:40'), (start: '08:00', end: '09:40'));
      expect(parseClassTimeRange('8:00~9:40'), (start: '08:00', end: '09:40'));
      expect(parseClassTimeRange(' 10:00 – 11:40 '),
          (start: '10:00', end: '11:40'));
    });

    test('parseClassTimeRange refuses a single time or a reversed range', () {
      expect(parseClassTimeRange('08:00'), isNull);
      expect(parseClassTimeRange('09:40-08:00'), isNull);
      expect(parseClassTimeRange('25:00-26:00'), isNull);
      expect(parseClassTimeRange(''), isNull);
    });

    test('parseClockMinutes rejects impossible clock values', () {
      expect(parseClockMinutes('23:59'), 23 * 60 + 59);
      expect(parseClockMinutes('24:00'), isNull);
      expect(parseClockMinutes('12:60'), isNull);
      expect(parseClockMinutes('noon'), isNull);
    });

    test('formatClock pads to two digits', () {
      expect(formatClock(DateTime(2026, 1, 1, 8, 5)), '08:05');
      expect(formatClock(DateTime(2026, 1, 1, 18, 30)), '18:30');
    });
  });
}
