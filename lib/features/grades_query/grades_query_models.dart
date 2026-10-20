/// Models for the teacher-grade and evaluation query.
///
/// ⚠️ **Schema status.** The four endpoints these read are **auth-walled**:
///
///   GET /api/v1/course/grades/by-name    → 401 {"status":401,"code":"UNAUTHORIZED"}
///   GET /api/v1/course/grades/view/       → 404 (needs a path parameter)
///   GET /api/v1/course/grades/teachers/    → 404 (needs a path parameter)
///   GET /api/v1/course/grades/resolve     → (needs a path parameter)
///
/// Their purpose is documented verbatim in the recovered strings, so the
/// *shape* of the feature is known, but **no response body was ever captured**
/// because reaching one needs the reader's own account. Every field name below
/// is therefore a *candidate* chosen from the strings, and every parser accepts
/// several aliases and preserves the untouched payload in [raw]. When the first
/// real response arrives, tighten these parsers to the actual keys instead of
/// widening the alias lists further.
library;

/// One bar in a grade distribution.
///
/// [GradePointBucket] — the name the recovered strings use for exactly this.
class GradeBucket {
  const GradeBucket({
    required this.label,
    this.count = 0,
    this.percentage = 0,
    this.raw = const {},
  });

  /// The grade band, e.g. `优`, `良`, `90-100`, `A`.
  final String label;

  /// How many students landed in [label].
  final int count;

  /// Share of the course's students, 0..100.
  final double percentage;

  /// The payload this was parsed from, unmodified.
  final Map<String, Object?> raw;

  /// Widest alias set of any parser here, because this is the field whose name
  /// could least be inferred from the strings.
  static GradeBucket? tryParse(Object? raw) {
    if (raw is! Map) return null;

    final label = _text(raw, const [
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
    ]);
    if (label == null || label.isEmpty) return null;

    return GradeBucket(
      label: label,
      count: _int(raw, const [
        'count',
        'total',
        'students',
        'student_count',
        'studentCount',
        'num',
        'n',
        'number',
        'value',
      ]),
      percentage: _double(raw, const [
        'percentage',
        'percent',
        'ratio',
        'pct',
        'rate',
        'proportion',
        'share',
      ]),
      raw: Map<String, Object?>.from(raw),
    );
  }

  /// Whether this is a pass-grade band rather than a fail one.
  ///
  /// Only used to colour the bar, so it errs toward "looks like a pass": an
  /// unrecognised label is treated as neutral rather than as a failure.
  bool get looksLikeFail {
    final l = label.toLowerCase();
    return l.contains('不及格') ||
        l.contains('不合格') ||
        l.startsWith('f') ||
        l.contains('fail');
  }
}

/// What one teacher gives on one course offering.
class TeacherGrade {
  const TeacherGrade({
    required this.id,
    required this.name,
    this.courseName = '',
    this.department = '',
    this.courseCode = '',
    this.distribution = const <GradeBucket>[],
    this.reviewCount = 0,
    this.rating = 0,
    this.difficulty = 0,
    this.teachingQuality = 0,
    this.workload = 0,
    this.gradingScore = 0,
    this.raw = const {},
  });

  /// Stable id for this offering — what `view/` takes.
  final String id;
  final String name;
  final String courseName;
  final String department;
  final String courseCode;
  final List<GradeBucket> distribution;
  final int reviewCount;

  /// The six average fields, when the payload carries them.
  final double rating;
  final double difficulty;
  final double teachingQuality;
  final double workload;

  /// The upstream `average_rating_difficult` field.
  ///
  /// ⚠️ **Its direction is unverified.** The key reads as "difficulty of the
  /// grade", which would mean a *higher* value is *harder* grading — the
  /// opposite of what a reader hopes. This class deliberately does **not**
  /// invert it: inverting would bake an unconfirmed guess into the number, so
  /// the UI shows it with a plain label rather than a "more is better" framing.
  /// Confirm the direction against one real response before labelling it.
  final double gradingScore;

  /// The payload this was parsed from, unmodified.
  final Map<String, Object?> raw;

  bool get hasDistribution => distribution.isNotEmpty;

  /// Total students across the buckets, if the buckets carry counts.
  int get bucketTotal => distribution.fold(0, (a, b) => a + b.count);

  static TeacherGrade? tryParse(Object? raw) {
    if (raw is! Map) return null;

    final id = _id(raw, const [
      'id',
      'teacher_id',
      'teacherId',
      'offering_id',
      'offeringId',
      'uid',
    ]);
    final name = _text(raw, const [
      'teacher_name',
      'teacherName',
      'name',
      'teacher',
    ]);
    // A teacher row without a name is unusable; one without an id still is, so
    // only the name is required.
    if (id == null || id.isEmpty || name == null || name.isEmpty) return null;

    final dist = <GradeBucket>[];
    for (final key in const [
      'distribution',
      'grade_distribution',
      'gradeDistribution',
      'buckets',
      'grades',
      'items',
    ]) {
      final v = raw[key];
      if (v is List) {
        for (final b in v) {
          final parsed = GradeBucket.tryParse(b);
          if (parsed != null) dist.add(parsed);
        }
        break;
      }
    }

    return TeacherGrade(
      id: id,
      name: name,
      courseName: _text(raw, const ['course_name', 'courseName', 'kcmc']) ?? '',
      department: _text(raw, const ['department', 'kkbmmc', 'college']) ?? '',
      courseCode: _text(raw, const ['course_code', 'code', 'kch']) ?? '',
      distribution: dist,
      reviewCount: _int(raw, const [
        'review_count',
        'reviewCount',
        'reviews',
        'comment_count',
      ]),
      rating: _double(raw, const ['average_rating', 'averageRating', 'rating']),
      difficulty:
          _double(raw, const ['average_difficulty', 'averageDifficulty']),
      teachingQuality:
          _double(raw, const ['average_teaching_quality', 'teaching_quality']),
      workload: _double(raw, const ['average_workload', 'average_work_load']),
      gradingScore: _double(raw, const [
        'average_rating_difficult',
        'averageRatingDifficult',
        'grade_generous',
      ]),
      raw: Map<String, Object?>.from(raw),
    );
  }
}

/// A course and every teacher who teaches it, for the query screen.
class CourseGrades {
  const CourseGrades({
    required this.uid,
    required this.name,
    this.teachers = const <TeacherGrade>[],
    this.raw = const {},
  });

  final String uid;
  final String name;
  final List<TeacherGrade> teachers;

  /// The payload this was parsed from, unmodified.
  final Map<String, Object?> raw;

  bool get isEmpty => teachers.isEmpty;

  static CourseGrades? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final name =
        _text(raw, const ['name', 'course_name', 'courseName', 'kcmc']);
    if (name == null || name.isEmpty) return null;

    final uid =
        _id(raw, const ['course_uid', 'courseUid', 'uid', 'id', 'code']);

    final teachers = <TeacherGrade>[];
    for (final key in const [
      'teachers',
      'offerings',
      'teaching_classes',
      'items',
      'results',
    ]) {
      final v = raw[key];
      if (v is List) {
        for (final t in v) {
          final parsed = TeacherGrade.tryParse(t);
          if (parsed != null) teachers.add(parsed);
        }
        break;
      }
    }

    return CourseGrades(
      uid: uid ?? name,
      name: name,
      teachers: teachers,
      raw: Map<String, Object?>.from(raw),
    );
  }
}

/// One review text entry.
class CourseReview {
  const CourseReview({
    required this.id,
    this.text = '',
    this.rating = 0,
    this.teacherName = '',
    this.createdAt,
    this.raw = const {},
  });

  final String id;
  final String text;
  final double rating;
  final String teacherName;
  final DateTime? createdAt;

  /// The payload this was parsed from, unmodified.
  final Map<String, Object?> raw;

  static CourseReview? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = _id(raw, const [
      'id',
      'review_id',
      'reviewId',
      'uid',
    ]);
    if (id == null || id.isEmpty) return null;

    DateTime? at;
    final when = raw['created_at'] ?? raw['createdAt'] ?? raw['time'];
    if (when is String) at = DateTime.tryParse(when);

    return CourseReview(
      id: id,
      text: _text(raw, const [
            'content',
            'comment',
            'text',
            'review',
            'body',
            'description',
          ]) ??
          '',
      rating: _double(raw, const ['rating', 'score', 'average_rating']),
      teacherName:
          _text(raw, const ['teacher_name', 'teacherName', 'teacher']) ?? '',
      createdAt: at,
      raw: Map<String, Object?>.from(raw),
    );
  }
}

// --------------------------------------------------------------- extraction

String? _text(Map<dynamic, dynamic> row, List<String> keys) {
  for (final k in keys) {
    final v = row[k];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    // A numeric label is a real possibility here, not a hypothetical: the
    // contract's own type name is `CourseReviewGradePointBucket`, and a grade
    // point arrives as a number more often than as a string.
    if (v is num) return '$v';
  }
  return null;
}

String? _id(Map<dynamic, dynamic> row, List<String> keys) {
  for (final k in keys) {
    final v = row[k];
    if (v == null) continue;
    if (v is String && v.trim().isNotEmpty) return v.trim();
    if (v is num) return '$v';
  }
  return null;
}

int _int(Map<dynamic, dynamic> row, List<String> keys) {
  for (final k in keys) {
    final v = row[k];
    if (v is num) return v.toInt();
    if (v is String) {
      final n = int.tryParse(v.trim());
      if (n != null) return n;
    }
  }
  return 0;
}

double _double(Map<dynamic, dynamic> row, List<String> keys) {
  for (final k in keys) {
    final v = row[k];
    if (v is num) return v.toDouble();
    if (v is String) {
      final n = double.tryParse(v.trim());
      if (n != null) return n;
    }
  }
  return 0;
}
