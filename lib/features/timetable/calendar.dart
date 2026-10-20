import '../agenda/agenda_repository.dart';
import 'timetable_models.dart';
import 'timetable_repository.dart';

/// One cell of a month grid.
class CalendarDay {
  const CalendarDay({required this.date, required this.inMonth});

  final DateTime date;
  final bool inMonth;
}

/// Six Monday-first weeks covering [month].
///
/// Always 42 cells so the grid does not change height between months — a
/// month view that jumps by a row when you page through it makes the whole
/// screen feel unstable. Days outside the month are included (greyed out) so a
/// class on the 1st still shows the tail of the previous month's week.
List<CalendarDay> monthGrid(DateTime month) {
  final first = DateTime(month.year, month.month);
  final start = first.subtract(Duration(days: first.weekday - 1));

  final days = <CalendarDay>[];
  for (var i = 0; i < 42; i++) {
    final date = DateTime(start.year, start.month, start.day + i);
    days.add(CalendarDay(date: date, inMonth: date.month == month.month));
  }
  return days;
}

/// The classes that actually meet on [date].
///
/// Empty before term start (week 0) and outside a course's week set — the same
/// rule the weekly grid uses, so the two views cannot disagree about whether a
/// class happens.
List<Course> coursesOnDate(
  List<Course> courses,
  DateTime date,
  DateTime firstWeekStart,
) {
  final week = weekNumberFor(date, firstWeekStart);
  if (week < 1) return const [];
  final out = courses
      .where((c) => c.weekday == date.weekday && c.occursInWeek(week))
      .toList()
    ..sort((a, b) => a.startPeriod.compareTo(b.startPeriod));
  return out;
}

/// Agenda entries that fall on [date], including repeats.
///
/// Done items are kept: the month view is a record of the day, and a ticked
/// task that happened still happened.
List<AgendaItem> agendaOnDate(List<AgendaItem> items, DateTime date) => [
      for (final item in items)
        if (item.occursOn(date)) item
    ];
