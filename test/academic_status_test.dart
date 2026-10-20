import 'package:campus_atlas/features/grades_query/archive/academic_status.dart';
import 'package:campus_atlas/features/grades_query/archive/gpa.dart';
import 'package:campus_atlas/features/grades_query/archive/grade_models.dart';
import 'package:flutter_test/flutter_test.dart';

GradeRecord row({
  String year = '2025-2026',
  String semester = '1',
  String name = '课程',
  String kind = '必修',
  double credits = 3,
  String scoreText = '90',
  double? score = 90,
}) =>
    GradeRecord(
      year: year,
      semester: semester,
      courseName: name,
      courseKind: kind,
      credits: credits,
      scoreText: scoreText,
      score: score,
    );

void main() {
  group('courseGroupOf', () {
    test('reads the course nature the system reports', () {
      expect(courseGroupOf(row(kind: '必修')), CourseGroup.required);
      expect(courseGroupOf(row(kind: '专业必修')), CourseGroup.required);
      expect(courseGroupOf(row(kind: '通识必修')), CourseGroup.required);
      expect(courseGroupOf(row(kind: '选修')), CourseGroup.elective);
      expect(courseGroupOf(row(kind: '专业选修')), CourseGroup.elective);
      expect(courseGroupOf(row(kind: '限选')), CourseGroup.elective);
      expect(courseGroupOf(row(kind: '')), CourseGroup.other);
      expect(courseGroupOf(row(kind: '实践')), CourseGroup.other);
    });
  });

  group('computeAcademicStatus', () {
    test('sums passed, attempted and per-group credits', () {
      final status = computeAcademicStatus([
        row(name: 'A', kind: '必修', credits: 3),
        row(name: 'B', kind: '选修', credits: 2),
        row(name: 'C', kind: '实践', credits: 1),
      ], GpaStandard.whu);

      expect(status.passedCredits, 6);
      expect(status.attemptedCredits, 6);
      expect(status.requiredCredits, 3);
      expect(status.electiveCredits, 2);
      expect(status.otherCredits, 1);
      expect(status.failed, isEmpty);
    });

    test('a failed course counts as attempted but not passed', () {
      final status = computeAcademicStatus([
        row(name: 'A', credits: 3),
        row(name: 'F', credits: 2, scoreText: '55', score: 55),
      ], GpaStandard.whu);

      expect(status.passedCredits, 3);
      expect(status.attemptedCredits, 5);
      expect(status.failed, hasLength(1));
      expect(status.failed.single.courseName, 'F');
    });

    test('a repeated course earns its credits once', () {
      final status = computeAcademicStatus([
        row(name: 'A', year: '2024-2025', semester: '2', scoreText: '55',
            score: 55),
        row(name: 'A', year: '2025-2026', semester: '1', scoreText: '85',
            score: 85),
      ], GpaStandard.whu);

      expect(status.passedCredits, 3);
      // Both attempts count toward what was attempted.
      expect(status.attemptedCredits, 6);
    });

    test('level grades earn credits but do not fail', () {
      final status = computeAcademicStatus([
        row(name: 'A', scoreText: '优秀', score: null),
      ], GpaStandard.whu);

      expect(status.passedCredits, 3);
      expect(status.failed, isEmpty);
    });

    test('terms are chronological and carry their own credits', () {
      final status = computeAcademicStatus([
        row(year: '2025-2026', semester: '1', name: 'A', credits: 3),
        row(year: '2024-2025', semester: '2', name: 'B', credits: 2),
      ], GpaStandard.whu);

      expect(status.terms.map((t) => t.label),
          ['2024-2025 2', '2025-2026 1']);
      expect(status.terms.first.credits, 2);
      expect(status.terms.last.credits, 3);
    });

    test('progress needs a target and clamps at 100%', () {
      final rows = [row(name: 'A', credits: 3)];

      expect(computeAcademicStatus(rows, GpaStandard.whu).progress, isNull);
      expect(
        computeAcademicStatus(rows, GpaStandard.whu, target: 12).progress,
        closeTo(0.25, 1e-9),
      );
      expect(
        computeAcademicStatus(rows, GpaStandard.whu, target: 2).progress,
        1.0,
      );
    });

    test('an empty archive is empty rather than a zero GPA', () {
      final status = computeAcademicStatus(const [], GpaStandard.whu);
      expect(status.isEmpty, isTrue);
      expect(status.summary.value, isNull);
      expect(status.passedCredits, 0);
    });
  });
}
