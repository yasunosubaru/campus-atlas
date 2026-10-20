import 'package:campus_atlas/features/grades_query/jwgl/jwgl_grade_grid.dart';
import 'package:flutter_test/flutter_test.dart';

/// The columns here are **the ones the live 学生成绩查询 grid actually has**, read
/// off `table.ui-jqgrid-htable` as `th.id` → label pairs. So the parser is tested
/// against the real shape rather than a convenient invention.
const List<(String, String)> _columns = [
  ('xnmmc', '学年'),
  ('xqmmc', '学期'),
  ('kch', '课程代码'),
  ('kcmc', '课程名称'),
  ('kcxzmc', '课程性质'),
  ('xf', '学分'),
  ('cjbz', '成绩备注'),
  ('jd', '绩点'),
  ('ksxz', '成绩性质'),
  ('sfxwkc', '是否学位课程'),
  ('kkbmmc', '开课学院'),
  ('kcbj', '课程标记'),
  ('kclbmc', '课程类别'),
  ('kcgsmc', '课程归属'),
  ('jxbmc', '教学班'),
  ('jsxm', '任课教师'),
  ('khfsmc', '考核方式'),
  ('xh', '学号'),
  ('xm', '姓名'),
  ('xsbjmc', '学生标记'),
  ('wlkkxq', '未来开课学期'),
  ('cj', '成绩'),
  ('cjsfzf', '是否成绩作废'),
  ('jysmc', '教研室'),
  ('xfjd', '学分绩点'),
];

void main() {
  Map<String, Object?> payload({
    List<(String, String)>? columns,
    List<List<String>>? rows,
    String notice = '',
  }) {
    final cols = columns ?? _columns;
    return {
      'url': 'https://jwgl.whu.edu.cn/cjcx/cjcx_cxDgXscj.html?gnmkdm=N305005',
      'title': '学生成绩查询',
      'gridId': 'tabGrid',
      'notice': notice,
      'fields': cols.map((c) => c.$1).toList(),
      'head': cols.map((c) => c.$2).toList(),
      'rows': rows ??
          [
            _row(
              year: '2025-2026',
              course: '数字信号处理',
              kind: '专业教育必修',
              credits: '3.0',
              point: '4.0',
              instructor: '陈小莉',
              score: '92',
            ),
            _row(
              year: '2025-2026',
              course: '高等数学D',
              kind: '公共基础必修',
              credits: '5.0',
              point: '3.7',
              instructor: '黄学英',
              score: '85',
            ),
          ],
    };
  }

  group('the extraction script', () {
    test('uses no Array.prototype helpers, because the page may replace them',
        () {
      // Measured on the live grade page, and this is the regression it pins: the
      // first version used `map`, `filter` and `some`, and the page threw
      // `cells.some is not a function`. 正方 is an old deployment that ships its
      // own compatibility scripts, so the built-in array methods are not
      // guaranteed to be the ones this project expects. Index loops and `push`
      // cannot be shadowed that way.
      for (final banned in const [
        '.map(',
        '.filter(',
        '.some(',
        '.forEach(',
        'Array.prototype',
      ]) {
        expect(gradeGridScript, isNot(contains(banned)),
            reason: 'the script uses $banned');
      }
    });

    test('the run wrapper clears the answer first and traps a throw', () {
      // Clearing first is what keeps a failed run from being read as the previous
      // run's answer, and the inner try is what turns a throw into something the
      // person can read instead of an empty result.
      expect(gradeGridRunScript, contains('window.$gradeGridVariable = null;'));
      expect(gradeGridRunScript, contains('catch (e)'));
      expect(gradeGridRunScript, contains('the script threw'));
    });

    test('the answer is read from a variable, not from a return value', () {
      // WebView2 reports a script with no completion value as the four characters
      // `null`, which is indistinguishable from a real `null` answer. The app
      // reads the variable back instead; see the constant's docs.
      expect(gradeGridVariable, startsWith('__campusAtlas'));
      expect(gradeGridRunScript, contains('window.$gradeGridVariable ='));
    });
  });

  group('reading a grid', () {
    test('counts the rows and keeps the header', () {
      final grid = JwglGradeGrid.tryParse(payload())!;

      expect(grid.isEmpty, isFalse);
      expect(grid.rows, hasLength(2));
      expect(grid.gridId, 'tabGrid');
      expect(grid.head, contains('课程名称'));
      expect(grid.labelAt(3), '课程名称');
      expect(grid.fieldAt(3), 'kcmc');
    });

    test('a field is preferred over a label that merely contains it', () {
      // The trap this test exists for: `学分` is a substring of `学分绩点`, so a
      // label match alone would put 学分绩点 (index 24) before 学分 (index 5).
      final grid = JwglGradeGrid.tryParse(payload())!;

      expect(grid.indexOfField('xf'), 5);
      expect(grid.columnFor('xf', '学分'), 5);
      expect(grid.columnsLike(const ['学分']), [5, 24]);
      expect(grid.columnFor('xfjd', '学分绩点'), 24);
    });

    test('a row is read through its field names', () {
      final grid = JwglGradeGrid.tryParse(payload())!;
      final row = grid.rows.first;

      expect(grid.valueOf('kcmc', row), '数字信号处理');
      expect(grid.valueOf('jsxm', row), '陈小莉');
      expect(grid.valueOf('cj', row), '92');
      expect(grid.valueOf('jd', row), '4.0');
      expect(grid.valueOf('xf', row), '3.0');
      expect(grid.valueOf('xfjd', row), '92.0');
    });

    test('field maps keep the grid own names, label maps keep the labels', () {
      final grid = JwglGradeGrid.tryParse(payload())!;

      expect(grid.asFieldMaps.first['kcmc'], '数字信号处理');
      expect(grid.asFieldMaps.first['cj'], '92');
      expect(grid.asMaps.first['课程名称'], '数字信号处理');
      expect(grid.asMaps.first['成绩'], '92');
    });

    test('an unknown field is refused rather than resolved by guesswork', () {
      final grid = JwglGradeGrid.tryParse(payload())!;

      expect(grid.valueOf('nope', grid.rows.first, labelNeedle: '也不存在'), '');
      expect(grid.columnFor('nope', '也不存在'), -1);
    });

    test('the grid own empty notice is carried through', () {
      // `请选择筛选条件!` (query not run yet) and `无数据显示` (query ran, nothing
      // found) call for different things from the person, so neither is invented.
      final grid = JwglGradeGrid.tryParse(
        payload(rows: const [], notice: '请选择筛选条件!'),
      )!;

      expect(grid.isEmpty, isTrue);
      expect(grid.notice, '请选择筛选条件!');
      expect(grid.summary, contains('请选择筛选条件!'));
      expect(grid.summary, contains('0 行'));
    });

    test('a label-only grid still reads, positionally', () {
      // No `fields`: the header survived but the field names did not. The rows
      // must still be usable rather than dropped.
      final grid = JwglGradeGrid.tryParse({
        'head': const ['成绩', '绩点'],
        'rows': const [
          ['92', '4.0'],
        ],
      })!;

      expect(grid.valueOf('cj', grid.rows.first, labelNeedle: '成绩'), '92');
      expect(grid.labelAt(0), '成绩');
    });

    test('a header-less grid yields positional labels', () {
      final grid = JwglGradeGrid.tryParse({
        'head': const <String>[],
        'rows': const [
          ['92', '4.0'],
        ],
      })!;

      expect(grid.labelAt(0), '第1列');
      expect(grid.asMaps.single['第2列'], '4.0');
    });

    test('a payload that is not a grid is refused, not guessed at', () {
      expect(JwglGradeGrid.tryParse(null), isNull);
      expect(JwglGradeGrid.tryParse('nope'), isNull);
      // The script's own error envelope. Inventing an empty grid here would hide
      // the failure behind "no data".
      expect(JwglGradeGrid.tryParse(const {'error': 'no table with rows'}),
          isNull);
    });

    test('rows shorter or longer than the header do not throw', () {
      final grid = JwglGradeGrid.tryParse({
        'head': const ['a', 'b'],
        'fields': const ['fa', 'fb'],
        'rows': const [
          ['1'],
          ['1', '2', '3'],
        ],
      })!;

      expect(grid.rows, hasLength(2));
      expect(grid.asMaps.first.length, 1);
      expect(grid.asMaps.last.length, 3);
      expect(grid.valueOf('fb', grid.rows.first), '');
    });
  });
}

/// A row with every column of [_columns] filled, so a test that reads one field
/// is reading it at the position the live grid would put it.
List<String> _row({
  required String year,
  required String course,
  required String kind,
  required String credits,
  required String point,
  required String instructor,
  required String score,
}) =>
    [
      year, // xnmmc
      '1', // xqmmc
      '3350130015302', // kch
      course, // kcmc
      kind, // kcxzmc
      credits, // xf
      '', // cjbz 成绩备注
      point, // jd
      '正常', // ksxz
      '是', // sfxwkc
      '电子信息学院', // kkbmmc
      '', // kcbj
      '专业课', // kclbmc
      '专业课', // kcgsmc
      '$course教学班', // jxbmc
      instructor, // jsxm
      '考试', // khfsmc
      'STUDENT-0000', // xh
      '', // xm 姓名
      '', // xsbjmc
      '', // wlkkxq
      score, // cj
      '否', // cjsfzf
      '', // jysmc
      '92.0', // xfjd
    ];
