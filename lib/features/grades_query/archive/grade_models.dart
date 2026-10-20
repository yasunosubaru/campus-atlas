/// A grade row archived on this machine.
///
/// ## Why an archive exists
///
/// Reading grades out of the academic system costs a sign-in, and on this
/// deployment a slider puzzle that a person clears by hand. Paying that once and
/// keeping the result is what makes GPA, term trends and statistics instant —
/// and it is also the seam every import channel shares: a channel only has to
/// produce [GradeRecord]s, and the statistics do not care where they came from.
///
/// ## What is deliberately not stored
///
/// Nothing identifying: no student id, no name. The live grade table carries
/// both (`xh` / `xm`), and neither is needed to compute a GPA. Only the
/// course-level fields below are persisted.
library;

import '../../../core/result.dart';

/// One course grade.
class GradeRecord {
  const GradeRecord({
    required this.year,
    required this.semester,
    required this.courseName,
    this.courseCode = '',
    this.teacher = '',
    this.courseKind = '',
    this.credits = 0,
    this.scoreText = '',
    this.score,
    this.gradePoint,
    this.source = 'jwgl',
  });

  /// Academic year as the system words it, e.g. `2025-2026`.
  final String year;

  /// Term as the system words it: `1`, `2`, `第一学期`, …
  final String semester;

  final String courseName;
  final String courseCode;
  final String teacher;

  /// Course nature (`必修` / `选修` / …) — the basis of the "compulsory only"
  /// scope, so it is kept verbatim rather than normalised.
  final String courseKind;

  final double credits;

  /// The score exactly as displayed: `90`, `优秀`, `W·中期退课`.
  final String scoreText;

  /// The numeric score when the row is on the 100-mark scale; null for
  /// level-graded rows (优秀 / 合格 / 退课), which cannot enter a GPA.
  final double? score;

  /// The grade point the system itself reported (`绩点` column), when present.
  ///
  /// Kept for honesty and future cross-checks; the computed statistics derive
  /// their own points from [score], so a row whose system point disagrees with
  /// the chosen algorithm still computes the way the algorithm says.
  final double? gradePoint;

  /// Which channel produced this row. `jwgl` today; a 研究生-system import and
  /// a manual entry are the planned siblings.
  final String source;

  /// Identity for merge purposes: one grade per course per term.
  ///
  /// The course code is preferred when the system provides it; the name is the
  /// fallback, because a row without a code would otherwise merge into every
  /// other codeless row of its term.
  String get key =>
      '$year|$semester|${courseCode.isNotEmpty ? courseCode : courseName}';

  /// First year of the academic year, for chronological ordering. `0` when the
  /// year is missing, which sorts it first rather than dropping the row.
  int get yearStart => yearStartOf(year);

  /// Term number within the year. Handles `1` and `第一学期` alike; `0` when
  /// unknown.
  int get semesterNumber => semesterNumberOf(semester);

  /// `2025-2026 1` — how a term is shown.
  String get termLabel => [year, semester].where((s) => s.isNotEmpty).join(' ');

  /// `25-26·1` — a short form for a chart axis.
  String get shortTermLabel => shortTermLabelOf(year, semester);

  /// Chronological order: by year, then by term.
  static int compare(GradeRecord a, GradeRecord b) {
    final byYear = a.yearStart.compareTo(b.yearStart);
    if (byYear != 0) return byYear;
    final byTerm = a.semesterNumber.compareTo(b.semesterNumber);
    if (byTerm != 0) return byTerm;
    return a.courseName.compareTo(b.courseName);
  }

  GradeRecord copyWith({
    String? year,
    String? semester,
    String? courseName,
    String? courseCode,
    String? teacher,
    String? courseKind,
    double? credits,
    String? scoreText,
    double? score,
    double? gradePoint,
    String? source,
  }) =>
      GradeRecord(
        year: year ?? this.year,
        semester: semester ?? this.semester,
        courseName: courseName ?? this.courseName,
        courseCode: courseCode ?? this.courseCode,
        teacher: teacher ?? this.teacher,
        courseKind: courseKind ?? this.courseKind,
        credits: credits ?? this.credits,
        scoreText: scoreText ?? this.scoreText,
        score: score ?? this.score,
        gradePoint: gradePoint ?? this.gradePoint,
        source: source ?? this.source,
      );

  Map<String, Object?> toJson() => {
        'year': year,
        'semester': semester,
        'courseName': courseName,
        'courseCode': courseCode,
        'teacher': teacher,
        'courseKind': courseKind,
        'credits': credits,
        'scoreText': scoreText,
        'score': score,
        'gradePoint': gradePoint,
        'source': source,
      };

  static Result<GradeRecord> fromJson(Map<String, Object?> json) {
    final year = json['year'];
    final semester = json['semester'];
    final name = json['courseName'];
    if (year is! String || semester is! String || name is! String) {
      return Failure<GradeRecord>.reason(
        FailureKind.invalidData,
        message: 'GradeRecord JSON is missing year/semester/courseName',
      );
    }
    return Success(
      GradeRecord(
        year: year,
        semester: semester,
        courseName: name,
        courseCode:
            json['courseCode'] is String ? json['courseCode']! as String : '',
        teacher: json['teacher'] is String ? json['teacher']! as String : '',
        courseKind:
            json['courseKind'] is String ? json['courseKind']! as String : '',
        credits:
            json['credits'] is num ? (json['credits']! as num).toDouble() : 0,
        scoreText:
            json['scoreText'] is String ? json['scoreText']! as String : '',
        score: json['score'] is num ? (json['score']! as num).toDouble() : null,
        gradePoint: json['gradePoint'] is num
            ? (json['gradePoint']! as num).toDouble()
            : null,
        source: json['source'] is String ? json['source']! as String : 'jwgl',
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GradeRecord &&
      other.year == year &&
      other.semester == semester &&
      other.courseName == courseName &&
      other.courseCode == courseCode &&
      other.teacher == teacher &&
      other.courseKind == courseKind &&
      other.credits == credits &&
      other.scoreText == scoreText &&
      other.score == score &&
      other.gradePoint == gradePoint &&
      other.source == source;

  @override
  int get hashCode => Object.hash(
        year,
        semester,
        courseName,
        courseCode,
        teacher,
        courseKind,
        credits,
        scoreText,
        score,
        gradePoint,
        source,
      );
}

/// First year of an academic-year string like `2025-2026`; `0` when absent.
int yearStartOf(String year) {
  final match = RegExp(r'(\d{4})').firstMatch(year);
  return match == null ? 0 : int.parse(match.group(1)!);
}

/// Term number for `1` and `第一学期` alike; `0` when unknown.
int semesterNumberOf(String semester) {
  final digit = RegExp(r'\d+').firstMatch(semester);
  if (digit != null) return int.parse(digit.group(0)!);
  if (semester.contains('一')) return 1;
  if (semester.contains('二')) return 2;
  if (semester.contains('三')) return 3;
  return 0;
}

/// `25-26·1` — the short axis label for a term.
String shortTermLabelOf(String year, String semester) {
  final start = yearStartOf(year);
  final head = start == 0 ? year : '${start % 100}-${(start + 1) % 100}';
  final tail = semesterNumberOf(semester) > 0
      ? '${semesterNumberOf(semester)}'
      : semester;
  return [head, tail].where((s) => s.isNotEmpty).join('·');
}
