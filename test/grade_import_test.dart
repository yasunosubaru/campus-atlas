import 'package:campus_atlas/features/grades_query/archive/grade_import.dart';
import 'package:campus_atlas/features/grades_query/jwgl/jwgl_grade_grid.dart';
import 'package:flutter_test/flutter_test.dart';

/// The live column set as read on 2026-10-18 (a reduced but faithful subset:
/// the field names are the real ones, the order matches the grid's own).
const _head = ['课程名称', '任课教师', '学分', '成绩', '绩点', '课程性质', '学年', '学期', '课程代码'];
const _fields = [
  'kcmc',
  'jsxm',
  'xf',
  'cj',
  'jd',
  'kcxzmc',
  'xnmmc',
  'xqmmc',
  'kch'
];

JwglGradeGrid _grid({
  List<String> head = _head,
  List<String> fields = _fields,
  required List<List<String>> rows,
}) =>
    JwglGradeGrid(head: head, fields: fields, rows: rows);

void main() {
  group('recordsFromGrid', () {
    test('maps a live-shaped row', () {
      final records = recordsFromGrid(_grid(rows: [
        ['大学交际英语3', '张美霞', '3', '90', '4.0', '必修', '2025-2026', '1', 'ENG003'],
      ]));

      final record = records.single;
      expect(record.courseName, '大学交际英语3');
      expect(record.teacher, '张美霞');
      expect(record.credits, 3);
      expect(record.score, 90);
      expect(record.scoreText, '90');
      expect(record.gradePoint, 4.0);
      expect(record.courseKind, '必修');
      expect(record.year, '2025-2026');
      expect(record.semester, '1');
      expect(record.courseCode, 'ENG003');
      expect(record.source, 'jwgl');
    });

    test('keeps a level-graded row, with no numeric score', () {
      final records = recordsFromGrid(_grid(rows: [
        ['素质体育1', '王老师', '1', 'W·中期退课', '', '必修', '2025-2026', '1', 'PE001'],
      ]));

      final record = records.single;
      expect(record.score, isNull);
      expect(record.scoreText, 'W·中期退课');
      expect(record.gradePoint, isNull);
    });

    test('skips a row without a course name', () {
      final records = recordsFromGrid(_grid(rows: [
        ['', '', '3', '', '', '', '2025-2026', '1', ''],
        ['线性代数A', '陈老师', '4', '90', '4.0', '必修', '2025-2026', '1', 'MATH002'],
      ]));

      expect(records.single.courseName, '线性代数A');
    });

    test('parses fractional credits', () {
      final records = recordsFromGrid(_grid(rows: [
        ['通识课', '赵老师', '1.5', '88', '3.7', '选修', '2025-2026', '1', 'GEN001'],
      ]));

      expect(records.single.credits, 1.5);
    });

    test('falls back to labels when the grid has no field names', () {
      final records = recordsFromGrid(JwglGradeGrid(
        head: _head,
        rows: [
          ['地球科学概论', '刘老师', '2', '77', '2.7', '必修', '2025-2026', '1', 'GEO001'],
        ],
      ));

      expect(records.single.courseName, '地球科学概论');
      expect(records.single.score, 77);
      expect(records.single.credits, 2);
    });

    test('an empty grid yields no rows', () {
      expect(recordsFromGrid(_grid(rows: [])), isEmpty);
    });
  });

  group('scoreFromText', () {
    test('parses a plain 100-mark score', () {
      expect(scoreFromText('90'), 90);
      expect(scoreFromText('95.5'), 95.5);
      expect(scoreFromText(' 60 '), 60);
    });

    test('refuses anything that is not a 100-mark score', () {
      expect(scoreFromText('优秀'), isNull);
      expect(scoreFromText('合格'), isNull);
      expect(scoreFromText('W·中期退课'), isNull);
      expect(scoreFromText('缺考'), isNull);
      expect(scoreFromText(''), isNull);
      expect(scoreFromText('101'), isNull);
    });
  });
}
