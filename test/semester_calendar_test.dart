import 'package:campus_atlas/features/timetable/import/semester_calendar.dart';
import 'package:campus_atlas/features/whu_auth/whu_endpoints.dart';
import 'package:flutter_test/flutter_test.dart';

/// The import writes courses for a semester, and the week grid draws them
/// against one anchor. These dates are WHU's published calendar, so a change
/// here is a change in the anchor every imported timetable is drawn with.
void main() {
  test('fall week 1 is the first Monday of September', () {
    expect(semesterFirstWeekStart('2026', WhuTerm.first), DateTime(2026, 9, 7));
    expect(semesterFirstWeekStart('2025', WhuTerm.first), DateTime(2025, 9, 1));
  });

  test('spring week 1 is the Monday on or after 20 February', () {
    expect(
      semesterFirstWeekStart('2026', WhuTerm.second),
      DateTime(2027, 2, 22),
    );
    expect(
      semesterFirstWeekStart('2025', WhuTerm.second),
      DateTime(2026, 2, 23),
    );
  });

  test('summer week 1 is the first Monday of July', () {
    expect(semesterFirstWeekStart('2025', WhuTerm.third), DateTime(2026, 7, 6));
  });

  test('an implausible year is rejected rather than guessed', () {
    expect(semesterFirstWeekStart('', WhuTerm.first), isNull);
    expect(semesterFirstWeekStart('26', WhuTerm.first), isNull);
    expect(semesterFirstWeekStart('abc', WhuTerm.first), isNull);
  });
}
