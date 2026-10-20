/// The GPA algorithms and the statistics built on top of them.
///
/// ## The WHU table is quoted, not guessed
///
/// [GpaStandard.whu] implements the conversion table from 武汉大学's own
/// regulation — 《武汉大学本科生学籍管理规定（修订）》第二十一条
/// (info.whu.edu.cn/info/3781/14965.htm):
///
/// ```
/// 成绩        绩点        成绩        绩点
/// 90－100     4.0         72－74      2.3
/// 85－89      3.7         68－71      2.0
/// 64－67      1.5
/// 82－84      3.3         60－63      1.0
/// 78－81      3.0         60 分以下   0
/// 75－77      2.7
/// 学分绩 = 课程绩点 × 学分数
/// 平均学分绩点（GPA） = 所修课程学分绩之和 ÷ 所修课程学分之和
/// ```
///
/// The live grade table reports its own `平均学分绩点` in the page header, so
/// the two can be compared against each other at runtime — a cross-check rather
/// than an assumption.
///
/// [GpaStandard.scale5] is the widely used linear 5-point form (60 → 1.0,
/// 100 → 5.0), [GpaStandard.weighted] is the plain credit-weighted mean of the
/// 100-mark scores, for comparisons that do not involve grade points at all.
library;

import 'grade_models.dart';

/// How a score becomes a grade point.
enum GpaStandard {
  /// 武汉大学 4.0 table, quoted above.
  whu('whu', 4.0),

  /// 五分制线性: 绩点 = (分数 − 50) ÷ 10，60 分起算，100 分满分 5.0。
  scale5('scale5', 5.0),

  /// No grade points: the credit-weighted mean of the 100-mark scores.
  weighted('weighted', 100.0);

  const GpaStandard(this.id, this.maxScale);

  /// Stable id for persistence; never rename an existing one.
  final String id;

  /// The ceiling a chart bar is drawn against.
  final double maxScale;

  /// Parses an id written by an older build; an unknown id falls back to
  /// [GpaStandard.whu] rather than throwing on startup.
  static GpaStandard fromId(String id) {
    for (final standard in values) {
      if (standard.id == id) return standard;
    }
    return GpaStandard.whu;
  }
}

/// The grade point [score] earns under [standard].
///
/// Never null for a numeric score: a 0 is a real outcome (a fail), and coding
/// it as null would silently drop the row from the weighted means.
double gradePointFor(GpaStandard standard, double score) {
  switch (standard) {
    case GpaStandard.whu:
      if (score >= 90) return 4.0;
      if (score >= 85) return 3.7;
      if (score >= 82) return 3.3;
      if (score >= 78) return 3.0;
      if (score >= 75) return 2.7;
      if (score >= 72) return 2.3;
      if (score >= 68) return 2.0;
      if (score >= 64) return 1.5;
      if (score >= 60) return 1.0;
      return 0;
    case GpaStandard.scale5:
      if (score < 60) return 0;
      return ((score - 50) / 10).clamp(1.0, 5.0);
    case GpaStandard.weighted:
      return score.clamp(0.0, 100.0);
  }
}

/// Which rows a statistic counts.
enum GradeScope {
  /// Every row that can enter a weighted mean.
  all,

  /// Only rows whose course nature says `必修`.
  requiredOnly;

  /// Whether [kind] (a raw 课程性质 cell) belongs in this scope.
  bool accepts(String kind) =>
      this == GradeScope.all || kind.contains('必修');
}

/// One set of statistics over a selection of rows.
class GradeSummary {
  const GradeSummary({
    required this.standard,
    this.value,
    this.avg = 0,
    this.counted = 0,
    this.total = 0,
    this.failed = 0,
    this.excluded = 0,
    this.countedCredits = 0,
    this.totalCredits = 0,
    this.passedCredits = 0,
  });

  final GpaStandard standard;

  /// The headline number: the GPA under [standard], or the weighted mean for
  /// [GpaStandard.weighted]. Null when nothing is countable.
  final double? value;

  /// The credit-weighted mean of the 100-mark scores, always computed.
  final double avg;

  /// Rows that entered the weighted means.
  final int counted;

  /// Rows offered, countable or not.
  final int total;

  /// Counted rows scored below 60.
  final int failed;

  /// Rows that could not be counted (level-graded, 退课, zero credits, or
  /// filtered out by the scope).
  final int excluded;

  /// Credits of the counted rows — the denominator of every mean here.
  final double countedCredits;

  /// Credits of every row offered, whatever its score looks like.
  final double totalCredits;

  /// Credits of rows scored 60 or above.
  final double passedCredits;

  bool get isEmpty => counted == 0;
}

/// Whether [row] represents a passed course.
///
/// A numeric score decides outright. A level-graded row cannot enter a GPA, but
/// it still earns its credits, so `优秀` / `合格` texts count as passed while
/// `不及格` / `缺考` / `退课` and anything unrecognised do not. Guessing "pass"
/// for an unknown marker would inflate the earned-credit total, which is the
/// number a graduation check reads.
bool passesCourse(GradeRecord row) {
  final score = row.score;
  if (score != null) return score >= 60;

  final text = row.scoreText;
  if (text.isEmpty) return false;
  const fail = ['不及格', '不合格', '不通过', '缺考', '退课', '作弊', '违纪'];
  if (fail.any(text.contains)) return false;
  const pass = ['优秀', '良好', '中等', '及格', '合格', '通过', '免修'];
  return pass.any(text.contains);
}

/// Computes the statistics a person actually reads off a grades page.
///
/// Entry rules, in one place:
///  * a row needs a numeric [GradeRecord.score] — level grades cannot be
///    weighted, and guessing a number for `优秀` would fabricate data;
///  * a row needs positive [GradeRecord.credits] — a zero-credit course would
///    enter an unweighted mean for free, which is not what any of the
///    standards' formulas say;
///  * [scope] filters by the raw course nature.
GradeSummary summarizeGrades(
  Iterable<GradeRecord> rows,
  GpaStandard standard, {
  GradeScope scope = GradeScope.all,
}) {
  var total = 0;
  var counted = 0;
  var failed = 0;
  var totalCredits = 0.0;
  var countedCredits = 0.0;
  var passedCredits = 0.0;
  var points = 0.0;
  var scoreCredits = 0.0;

  for (final row in rows) {
    total++;
    totalCredits += row.credits;

    if (passesCourse(row)) passedCredits += row.credits;

    final score = row.score;
    if (score == null || row.credits <= 0 || !scope.accepts(row.courseKind)) {
      continue;
    }
    counted++;
    if (score < 60) failed++;
    countedCredits += row.credits;
    points += gradePointFor(standard, score) * row.credits;
    scoreCredits += score * row.credits;
  }

  return GradeSummary(
    standard: standard,
    value: countedCredits > 0 ? points / countedCredits : null,
    avg: countedCredits > 0 ? scoreCredits / countedCredits : 0,
    counted: counted,
    total: total,
    failed: failed,
    excluded: total - counted,
    countedCredits: countedCredits,
    totalCredits: totalCredits,
    passedCredits: passedCredits,
  );
}

/// One term's statistics, for the trend.
class TermStats {
  const TermStats({
    required this.year,
    required this.semester,
    required this.summary,
  });

  final String year;
  final String semester;
  final GradeSummary summary;

  /// `2025-2026 1`
  String get label => [year, semester].where((s) => s.isNotEmpty).join(' ');

  /// `25-26·1`, for a chart axis.
  String get shortLabel => shortTermLabelOf(year, semester);
}

/// Per-term statistics in chronological order.
///
/// Terms with nothing countable are kept: a term that only holds 退课 rows is
/// a fact about the timeline, and dropping it would make a gap look like a
/// missing import.
List<TermStats> termStats(
  Iterable<GradeRecord> rows,
  GpaStandard standard, {
  GradeScope scope = GradeScope.all,
}) {
  final grouped = <String, List<GradeRecord>>{};
  for (final row in rows) {
    grouped.putIfAbsent('${row.year}|${row.semester}', () => <GradeRecord>[])
        .add(row);
  }

  final entries = grouped.values.toList()
    ..sort((a, b) {
      final byYear = a.first.yearStart.compareTo(b.first.yearStart);
      if (byYear != 0) return byYear;
      return a.first.semesterNumber.compareTo(b.first.semesterNumber);
    });

  return [
    for (final group in entries)
      TermStats(
        year: group.first.year,
        semester: group.first.semester,
        summary: summarizeGrades(group, standard, scope: scope),
      ),
  ];
}
