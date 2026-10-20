import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/config/app_config.dart';
import '../../core/network/api_client.dart';
import '../../core/network/body_shape.dart';
import '../../core/result.dart';
import 'altcha.dart';
import 'grades_query_models.dart';

/// Where an answer came from, for the UI to label honestly.
enum GradesSource { server, unavailable }

/// Client for the teacher-grade and evaluation query.
///
/// All four routes are behind the app's own account login — `POST
/// /api/v1/user/login`, protected by an Altcha proof of work. The gate for that
/// login is the reader's own password, which this class never stores and never
/// sees beyond the moment it is submitted: the token it returns is held **in
/// memory for the lifetime of this object** and is not written anywhere.
///
/// What is *not* implemented, and why: nothing here touches the university's own
/// systems (教务 / CAS / 评教). This is the app operator's own API, used with
/// the reader's own account — a different thing from authenticating against a
/// third party's system on their behalf.
class GradesQueryRepository {
  GradesQueryRepository({required this.client});

  final ApiClient client;

  /// Bearer token for the app's own API. Null when signed out.
  String? token;

  /// The raw body of the most recent **data** response, for diagnostics.
  ///
  /// ⚠️ Deliberately **not** populated by [login]. That response carries the
  /// access token, and a buffer whose entire purpose is to be shown to a person
  /// and pasted into a message is exactly the wrong place for a credential.
  /// Only the grade-query endpoints write here.
  String? lastRawResponse;

  /// Which request produced [lastRawResponse].
  String? lastRawEndpoint;

  /// Cap on the diagnostic buffer. A grade payload is small; anything larger is
  /// almost certainly an error page and truncating it loses nothing.
  static const int _rawLimit = 40000;

  void clearDiagnostics() {
    lastRawResponse = null;
    lastRawEndpoint = null;
  }

  bool get hasDiagnostics => (lastRawResponse ?? '').isNotEmpty;

  /// Every route this class calls, so a reader can see the surface at a glance.
  static const List<String> routes = [
    'GET  /api/v1/verification/altcha',
    'POST /api/v1/user/login',
    'GET  /api/v1/course/grades/by-name',
    'GET  /api/v1/course/grades/teachers/{course_uid}',
    'GET  /api/v1/course/grades/view/{offering_id}',
    'GET  /api/v1/reviews',
    'GET  /api/v1/suggest/courses',
  ];

  bool get isSignedIn => (token ?? '').isNotEmpty;

  Uri get _base => AppConfig.courseApi;

  void signOut() => token = null;

  Map<String, String> get _authHeaders => {
        'accept': 'application/json',
        if (isSignedIn) 'authorization': 'Bearer $token',
      };

  // ------------------------------------------------------------------ login

  /// Signs in with the reader's own account.
  ///
  /// Sequence, in order:
  ///   1. `GET /api/v1/verification/altcha` — the proof-of-work challenge.
  ///   2. Solve it locally. Altcha is a proof of work by design; computing it is
  ///      what the official widget does, not a bypass of anything.
  ///   3. `POST /api/v1/user/login` with the solved payload in the `X-Altcha`
  ///      header.
  ///
  /// ## Every part of this shape was determined empirically, not assumed
  ///
  /// Probed against the live service with a synthetic identifier — no real
  /// credential was involved, and the only thing being learned was which names
  /// the schema accepts:
  ///
  /// * **Header is `X-Altcha`**, not Altcha's own `Authorization: Altcha …`.
  ///   Using the vendor-standard header gets
  ///   `400 {"detail":"X-Altcha header required","business_code":1018}`.
  /// * **Body is `{"identifier": …, "password": …}`** — exactly two fields.
  ///   `email` / `account` / `username` all draw
  ///   `expected required property identifier to be present`, and any extra
  ///   property draws `unexpected property`, so the model forbids extras.
  /// * **The identifier may be a bare student number or a full address** —
  ///   both shapes reach `401 Invalid username or password`
  ///   (`business_code: 1004`), i.e. past validation, failing only on the
  ///   credentials.
  /// * **Challenges are single use** — reusing one draws
  ///   `409 {"detail":"Challenge already used"}`. [login] therefore fetches a
  ///   fresh challenge per attempt rather than caching one.
  Future<Result<String>> login({
    required String identifier,
    required String password,
  }) async {
    final trimmed = identifier.trim();
    if (trimmed.isEmpty || password.isEmpty) {
      return Failure<String>.reason(
        FailureKind.validation,
        message: 'Both identifier and password are required',
      );
    }

    // 1. challenge
    final challengeUri = Uri.parse('$_base/api/v1/verification/altcha');
    final challengeRaw = await client.getJson(challengeUri);
    if (challengeRaw.isFailure) {
      return Failure<String>(challengeRaw.errorOrNull!);
    }
    final challenge = AltchaChallenge.tryParse(challengeRaw.requireValue);
    if (challenge == null) {
      return Failure<String>.reason(
        FailureKind.protocol,
        message: 'The verification challenge was not in the expected shape',
        endpoint: '/api/v1/verification/altcha',
      );
    }

    // 2. solve
    final solved = challenge.solveAndEncode();
    if (solved == null) {
      return Failure<String>.reason(
        FailureKind.protocol,
        message: 'The proof-of-work challenge could not be solved within the '
            "server's own budget",
        endpoint: '/api/v1/verification/altcha',
      );
    }

    // 3. submit
    final loginUri = Uri.parse('$_base/api/v1/user/login');
    // `sendAnyStatus`, not `rawSend`: this service puts its actionable detail
    // in error bodies, and a status-only classification discards them.
    final sent = await client.sendAnyStatus(
      http.Request('POST', loginUri)
        ..headers.addAll({
          ..._authHeaders,
          'content-type': 'application/json',
          // `X-Altcha`, verified against the live service. Altcha's own
          // `Authorization: Altcha …` transport is rejected here with
          // business_code 1018.
          'X-Altcha': solved.encoded,
        })
        ..body = jsonEncode({
          // Exactly these two fields: the model rejects extras, and
          // `identifier` is the only name it accepts.
          'identifier': trimmed,
          'password': password,
        }),
    );
    final failure = sent.errorOrNull;
    if (failure != null) return Failure<String>(failure);

    final http.Response response;
    try {
      response = await http.Response.fromStream(sent.requireValue);
    } catch (e) {
      return Failure<String>.reason(
        FailureKind.protocol,
        message: 'Could not read the sign-in response',
        cause: e,
        endpoint: '/api/v1/user/login',
      );
    }

    final decoded = _decode(response.body);

    // An error status, reported with whatever the server actually said.
    if (response.statusCode >= 400) {
      final status = response.statusCode;
      return Failure<String>.reason(
        status == 401 || status == 403
            ? FailureKind.unauthorized
            : (status >= 500 ? FailureKind.server : FailureKind.validation),
        // A 422's `detail` reads only "validation failed"; the field-level
        // `errors[]` is what names the property, so prefer that.
        message: _loginMessage(decoded) ?? 'HTTP $status',
        statusCode: status,
        endpoint: '/api/v1/user/login',
      );
    }

    if (decoded == null) {
      return Failure<String>.reason(
        looksLikeHtml(response.body)
            ? FailureKind.protocol
            : FailureKind.invalidData,
        message: 'Sign-in response was not JSON',
        endpoint: '/api/v1/user/login',
      );
    }

    final extracted = _extractToken(decoded);
    if (extracted == null || extracted.isEmpty) {
      return Failure<String>.reason(
        FailureKind.unauthorized,
        message: _loginMessage(decoded) ??
            'Sign-in succeeded but no token came back',
        endpoint: '/api/v1/user/login',
      );
    }

    token = extracted;
    return Success(extracted);
  }

  /// Reads a token out of a login response without assuming one shape.
  ///
  /// Three conventions are common: `access_token`, a nested
  /// `{token: {access_token}}`, and `data.access_token`. A keyed lookup would
  /// fail on two of the three.
  String? _extractToken(Object? decoded) {
    if (decoded is! Map) return null;
    for (final key in const ['access_token', 'accessToken', 'token']) {
      final v = decoded[key];
      if (v is String && v.isNotEmpty) return v;
    }
    for (final key in const ['data', 'result']) {
      final nested = decoded[key];
      if (nested is Map) {
        for (final k in const ['access_token', 'accessToken', 'token']) {
          final v = nested[k];
          if (v is String && v.isNotEmpty) return v;
        }
      }
    }
    return null;
  }

  /// Human-readable reason from a failed login, if the server gave one.
  ///
  /// A 422 from this service carries a field-level `errors[]` array, and that
  /// is the most actionable part of the response — it names the exact property
  /// the schema wanted. Checked before the flat `detail`, which on a 422 reads
  /// only "validation failed" and tells the reader nothing.
  String? _loginMessage(Object? decoded) {
    if (decoded is! Map) return null;

    final errors = decoded['errors'];
    if (errors is List && errors.isNotEmpty) {
      final parts = <String>[];
      for (final e in errors) {
        if (e is Map) {
          final message = e['message'];
          final location = e['location'];
          if (message is String && message.isNotEmpty) {
            parts.add(location is String && location.isNotEmpty
                ? '$message ($location)'
                : message);
          }
        }
      }
      if (parts.isNotEmpty) return parts.join('; ');
    }

    for (final key in const ['detail', 'message', 'msg', 'error']) {
      final v = decoded[key];
      if (v is String && v.isNotEmpty) return v;
      if (v is Map) {
        final inner = v['message'];
        if (inner is String && inner.isNotEmpty) return inner;
      }
    }
    return null;
  }

  // ------------------------------------------------------------- the queries

  /// Every offering's grade distribution for a course name.
  ///
  /// `GET /api/v1/course/grades/by-name` — "Read every offering's grade
  /// distribution for a course name". Requires sign-in.
  ///
  /// The query parameter is **`course_name`**, not `query`. Pinned from a 422
  /// this service returned to a signed-in caller:
  ///
  /// ```json
  /// {"status":422,"errors":[{"message":"required query parameter is missing",
  ///                          "location":"query.course_name","value":""}]}
  /// ```
  ///
  /// Worth recording *why* this could not be found earlier: the 422 only
  /// appears **behind** authentication. An unsigned request to this route gets
  /// `401 authentication required` and never reaches parameter validation, so
  /// there is no way to learn the name without a signed-in probe.
  ///
  /// The value matches the full course name; an abbreviation such as 高数 will
  /// not find 高等数学, so the screen drives this from picked suggestions
  /// rather than from raw typing.
  Future<Result<List<CourseGrades>>> byName(String query) async {
    final guard = _requireSignIn<List<CourseGrades>>();
    if (guard != null) return guard;

    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return Failure<List<CourseGrades>>.reason(
        FailureKind.validation,
        message: 'Query must not be empty',
      );
    }

    final uri = Uri.parse('$_base/api/v1/course/grades/by-name')
        .replace(queryParameters: {'course_name': trimmed});

    final raw = await _getJson(uri);
    if (raw.isFailure) return Failure<List<CourseGrades>>(raw.errorOrNull!);

    final items = _rowsFrom(raw.requireValue);
    final out = <CourseGrades>[];
    for (final row in items) {
      final parsed = CourseGrades.tryParse(row);
      if (parsed != null) out.add(parsed);
    }
    return Success(out);
  }

  /// The teachers who teach a course.
  ///
  /// `GET /api/v1/course/grades/teachers/{course_uid}` — "Choose a teacher to
  /// view the corresponding grade data".
  Future<Result<List<TeacherGrade>>> teachers(String courseUid) async {
    final guard = _requireSignIn<List<TeacherGrade>>();
    if (guard != null) return guard;

    if (courseUid.trim().isEmpty) {
      return Failure<List<TeacherGrade>>.reason(
        FailureKind.validation,
        message: 'A course is required',
      );
    }

    final uri = Uri.parse(
        '$_base/api/v1/course/grades/teachers/${Uri.encodeComponent(courseUid.trim())}');
    final raw = await _getJson(uri);
    if (raw.isFailure) return Failure<List<TeacherGrade>>(raw.errorOrNull!);

    final out = <TeacherGrade>[];
    for (final row in _rowsFrom(raw.requireValue)) {
      final parsed = TeacherGrade.tryParse(row);
      if (parsed != null) out.add(parsed);
    }
    return Success(out);
  }

  /// One teacher's grade distribution in detail.
  ///
  /// `GET /api/v1/course/grades/view/{offering_id}` — "Read a course grade
  /// distribution".
  Future<Result<TeacherGrade>> view(String offeringId) async {
    final guard = _requireSignIn<TeacherGrade>();
    if (guard != null) return guard;

    if (offeringId.trim().isEmpty) {
      return Failure<TeacherGrade>.reason(
        FailureKind.validation,
        message: 'An offering is required',
      );
    }

    final uri = Uri.parse(
        '$_base/api/v1/course/grades/view/${Uri.encodeComponent(offeringId.trim())}');
    final raw = await _getJson(uri);
    if (raw.isFailure) return Failure<TeacherGrade>(raw.errorOrNull!);

    final parsed = TeacherGrade.tryParse(raw.requireValue);
    if (parsed == null) {
      return Failure<TeacherGrade>.reason(
        FailureKind.invalidData,
        message: 'Grade response could not be parsed',
        endpoint: '/api/v1/course/grades/view',
      );
    }
    return Success(parsed);
  }

  /// Review texts, optionally filtered by course or teacher.
  ///
  /// `GET /api/v1/reviews` — verified public in shape
  /// (`{"reviews":[],"total":0,"page":1,"limit":20}`), and it is the one route
  /// here that answered without credentials. Its dataset is empty today.
  Future<Result<List<CourseReview>>> reviews({
    String? courseUid,
    String? teacherId,
    int page = 1,
    int limit = 20,
  }) async {
    final params = <String, String>{
      'page': '$page',
      'limit': '$limit',
    };
    if (courseUid != null && courseUid.isNotEmpty) {
      params['course_uid'] = courseUid;
    }
    if (teacherId != null && teacherId.isNotEmpty) {
      params['teacher_id'] = teacherId;
    }

    final uri =
        Uri.parse('$_base/api/v1/reviews').replace(queryParameters: params);
    // Deliberately *not* gated on sign-in: this endpoint is public.
    final raw = await _getJson(uri);
    if (raw.isFailure) return Failure<List<CourseReview>>(raw.errorOrNull!);

    final out = <CourseReview>[];
    for (final row in _rowsFrom(raw.requireValue)) {
      final parsed = CourseReview.tryParse(row);
      if (parsed != null) out.add(parsed);
    }
    return Success(out);
  }

  /// Autocomplete for the course box, from a public endpoint.
  Future<Result<List<String>>> suggest(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return Failure<List<String>>.reason(
        FailureKind.validation,
        message: 'Query must not be empty',
      );
    }
    final uri = Uri.parse('$_base/api/v1/suggest/courses')
        .replace(queryParameters: {'q': trimmed});
    final raw = await _getJson(uri);
    if (raw.isFailure) return Failure<List<String>>(raw.errorOrNull!);

    final suggestions = raw.requireValue['suggestions'];
    if (suggestions is! List) {
      return Failure<List<String>>.reason(
        FailureKind.invalidData,
        message: 'suggest/courses missing suggestions[]',
      );
    }
    return Success(suggestions.whereType<String>().toList());
  }

  // ----------------------------------------------------------------- helpers

  Failure<T>? _requireSignIn<T>() {
    if (isSignedIn) return null;
    return Failure<T>.reason(
      FailureKind.unauthorized,
      message: 'Sign in to query grade data',
    );
  }

  /// Pulls the row array out of an arbitrary envelope.
  ///
  /// The first case is the one the live service actually uses, and it is not a
  /// list at all — a signed-in probe returned:
  ///
  /// ```json
  /// {"course_name":"高等数学","offerings":[]}
  /// ```
  ///
  /// **The root object is the course**, with its offerings hanging off it.
  /// Looking only for a course-shaped *array* misses the root entirely, and the
  /// query then reports "nothing found" for a course the server did find.
  List<Object?> _rowsFrom(Map<String, Object?> payload) {
    // Root-as-course, checked first: a real response is shaped this way.
    final rootName = payload['course_name'] ?? payload['name'];
    if (rootName is String && rootName.isNotEmpty) {
      return <Object?>[payload];
    }

    for (final key in const [
      'courses',
      'teachers',
      'offerings',
      'items',
      'results',
      'data',
    ]) {
      final v = payload[key];
      if (v is List) return v;
    }
    return const [];
  }

  /// A GET that keeps the raw body around for diagnostics.
  ///
  /// Why this instead of [ApiClient.getJson]: the four grade endpoints have
  /// **never had a response body recorded**, because they are auth-walled and
  /// reaching one needs the reader's own account. The parser copes by accepting
  /// several key aliases, but aliases are guesswork until one real payload is
  /// seen. Buffering the body lets the reader hand it over after a single
  /// sign-in, which is what turns this feature from inferred to known.
  ///
  /// The buffer is display-only: it is never written to disk and never logged.
  Future<Result<Map<String, Object?>>> _getJson(Uri uri) async {
    final sent = await client.sendAnyStatus(
      http.Request('GET', uri)..headers.addAll(_authHeaders),
    );
    final failure = sent.errorOrNull;
    if (failure != null) return Failure<Map<String, Object?>>(failure);

    final http.Response response;
    try {
      response = await http.Response.fromStream(sent.requireValue);
    } catch (e) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.protocol,
        message: 'Could not read the response body',
        cause: e,
        endpoint: uri.path,
      );
    }

    // Captured before any status handling: when the shape is wrong, the reader
    // needs to see what actually arrived, and an error body is what arrived.
    _capture(uri, response.body);

    if (response.statusCode >= 400) {
      // Every error status is handled here, not just 401 and 5xx. A 422 body is
      // valid JSON, so without this it falls through to the row extractor and
      // returns a *successful empty list* — and the UI then says "no course
      // found" when the truth is "your request was malformed".
      final status = response.statusCode;
      return Failure<Map<String, Object?>>.reason(
        status == 401 || status == 403
            ? FailureKind.unauthorized
            : (status >= 500 ? FailureKind.server : FailureKind.validation),
        // The field-level `errors[]` names the property; `detail` on a 422
        // reads only "validation failed".
        message: _loginMessage(_decode(response.body)) ?? 'HTTP $status',
        statusCode: status,
        endpoint: uri.path,
      );
    }

    if (!looksLikeJson(response.body)) {
      return Failure<Map<String, Object?>>.reason(
        looksLikeHtml(response.body)
            ? FailureKind.protocol
            : FailureKind.invalidData,
        message: looksLikeHtml(response.body)
            ? 'Expected JSON, received an HTML page — most likely a sign-in page'
            : 'Expected JSON, received something else',
        statusCode: response.statusCode,
        endpoint: uri.path,
      );
    }

    final decoded = _decode(response.body);
    if (decoded is Map<String, Object?>) return Success(decoded);
    if (decoded is List) return Success(<String, Object?>{'data': decoded});
    return Failure<Map<String, Object?>>.reason(
      FailureKind.invalidData,
      message: 'Response JSON root was ${decoded.runtimeType}, expected an '
          'object or array',
      endpoint: uri.path,
    );
  }

  void _capture(Uri uri, String body) {
    lastRawEndpoint = 'GET ${uri.path}';
    lastRawResponse =
        body.length > _rawLimit ? body.substring(0, _rawLimit) : body;
  }
}

Object? _decode(String body) {
  try {
    return jsonDecode(body);
  } catch (_) {
    return null;
  }
}
