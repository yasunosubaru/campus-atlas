import 'package:campus_atlas/features/grades_query/grades_query_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the tolerant parsers in the grade-query feature.
///
/// ⚠️ **Every fixture here is hand-shaped, not captured.** The four endpoints
/// behind this feature are auth-walled and no response body was ever recorded,
/// so these fixtures model what the *contract* implies — one row per alias the
/// parser accepts — rather than what the server actually sends. When the first
/// real response arrives, tighten the parser to the real keys and delete the
/// alias coverage that turned out to be dead.
void main() {
  group('GradeBucket', () {
    test('reads whichever label alias the server uses', () {
      for (final key in const [
        'label',
        'grade',
        'grade_point',
        'gradePoint',
        'point',
        'bucket',
        'range',
        'band',
        'name',
        'score',
      ]) {
        final b = GradeBucket.tryParse({key: '优', 'count': 12});
        expect(b, isNotNull, reason: key);
        expect(b!.label, '优', reason: key);
        expect(b.count, 12);
      }
    });

    test('reads whichever count alias the server uses', () {
      for (final key in const [
        'count',
        'total',
        'students',
        'student_count',
        'studentCount',
        'num',
        'n',
        'number',
        'value',
      ]) {
        final b = GradeBucket.tryParse({'label': '良', key: 7});
        expect(b, isNotNull, reason: key);
        expect(b!.count, 7, reason: key);
      }
    });

    test('reads whichever percentage alias the server uses', () {
      for (final key in const [
        'percentage',
        'percent',
        'ratio',
        'pct',
        'rate',
        'proportion',
        'share',
      ]) {
        final b = GradeBucket.tryParse({'label': '中', key: 20.5});
        expect(b, isNotNull, reason: key);
        expect(b!.percentage, closeTo(20.5, 1e-9), reason: key);
      }
    });

    test('keeps the untouched payload for diagnostics', () {
      final raw = {'label': '优', 'count': 3, 'unknownColumn': 'x'};
      final b = GradeBucket.tryParse(raw)!;
      expect(b.raw['unknownColumn'], 'x');
      expect(b.raw, isA<Map<String, Object?>>());
    });

    test('a row with no label is discarded', () {
      expect(GradeBucket.tryParse({'count': 5}), isNull);
      expect(GradeBucket.tryParse({'label': '   ', 'count': 5}), isNull);
      expect(GradeBucket.tryParse('not a row'), isNull);
      expect(GradeBucket.tryParse(null), isNull);
    });

    test('a numeric label is still usable', () {
      // Ranges like 90-100 may arrive as a number when the format is a plain
      // score band.
      final b = GradeBucket.tryParse({'grade': 95, 'count': 4});
      expect(b, isNotNull);
      expect(b!.label, '95');
    });

    test('fail bands are recognised, neutral bands are not', () {
      expect(GradeBucket.tryParse({'label': '不及格'})!.looksLikeFail, isTrue);
      expect(GradeBucket.tryParse({'label': '不合格'})!.looksLikeFail, isTrue);
      expect(GradeBucket.tryParse({'label': 'F'})!.looksLikeFail, isTrue);
      expect(GradeBucket.tryParse({'label': 'Fail'})!.looksLikeFail, isTrue);
      // The important direction: everything unrecognised must be neutral, so a
      // pass band is never painted as a failure.
      expect(GradeBucket.tryParse({'label': '优'})!.looksLikeFail, isFalse);
      expect(GradeBucket.tryParse({'label': '90-100'})!.looksLikeFail, isFalse);
      expect(GradeBucket.tryParse({'label': 'A'})!.looksLikeFail, isFalse);
    });
  });

  group('TeacherGrade', () {
    test('reads a full teacher row', () {
      final t = TeacherGrade.tryParse({
        'id': 99,
        'teacher_name': '周国全',
        'course_name': '大学物理A（下）',
        'department': '物理科学与技术学院',
        'course_code': '1100860011002',
        'review_count': 12,
        'average_rating': 4.5,
        'average_difficulty': 3.2,
        'average_teaching_quality': 4.1,
        'average_workload': 2.8,
        'average_rating_difficult': 3.9,
      })!;

      expect(t.id, '99');
      expect(t.name, '周国全');
      expect(t.courseName, '大学物理A（下）');
      expect(t.department, '物理科学与技术学院');
      expect(t.courseCode, '1100860011002');
      expect(t.reviewCount, 12);
      expect(t.rating, closeTo(4.5, 1e-9));
      expect(t.difficulty, closeTo(3.2, 1e-9));
      expect(t.teachingQuality, closeTo(4.1, 1e-9));
      expect(t.workload, closeTo(2.8, 1e-9));
      expect(t.gradingScore, closeTo(3.9, 1e-9));
    });

    test('the grading field is carried through, never inverted', () {
      // `average_rating_difficult` has an unverified direction. Inverting it
      // here would silently bake a guess into the displayed number, so the
      // value must arrive exactly as sent.
      final t = TeacherGrade.tryParse({
        'teacher_id': 'x',
        'name': '王老师',
        'average_rating_difficult': 4,
      })!;
      expect(t.gradingScore, 4);
      expect(t.gradingScore, isNot(1));
    });

    test('a teacher without a name is discarded; one without an id is not', () {
      expect(TeacherGrade.tryParse({'id': 1}), isNull);
      expect(TeacherGrade.tryParse({'name': '  '}), isNull);
      expect(TeacherGrade.tryParse({'name': '李', 'id': '7'}), isNotNull);
    });

    test('distribution is read from the first list-shaped key', () {
      for (final key in const [
        'distribution',
        'grade_distribution',
        'gradeDistribution',
        'buckets',
        'grades',
        'items',
      ]) {
        final t = TeacherGrade.tryParse({
          'id': '1',
          'name': 'T',
          key: [
            {'label': '优', 'count': 3},
            {'label': '良', 'count': 5},
          ],
        })!;
        expect(t.hasDistribution, isTrue, reason: key);
        expect(t.distribution, hasLength(2), reason: key);
        expect(t.bucketTotal, 8, reason: key);
      }
    });

    test('malformed rows inside a distribution are skipped, not fatal', () {
      final t = TeacherGrade.tryParse({
        'id': '1',
        'name': 'T',
        'distribution': [
          {'label': '优', 'count': 3},
          {'count': 9},
          'garbage',
          null,
          {'label': '良', 'count': 4},
        ],
      })!;
      expect(t.hasDistribution, isTrue);
      expect(t.distribution, hasLength(2));
    });

    test('an empty distribution is not "has distribution"', () {
      final t = TeacherGrade.tryParse(
          {'id': '1', 'name': 'T', 'buckets': <Object?>[]})!;
      expect(t.hasDistribution, isFalse);
    });

    test('a string number in a count field still parses', () {
      final t = TeacherGrade.tryParse({
        'id': '1',
        'name': 'T',
        'review_count': '34',
      })!;
      expect(t.reviewCount, 34);
    });
  });

  group('CourseGrades', () {
    test('reads a course with its teachers', () {
      final c = CourseGrades.tryParse({
        'course_uid': '01a0bda9',
        'name': '大学物理A（下）',
        'teachers': [
          {'id': '1', 'teacher_name': '周国全'},
          {'id': '2', 'teacher_name': '王晓峰'},
        ],
      })!;

      expect(c.uid, '01a0bda9');
      expect(c.name, '大学物理A（下）');
      expect(c.teachers, hasLength(2));
      expect(c.isEmpty, isFalse);
    });

    test('the uid falls back to the name when absent', () {
      final c = CourseGrades.tryParse({'name': '线性代数'})!;
      expect(c.uid, '线性代数');
    });

    test('a course with no teachers is empty but valid', () {
      final c = CourseGrades.tryParse({
        'course_uid': 'x',
        'name': '高等数学',
      })!;
      expect(c.isEmpty, isTrue);
      expect(c.teachers, isEmpty);
    });

    test('a course with no name is discarded', () {
      expect(CourseGrades.tryParse({'uid': '1'}), isNull);
      expect(CourseGrades.tryParse({'name': ''}), isNull);
      expect(CourseGrades.tryParse(null), isNull);
    });

    test('teachers are read from whichever list key is present', () {
      for (final key in const [
        'teachers',
        'offerings',
        'teaching_classes',
        'items',
        'results',
      ]) {
        final c = CourseGrades.tryParse({
          'name': 'C',
          key: [
            {'id': '1', 'name': '张三'},
          ],
        })!;
        expect(c.teachers, hasLength(1), reason: key);
      }
    });
  });

  group('CourseReview', () {
    test('reads a review from whichever content key is present', () {
      for (final key in const [
        'content',
        'comment',
        'text',
        'review',
        'body',
        'description',
      ]) {
        final r = CourseReview.tryParse({
          'id': 'r1',
          key: '给分很松，推荐',
        })!;
        expect(r.text, '给分很松，推荐', reason: key);
      }
    });

    test('reads a rating and a date', () {
      final r = CourseReview.tryParse({
        'id': 'r1',
        'rating': 4.5,
        'created_at': '2026-09-20T07:13:07.695717Z',
        'teacher_name': '张三',
      })!;
      expect(r.rating, closeTo(4.5, 1e-9));
      expect(r.createdAt, DateTime.parse('2026-09-20T07:13:07.695717Z'));
      expect(r.teacherName, '张三');
    });

    test('a review with no id is discarded', () {
      expect(CourseReview.tryParse({'content': 'x'}), isNull);
      expect(CourseReview.tryParse({'id': '', 'content': 'x'}), isNull);
    });

    test('an unparsable date yields null rather than throwing', () {
      final r = CourseReview.tryParse({'id': 'r', 'created_at': 'not-a-date'})!;
      expect(r.createdAt, isNull);
    });
  });
}
