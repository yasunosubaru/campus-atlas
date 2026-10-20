import '../../whu_auth/whu_endpoints.dart' show WhuTerm;

/// The Monday on which academic week 1 begins.
///
/// [year] is the calendar year in which the academic year starts, so the
/// 2026–2027 year is `2026`. The dates follow WHU's published calendar:
///
///   * 第1学期 (fall): classes begin on the first Monday of September.
///   * 第2学期 (spring): classes begin on the Monday on or after 20 February
///     of the following calendar year.
///   * 第3学期 (summer): classes begin on the first Monday of July of the
///     following calendar year.
///
/// The import sheet knows only the year and term; without this anchor the
/// week grid counts from the app's default (the spring semester) and an
/// imported fall timetable is stored correctly but drawn in the wrong week.
///
/// Returns null when [year] is not a plausible academic year, so a typo in
/// the year field cannot overwrite the person's anchor with a guess.
DateTime? semesterFirstWeekStart(String year, WhuTerm term) {
  final startYear = int.tryParse(year.trim());
  if (startYear == null || startYear < 2000 || startYear > 2100) return null;

  final seed = switch (term) {
    WhuTerm.first => DateTime(startYear, 9, 1),
    WhuTerm.second => DateTime(startYear + 1, 2, 20),
    WhuTerm.third => DateTime(startYear + 1, 7, 1),
  };
  // Dart's % is non-negative, so this is the number of days until Monday even
  // when the seed is Monday itself (0) or Sunday (1).
  final monday = seed.add(Duration(days: (DateTime.monday - seed.weekday) % 7));
  return DateTime(monday.year, monday.month, monday.day);
}
