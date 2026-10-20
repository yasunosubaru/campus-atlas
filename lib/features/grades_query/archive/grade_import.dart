/// Turning a read grade grid into [GradeRecord]s.
///
/// Field names first, labels as the fallback — the same order the reader screen
/// uses, and for the same reason: `学分` is a substring of `学分绩点`, so label
/// matching alone can pick the wrong column while the field is right there.
/// The field set (`kcmc`, `cj`, `jd`, `xnmmc`, `xqmmc`, …) was read off the live
/// grid on 2026-10-18; see `docs/grades-and-reviews.md` §5.6.
library;

import '../jwgl/jwgl_grade_grid.dart';
import 'grade_models.dart';

/// Converts every usable row of [grid] into a [GradeRecord].
///
/// A row without a course name is skipped: it is a spacer or a rendering
/// artefact, not a grade. Everything else is kept even when it cannot enter a
/// GPA (退课, 等级制), because the archive is a record of what the system said,
/// not only of what the statistics can use.
List<GradeRecord> recordsFromGrid(JwglGradeGrid grid) {
  final nameIndex = grid.columnFor(JwglGradeFields.courseName, '课程名称');
  final codeIndex = grid.columnFor(JwglGradeFields.courseCode, '课程代码');
  final teacherIndex = grid.columnFor(JwglGradeFields.instructor, '任课教师');
  final creditsIndex = grid.columnFor(JwglGradeFields.credits, '学分');
  final scoreIndex = grid.columnFor(JwglGradeFields.score, '成绩');
  final pointIndex = grid.columnFor(JwglGradeFields.gradePoint, '绩点');
  final kindIndex = grid.columnFor(JwglGradeFields.courseKind, '课程性质');
  final yearIndex = grid.columnFor(JwglGradeFields.year, '学年');
  final termIndex = grid.columnFor(JwglGradeFields.term, '学期');

  String cell(List<String> row, int index) =>
      index >= 0 && index < row.length ? row[index].trim() : '';

  final out = <GradeRecord>[];
  for (final row in grid.rows) {
    final name = cell(row, nameIndex);
    if (name.isEmpty) continue;

    final scoreText = cell(row, scoreIndex);
    out.add(
      GradeRecord(
        year: cell(row, yearIndex),
        semester: cell(row, termIndex),
        courseName: name,
        courseCode: cell(row, codeIndex),
        teacher: cell(row, teacherIndex),
        courseKind: cell(row, kindIndex),
        credits: _creditsOf(cell(row, creditsIndex)),
        scoreText: scoreText,
        score: scoreFromText(scoreText),
        gradePoint: _numberOf(cell(row, pointIndex)),
        source: 'jwgl',
      ),
    );
  }
  return out;
}

/// The numeric score behind [text], or null when the row is not on the
/// 100-mark scale.
///
/// Deliberately strict: `优秀`, `合格`, `W·中期退课`, `缺考` and an empty cell
/// all answer null. A loose parse would turn `优秀` into a fail-sized 0 and
/// quietly drag a GPA down.
double? scoreFromText(String text) {
  final value = double.tryParse(text.trim());
  if (value == null) return null;
  if (value < 0 || value > 100) return null;
  return value;
}

/// Credits tolerate a stray unit-less value; anything unparsable is 0 and the
/// row is then excluded from weighting rather than weighted as if it had none.
double _creditsOf(String text) => double.tryParse(text.trim()) ?? 0;

double? _numberOf(String text) => double.tryParse(text.trim());
