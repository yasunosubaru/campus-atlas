import '../../core/result.dart';

/// Six-dimension rating aggregates for a course.
///
/// The upstream field set is fixed and verified against the live API:
/// `average_rating`, `average_difficulty`, `average_teaching_quality`,
/// `average_workload`, `average_course_interest`, `average_rating_difficult`,
/// plus `review_count`.
///
/// Every value is a double on the server but arrives as an int-typed JSON
/// number when whole, so all reads go through [asDouble].
class CourseRating {
  const CourseRating({
    this.rating = 0,
    this.difficulty = 0,
    this.teachingQuality = 0,
    this.workload = 0,
    this.courseInterest = 0,
    this.ratingDifficult = 0,
    this.reviewCount = 0,
    this.relevanceScore,
  });

  final double rating;
  final double difficulty;
  final double teachingQuality;
  final double workload;
  final double courseInterest;
  final double ratingDifficult;
  final int reviewCount;
  final double? relevanceScore;

  /// True when at least one review exists. The upstream service currently
  /// returns a fully-populated course record with all zeros, so "has reviews"
  /// has to be decided by the count, not by the presence of the fields.
  bool get hasReviews => reviewCount > 0;

  /// True when the record is a placeholder with no review data behind it.
  bool get isEmpty => reviewCount == 0;

  factory CourseRating.fromJson(Map<String, Object?> json) => CourseRating(
        rating: asDouble(json['average_rating']),
        difficulty: asDouble(json['average_difficulty']),
        teachingQuality: asDouble(json['average_teaching_quality']),
        workload: asDouble(json['average_workload']),
        courseInterest: asDouble(json['average_course_interest']),
        ratingDifficult: asDouble(json['average_rating_difficult']),
        reviewCount: asInt(json['review_count']) ?? 0,
        relevanceScore: json['relevance_score'] == null
            ? null
            : asDouble(json['relevance_score']),
      );

  static const CourseRating empty = CourseRating();
}

/// A course as returned by `/api/v1/search/simple`.
///
/// Field set verified against a live 200 response.
class CourseSummary {
  const CourseSummary({
    required this.uid,
    required this.name,
    this.publicUid = '',
    this.code = '',
    this.department = '',
    this.credits = 0,
    this.examMethod = '',
    this.gradingMethod = '',
    this.attendancePolicy = '',
    this.courseContent = '',
    this.prerequisites = '',
    this.electiveField = '',
    this.semester = '',
    this.rating = CourseRating.empty,
  });

  final String uid;
  final String name;
  final String publicUid;
  final String code;
  final String department;
  final int credits;
  final String examMethod;
  final String gradingMethod;
  final String attendancePolicy;
  final String courseContent;
  final String prerequisites;
  final String electiveField;
  final String semester;
  final CourseRating rating;

  static Result<CourseSummary> fromJson(Map<String, Object?> json) {
    final uid = json['course_uid'];
    final name = json['name'];
    if (uid is! String || name is! String) {
      return Failure<CourseSummary>.reason(
        FailureKind.invalidData,
        message: 'course record missing course_uid or name',
      );
    }
    return Success(
      CourseSummary(
        uid: uid,
        name: name,
        publicUid:
            json['public_uid'] is String ? json['public_uid']! as String : '',
        code: json['code'] is String ? json['code']! as String : '',
        department:
            json['department'] is String ? json['department']! as String : '',
        credits: asInt(json['credits']) ?? 0,
        examMethod:
            json['exam_method'] is String ? json['exam_method']! as String : '',
        gradingMethod: json['grading_method'] is String
            ? json['grading_method']! as String
            : '',
        attendancePolicy: json['attendance_policy'] is String
            ? json['attendance_policy']! as String
            : '',
        courseContent: json['course_content'] is String
            ? json['course_content']! as String
            : '',
        prerequisites: json['prerequisites'] is String
            ? json['prerequisites']! as String
            : '',
        electiveField: json['elective_field'] is String
            ? json['elective_field']! as String
            : '',
        semester: json['semester'] is String ? json['semester']! as String : '',
        rating: CourseRating.fromJson(json),
      ),
    );
  }
}

/// One teaching-class row from the master timetable search.
///
/// This is the authoritative schedule source: `day_of_week` is 1..7 with
/// 1 = Monday, `start_section`/`end_section` are 1-based period indices, and
/// `weeks` uses the compact `1-4,6-16` notation.
class MasterCourse {
  const MasterCourse({
    required this.id,
    required this.name,
    required this.dayOfWeek,
    required this.startSection,
    required this.endSection,
    required this.weeks,
    this.code = '',
    this.teacherName = '',
    this.department = '',
    this.courseType = '',
    this.room = '',
    this.building = '',
    this.campus = '',
    this.credits = 0,
    this.year = 0,
    this.semester = '',
  });

  final int id;
  final String name;
  final int dayOfWeek;
  final int startSection;
  final int endSection;

  /// Raw week expression exactly as the service returns it, e.g. `1-4,6-16`.
  final String weeks;

  final String code;
  final String teacherName;
  final String department;
  final String courseType;
  final String room;
  final String building;
  final String campus;
  final int credits;
  final int year;
  final String semester;

  static Result<MasterCourse> fromJson(Map<String, Object?> json) {
    final id = asInt(json['id']);
    final name = json['name'];
    final day = asInt(json['day_of_week']);
    final start = asInt(json['start_section']);
    final end = asInt(json['end_section']);

    if (id == null ||
        name is! String ||
        day == null ||
        start == null ||
        end == null) {
      return Failure<MasterCourse>.reason(
        FailureKind.invalidData,
        message: 'master course row missing id/name/day/sections',
      );
    }

    return Success(
      MasterCourse(
        id: id,
        name: name,
        dayOfWeek: day,
        startSection: start,
        endSection: end,
        weeks: json['weeks'] is String ? json['weeks']! as String : '',
        code: json['code'] is String ? json['code']! as String : '',
        teacherName: json['teacher_name'] is String
            ? json['teacher_name']! as String
            : '',
        department:
            json['department'] is String ? json['department']! as String : '',
        courseType:
            json['course_type'] is String ? json['course_type']! as String : '',
        room: json['room'] is String ? json['room']! as String : '',
        building: json['building'] is String ? json['building']! as String : '',
        campus: json['campus'] is String ? json['campus']! as String : '',
        credits: asInt(json['credits']) ?? 0,
        year: asInt(json['year']) ?? 0,
        semester: json['semester'] is String ? json['semester']! as String : '',
      ),
    );
  }
}

/// Uniform paging envelope: `{items|results, total, page, limit, has_more}`.
class ResultPage<T> {
  const ResultPage({
    required this.items,
    required this.total,
    this.page = 1,
    this.limit = 20,
    this.hasMore = false,
    this.extra = const {},
  });

  final List<T> items;
  final int total;
  final int page;
  final int limit;
  final bool hasMore;

  /// Response fields that are not part of the envelope, kept for display
  /// (e.g. `engine_type`, `scope`, `query`, `revision`).
  final Map<String, Object?> extra;

  bool get isEmpty => items.isEmpty;

  /// Parses the standard `{items, total, page, limit, has_more, ...}` envelope.
  ///
  /// [parseItem] may return null for a row that fails validation; such rows are
  /// skipped rather than failing the whole page, because one malformed course
  /// should not blank out an otherwise good list.
  static ResultPage<T> fromJson<T>(
    Map<String, Object?> json,
    T? Function(Map<String, Object?> raw) parseItem,
  ) {
    final rawItems = json['items'];
    final items = <T>[];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is Map<String, Object?>) {
          final parsed = parseItem(raw);
          if (parsed != null) items.add(parsed);
        }
      }
    }
    return ResultPage<T>(
      items: items,
      total: asInt(json['total']) ?? items.length,
      page: asInt(json['page']) ?? 1,
      limit: asInt(json['limit']) ?? 20,
      hasMore: json['has_more'] == true,
      extra: Map<String, Object?>.from(json)
        ..remove('items')
        ..remove('total')
        ..remove('page')
        ..remove('limit')
        ..remove('has_more'),
    );
  }
}

double asDouble(Object? v) {
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

int? asInt(Object? v) {
  if (v is int) return v;
  if (v is double) return v.round();
  if (v is String) return int.tryParse(v);
  return null;
}
