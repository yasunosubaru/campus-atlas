import 'gpa.dart';
import 'grade_models.dart';

/// Which part of a degree a course belongs to.
///
/// Derived from the raw 课程性质 cell, because that is what the academic system
/// actually reports. The three groups are the ones a credit check cares about;
/// an unrecognised nature stays [other] rather than being folded into a group it
/// might not belong to.
enum CourseGroup { required, elective, other }

CourseGroup courseGroupOf(GradeRecord row) {
  final kind = row.courseKind;
  if (kind.contains('必修')) return CourseGroup.required;
  if (kind.contains('选修') ||
      kind.contains('限选') ||
      kind.contains('任选') ||
      kind.contains('通识')) {
    return CourseGroup.elective;
  }
  return CourseGroup.other;
}

/// One term's earned credits and GPA.
class TermCredits {
  const TermCredits({
    required this.year,
    required this.semester,
    required this.credits,
    required this.summary,
  });

  final String year;
  final String semester;
  final double credits;
  final GradeSummary summary;

  String get label => [year, semester].where((s) => s.isNotEmpty).join(' ');

  String get shortLabel => shortTermLabelOf(year, semester);
}

/// The credit picture a degree check asks for, computed from the local archive.
class AcademicStatus {
  const AcademicStatus({
    required this.summary,
    required this.passedCredits,
    required this.attemptedCredits,
    required this.requiredCredits,
    required this.electiveCredits,
    required this.otherCredits,
    required this.failed,
    required this.terms,
    this.target,
  });

  /// GPA / weighted mean under the chosen standard.
  final GradeSummary summary;

  /// Credits of every course that was passed.
  final double passedCredits;

  /// Credits of every course attempted, passed or not.
  final double attemptedCredits;

  final double requiredCredits;
  final double electiveCredits;
  final double otherCredits;

  /// Numeric failures, newest term first.
  final List<GradeRecord> failed;

  final List<TermCredits> terms;

  /// The graduation requirement, when the person has set one.
  final double? target;

  /// Fraction of [target] earned, or null when no target is set.
  double? get progress {
    final goal = target;
    if (goal == null || goal <= 0) return null;
    return (passedCredits / goal).clamp(0.0, 1.0);
  }

  bool get isEmpty => summary.total == 0;
}

/// Builds the status from archived rows.
///
/// Credits are counted **per course**, not per row: a course repeated in two
/// terms counts its credits once when passed. The archive is keyed by term, so
/// the same course name in two terms is two rows — and only the pass should earn
/// the credits.
AcademicStatus computeAcademicStatus(
  List<GradeRecord> rows,
  GpaStandard standard, {
  double? target,
}) {
  final summary = summarizeGrades(rows, standard);

  var passedCredits = 0.0;
  var attemptedCredits = 0.0;
  var requiredCredits = 0.0;
  var electiveCredits = 0.0;
  var otherCredits = 0.0;
  final failed = <GradeRecord>[];
  final creditedNames = <String>{};

  for (final row in rows) {
    if (row.credits > 0) attemptedCredits += row.credits;

    if (passesCourse(row)) {
      // The same course passed twice (a repeat that improved a grade) earns its
      // credits once. Keying on the name rather than the code because a retake
      // can carry a different code for the same course.
      final firstPass = creditedNames.add(row.courseName);
      if (firstPass) {
        passedCredits += row.credits;
        switch (courseGroupOf(row)) {
          case CourseGroup.required:
            requiredCredits += row.credits;
          case CourseGroup.elective:
            electiveCredits += row.credits;
          case CourseGroup.other:
            otherCredits += row.credits;
        }
      }
    } else if (row.score != null && row.score! < 60) {
      failed.add(row);
    }
  }

  failed.sort((a, b) {
    final byTerm = GradeRecord.compare(b, a);
    return byTerm != 0 ? byTerm : a.courseName.compareTo(b.courseName);
  });

  final terms = [
    for (final term in termStats(rows, standard))
      TermCredits(
        year: term.year,
        semester: term.semester,
        credits: term.summary.passedCredits,
        summary: term.summary,
      ),
  ];

  return AcademicStatus(
    summary: summary,
    passedCredits: passedCredits,
    attemptedCredits: attemptedCredits,
    requiredCredits: requiredCredits,
    electiveCredits: electiveCredits,
    otherCredits: otherCredits,
    failed: failed,
    terms: terms,
    target: target,
  );
}
