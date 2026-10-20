import '../../core/config/app_config.dart';
import '../../core/network/api_client.dart';
import '../../core/result.dart';
import 'course_models.dart';

/// Term identifiers as the academic system encodes them.
/// Verified live: 3 = autumn, 12 = winter, 16 = summer.
enum Term {
  autumn('3', '秋季'),
  winter('12', '冬季'),
  summer('16', '夏季');

  const Term(this.code, this.label);
  final String code;
  final String label;

  static Term? fromCode(String code) {
    for (final t in Term.values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

/// One term's published revision of the master timetable.
class MasterTerm {
  const MasterTerm({
    required this.year,
    required this.term,
    required this.revision,
    required this.storedCount,
    this.publishedAt,
  });

  final int year;
  final Term term;
  final String revision;
  final int storedCount;
  final DateTime? publishedAt;

  static Result<MasterTerm> fromJson(Map<String, Object?> json) {
    final year = asInt(json['year']);
    final termCode = json['semester'];
    final term = termCode is String ? Term.fromCode(termCode) : null;
    if (year == null || term == null) {
      return Failure<MasterTerm>.reason(
        FailureKind.invalidData,
        message: 'period row missing year or unknown semester',
      );
    }
    return Success(
      MasterTerm(
        year: year,
        term: term,
        revision: json['revision'] is String ? json['revision']! as String : '',
        storedCount: asInt(json['stored_count']) ?? 0,
        publishedAt: DateTime.tryParse('${json['published_at'] ?? ''}'),
      ),
    );
  }
}

/// Read-only client for the public course / timetable catalogue.
///
/// Every method here is backed by an endpoint that was verified to answer
/// **200 without credentials**. Nothing in this repository touches an
/// authenticated surface, which is a deliberate boundary: personal data such
/// as the signed-in student's own transcript is not reachable from here.
class CourseRepository {
  CourseRepository({required this.client});

  final ApiClient client;

  /// Backend base. Overridable so tests and forks can point elsewhere.
  final Uri base = AppConfig.courseApi;

  // ------------------------------------------------------------- suggestions

  /// Autocomplete for the course box.
  ///
  /// Verified: `GET /api/v1/suggest/courses?q=高数` returns real course names
  /// and teacher names (`高等数学A1`, `高力`, `高洵`, ...).
  Future<Result<List<String>>> suggestCourses(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return Failure<List<String>>.reason(
        FailureKind.validation,
        message: 'Query must not be empty',
      );
    }
    final uri = Uri.parse('$base/api/v1/suggest/courses').replace(
      queryParameters: {'q': trimmed},
    );
    final raw = await client.getJson(uri);
    if (raw is Failure) return Failure<List<String>>(raw.errorOrNull!);

    final suggestions = raw.requireValue['suggestions'];
    if (suggestions is! List) {
      return Failure<List<String>>.reason(
        FailureKind.invalidData,
        message: 'suggest/courses missing suggestions[]',
      );
    }
    return Success(suggestions.whereType<String>().toList());
  }

  // --------------------------------------------------------- course reviews

  /// Course search carrying the six-dimension rating aggregates.
  ///
  /// Verified: `GET /api/v1/search/simple?query=...` → 200, envelope
  /// `{success, results: {courses: [...]}, total, page, limit, engine_type,
  /// query, scope}`. Note `results` is a *nested object* holding `courses`,
  /// which is why this does not go through [ResultPage.fromJson].
  ///
  /// The ratings are aggregates over all reviews of that course, so a teacher
  /// rating is a course-level figure, not a per-teacher one.
  Future<Result<ResultPage<CourseSummary>>> searchCourses(
    String query, {
    int page = 1,
    int limit = 20,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return Failure<ResultPage<CourseSummary>>.reason(
        FailureKind.validation,
        message: 'Query must not be empty',
      );
    }
    final uri = Uri.parse('$base/api/v1/search/simple').replace(
      queryParameters: {'query': trimmed, 'page': '$page', 'limit': '$limit'},
    );
    final raw = await client.getJson(uri);
    if (raw is Failure) {
      return Failure<ResultPage<CourseSummary>>(raw.errorOrNull!);
    }

    final payload = raw.requireValue;
    final results = payload['results'];
    final rawCourses =
        results is Map<String, Object?> ? results['courses'] : null;
    if (rawCourses is! List) {
      return Failure<ResultPage<CourseSummary>>.reason(
        FailureKind.invalidData,
        message: 'search/simple missing results.courses[]',
      );
    }

    final items = <CourseSummary>[];
    for (final row in rawCourses) {
      if (row is! Map<String, Object?>) continue;
      final parsed = CourseSummary.fromJson(row);
      if (parsed is Success) items.add(parsed.dataOrNull!);
    }

    return Success(
      ResultPage<CourseSummary>(
        items: items,
        total: asInt(payload['total']) ?? items.length,
        page: asInt(payload['page']) ?? page,
        limit: asInt(payload['limit']) ?? limit,
        hasMore: items.length < (asInt(payload['total']) ?? items.length),
        extra: Map<String, Object?>.from(payload)..remove('results'),
      ),
    );
  }

  // ------------------------------------------------------- master timetable

  /// The published revisions of the master timetable, newest first.
  ///
  /// Verified: `GET /api/v1/timetable/master/periods` → 200.
  Future<Result<List<MasterTerm>>> masterTerms() async {
    final raw = await client.getJson(
      Uri.parse('$base/api/v1/timetable/master/periods'),
    );
    if (raw is Failure) return Failure<List<MasterTerm>>(raw.errorOrNull!);

    final periods = raw.requireValue['periods'];
    if (periods is! List) {
      return Failure<List<MasterTerm>>.reason(
        FailureKind.invalidData,
        message: 'master/periods missing periods[]',
      );
    }
    final out = <MasterTerm>[];
    for (final row in periods) {
      if (row is! Map<String, Object?>) continue;
      final parsed = MasterTerm.fromJson(row);
      if (parsed is Success) out.add(parsed.dataOrNull!);
    }
    out.sort((a, b) {
      final byYear = b.year.compareTo(a.year);
      if (byYear != 0) return byYear;
      // Compare by enum position, not by the string code: sorting "12", "16",
      // "3" lexically would put winter/summer before autumn.
      return a.term.index.compareTo(b.term.index);
    });
    return Success(out);
  }

  /// Search the master timetable for one term.
  ///
  /// Verified: `GET /api/v1/timetable/master/search?year=&semester=[&q=][&limit=]`
  /// → 200 with envelope `{items, total, page, limit, has_more, revision}`.
  /// `year` and `semester` are mandatory; omitting either yields 422 naming
  /// the missing parameter.
  Future<Result<ResultPage<MasterCourse>>> searchMasterTimetable({
    required int year,
    required Term term,
    String query = '',
    int page = 1,
    int limit = 20,
  }) async {
    final params = <String, String>{
      'year': '$year',
      'semester': term.code,
      'page': '$page',
      'limit': '$limit',
    };
    final q = query.trim();
    if (q.isNotEmpty) params['q'] = q;

    final uri = Uri.parse('$base/api/v1/timetable/master/search')
        .replace(queryParameters: params);
    final raw = await client.getJson(uri);
    if (raw is Failure) {
      return Failure<ResultPage<MasterCourse>>(raw.errorOrNull!);
    }

    final payload = raw.requireValue;
    return Success(
      ResultPage.fromJson<MasterCourse>(
        payload,
        (row) {
          final parsed = MasterCourse.fromJson(row);
          return parsed is Success ? parsed.dataOrNull! : null;
        },
      ),
    );
  }

  /// Suggestions scoped to one term.
  ///
  /// Verified: `GET /api/v1/timetable/master/suggestions?q=&year=&semester=`
  ///
  /// **Two live behaviours this handles explicitly:**
  ///
  ///   * items are objects, not strings — a real response is
  ///     `{"value": "...", "label": "... · 1100860011 · 周国全", "kind":
  ///     "course", "course_code": "...", "teacher_name": "..."}`. Filtering
  ///     with `whereType<String>()` returns nothing at all, which reads as
  ///     "the suggestion box is empty" rather than as a parse failure.
  ///   * matching is a **prefix match on the full course name**: `大学物理`
  ///     yields 8, while `高数` yields 0 — 高数 is an abbreviation, not a
  ///     prefix of 高等数学. So the caller collects whatever was typed rather
  ///     than forwarding it as a filter.
  ///
  /// Contrast [suggestCourses], whose items genuinely are plain strings.
  Future<Result<List<MasterSuggestion>>> suggestMasterTimetable({
    required int year,
    required Term term,
    String query = '',
  }) async {
    final uri = Uri.parse('$base/api/v1/timetable/master/suggestions').replace(
      queryParameters: {
        'q': query.trim(),
        'year': '$year',
        'semester': term.code,
      },
    );
    final raw = await client.getJson(uri);
    if (raw.isFailure) {
      return Failure<List<MasterSuggestion>>(raw.errorOrNull!);
    }

    final suggestions = raw.requireValue['suggestions'];
    if (suggestions is! List) {
      return Failure<List<MasterSuggestion>>.reason(
        FailureKind.invalidData,
        message: 'master/suggestions missing suggestions[]',
      );
    }

    final out = <MasterSuggestion>[];
    for (final row in suggestions) {
      if (row is String) {
        // A bare string carries no teacher or course code, but is still worth
        // showing rather than dropping.
        out.add(MasterSuggestion(value: row, label: row));
        continue;
      }
      if (row is! Map<String, Object?>) continue;
      final value = row['value'];
      if (value is! String || value.isEmpty) continue;
      out.add(MasterSuggestion(
        value: value,
        label: row['label'] is String ? row['label']! as String : value,
        courseCode:
            row['course_code'] is String ? row['course_code']! as String : '',
        teacherName:
            row['teacher_name'] is String ? row['teacher_name']! as String : '',
      ));
    }
    return Success(out);
  }
}

/// One row from the master-timetable suggestion box.
///
/// [label] is the human-facing form — `大学物理A（下） · 1100860011 · 周国全` —
/// which is what tells two teaching classes of the same course apart, because
/// they differ only by teacher. [value] is what to search with: the bare course
/// name.
class MasterSuggestion {
  const MasterSuggestion({
    required this.value,
    required this.label,
    this.courseCode = '',
    this.teacherName = '',
  });

  final String value;
  final String label;
  final String courseCode;
  final String teacherName;

  bool get hasTeacher => teacherName.isNotEmpty;

  @override
  String toString() => 'MasterSuggestion($label)';
}
