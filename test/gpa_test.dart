import 'package:campus_atlas/features/grades_query/archive/gpa.dart';
import 'package:campus_atlas/features/grades_query/archive/grade_models.dart';
import 'package:flutter_test/flutter_test.dart';

GradeRecord _rec({
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
  group('the WHU table (武汉大学本科生学籍管理规定 第二十一条)', () {
    test('every band boundary lands on the quoted point', () {
      expect(gradePointFor(GpaStandard.whu, 100), 4.0);
      expect(gradePointFor(GpaStandard.whu, 90), 4.0);
      expect(gradePointFor(GpaStandard.whu, 89), 3.7);
      expect(gradePointFor(GpaStandard.whu, 85), 3.7);
      expect(gradePointFor(GpaStandard.whu, 84), 3.3);
      expect(gradePointFor(GpaStandard.whu, 82), 3.3);
      expect(gradePointFor(GpaStandard.whu, 81), 3.0);
      expect(gradePointFor(GpaStandard.whu, 78), 3.0);
      expect(gradePointFor(GpaStandard.whu, 77), 2.7);
      expect(gradePointFor(GpaStandard.whu, 75), 2.7);
      expect(gradePointFor(GpaStandard.whu, 74), 2.3);
      expect(gradePointFor(GpaStandard.whu, 72), 2.3);
      expect(gradePointFor(GpaStandard.whu, 71), 2.0);
      expect(gradePointFor(GpaStandard.whu, 68), 2.0);
      expect(gradePointFor(GpaStandard.whu, 67), 1.5);
      expect(gradePointFor(GpaStandard.whu, 64), 1.5);
      expect(gradePointFor(GpaStandard.whu, 63), 1.0);
      expect(gradePointFor(GpaStandard.whu, 60), 1.0);
      expect(gradePointFor(GpaStandard.whu, 59), 0);
      expect(gradePointFor(GpaStandard.whu, 0), 0);
    });

    test('a 90 with 3 credits weighs in as 4.0 × 3, the school\u2019s 12.00',
        () {
      // 大学交际英语3 on the live page: cj=90, jd=4.0, xfjd=12.00.
      expect(gradePointFor(GpaStandard.whu, 90) * 3, 12.0);
    });
  });

  group('the other standards', () {
    test('五分之制 is linear from 60', () {
      expect(gradePointFor(GpaStandard.scale5, 100), 5.0);
      expect(gradePointFor(GpaStandard.scale5, 90), 4.0);
      expect(gradePointFor(GpaStandard.scale5, 61), closeTo(1.1, 1e-9));
      expect(gradePointFor(GpaStandard.scale5, 60), 1.0);
      expect(gradePointFor(GpaStandard.scale5, 59), 0);
    });

    test('the weighted standard keeps the score itself', () {
      expect(gradePointFor(GpaStandard.weighted, 82), 82);
    });

    test('an unknown persisted id falls back to the WHU standard', () {
      expect(GpaStandard.fromId('scale5'), GpaStandard.scale5);
      expect(GpaStandard.fromId('gone'), GpaStandard.whu);
    });
  });

  group('summarizeGrades', () {
    // A: 90×3必修, B: 80×2选修, C: 65×1必修, D: 优秀×2必修, E: 88×0必修.
    final rows = [
      _rec(name: 'A', credits: 3, scoreText: '90', score: 90),
      _rec(name: 'B', credits: 2, scoreText: '80', score: 80, kind: '选修'),
      _rec(name: 'C', credits: 1, scoreText: '65', score: 65),
      _rec(name: 'D', credits: 2, scoreText: '优秀', score: null),
      _rec(name: 'E', credits: 0, scoreText: '88', score: 88),
    ];

    test('weights by credits and excludes what cannot be weighted', () {
      final summary = summarizeGrades(rows, GpaStandard.whu);

      // (4.0×3 + 3.0×2 + 1.5×1) / 6
      expect(summary.value, closeTo(3.25, 1e-9));
      // (90×3 + 80×2 + 65×1) / 6
      expect(summary.avg, closeTo(82.5, 1e-9));
      expect(summary.counted, 3);
      expect(summary.total, 5);
      expect(summary.excluded, 2);
      expect(summary.countedCredits, 6);
      expect(summary.totalCredits, 8);
      // 优秀 earns its 2 credits even though it cannot enter the GPA.
      expect(summary.passedCredits, 8);
    });

    test('the required-only scope drops electives', () {
      final summary = summarizeGrades(rows, GpaStandard.whu,
          scope: GradeScope.requiredOnly);

      // (4.0×3 + 1.5×1) / 4
      expect(summary.value, closeTo(3.375, 1e-9));
      expect(summary.counted, 2);
      expect(summary.countedCredits, 4);
    });

    test('a fail counts, scores 0 and is reported', () {
      final summary = summarizeGrades(
        [_rec(scoreText: '55', score: 55)],
        GpaStandard.whu,
      );

      expect(summary.counted, 1);
      expect(summary.failed, 1);
      expect(summary.value, 0);
      expect(summary.passedCredits, 0);
    });

    test('nothing countable answers an empty summary, not a crash', () {
      final summary = summarizeGrades(
        [_rec(scoreText: 'W·中期退课', score: null)],
        GpaStandard.whu,
      );

      expect(summary.isEmpty, isTrue);
      expect(summary.value, isNull);
      expect(summary.countedCredits, 0);
    });

    test('the weighted standard returns the mean score as its value', () {
      final summary = summarizeGrades(rows, GpaStandard.weighted);
      expect(summary.value, closeTo(82.5, 1e-9));
    });
  });

  group('passesCourse', () {
    test('numeric scores decide by the 60 line', () {
      expect(passesCourse(_rec(score: 60, scoreText: '60')), isTrue);
      expect(passesCourse(_rec(score: 59, scoreText: '59')), isFalse);
    });

    test('level grades are read, not guessed', () {
      expect(passesCourse(_rec(score: null, scoreText: '优秀')), isTrue);
      expect(passesCourse(_rec(score: null, scoreText: '合格')), isTrue);
      expect(passesCourse(_rec(score: null, scoreText: '不及格')), isFalse);
      expect(passesCourse(_rec(score: null, scoreText: '缺考')), isFalse);
      expect(passesCourse(_rec(score: null, scoreText: 'W·中期退课')), isFalse);
      expect(passesCourse(_rec(score: null, scoreText: '')), isFalse);
    });
  });

  group('termStats', () {
    test('orders terms chronologically and keeps empty ones', () {
      final rows = [
        _rec(
            year: '2025-2026',
            semester: '1',
            name: 'A',
            score: 90,
            scoreText: '90'),
        _rec(
            year: '2024-2025',
            semester: '2',
            name: 'B',
            score: 80,
            scoreText: '80'),
        _rec(
          year: '2025-2026',
          semester: '2',
          name: 'C',
          score: null,
          scoreText: 'W·中期退课',
        ),
      ];

      final terms = termStats(rows, GpaStandard.whu);

      expect(terms.map((t) => t.label).toList(), [
        '2024-2025 2',
        '2025-2026 1',
        '2025-2026 2',
      ]);
      expect(terms[0].summary.value, closeTo(3.0, 1e-9));
      expect(terms[1].summary.value, closeTo(4.0, 1e-9));
      expect(terms[2].summary.isEmpty, isTrue);
      expect(terms[2].shortLabel, '25-26·2');
    });

    test('terms in the same year sort by term number', () {
      final rows = [
        _rec(semester: '2', name: 'late'),
        _rec(semester: '1', name: 'early'),
      ];

      expect(
        termStats(rows, GpaStandard.whu).map((t) => t.label).toList(),
        ['2025-2026 1', '2025-2026 2'],
      );
    });
  });
}
