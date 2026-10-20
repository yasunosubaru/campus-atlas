import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/network/api_client.dart';
import '../../../core/network/body_shape.dart';
import '../../../core/result.dart';
import '../../whu_auth/whu_endpoints.dart' show JwglOrigin;
import '../../whu_auth/whu_session.dart';
import 'jwgl_timetable_parser.dart';

/// Reads the student's timetable from 正方教务 (N2151).
///
/// Uses the session the person obtained interactively, exactly like the grade
/// query: no credentials, no CAPTCHA, no storage. The endpoint is posted as a
/// form because that is what the page's own AJAX does.
class JwglTimetableRepository {
  JwglTimetableRepository({required this.client, required this.session});

  final ApiClient client;
  final WhuSession? session;

  /// Same freshness budget as the grade chain, stated here so the two do not
  /// drift apart.
  static const Duration sessionTtl = Duration(hours: 2);

  bool get hasSession => session != null;

  Future<Result<TimetableImport>> fetch({
    required String year,
    required String term,
  }) async {
    final s = session;
    if (s == null) {
      return Failure<TimetableImport>.reason(
        FailureKind.unauthorized,
        message: 'Sign in to the university single sign-on first',
        endpoint: JwglOrigin.timetableData,
      );
    }
    if (!s.hasTgc) {
      return Failure<TimetableImport>.reason(
        FailureKind.unauthorized,
        message: 'the CAS ticket is missing',
        endpoint: JwglOrigin.timetableData,
      );
    }
    if (!s.isFresh(ttl: sessionTtl)) {
      return Failure<TimetableImport>.reason(
        FailureKind.unauthorized,
        message: 'the session is older than ${sessionTtl.inMinutes} minutes',
        endpoint: JwglOrigin.timetableData,
      );
    }
    if (year.trim().isEmpty || term.trim().isEmpty) {
      return Failure<TimetableImport>.reason(
        FailureKind.validation,
        message: 'Both academic year and term are required',
        endpoint: JwglOrigin.timetableData,
      );
    }

    final uri = Uri.parse(JwglOrigin.timetableData).replace(queryParameters: {
      'gnmkdm': JwglOrigin.timetableGnmkdm,
      'layout': 'default',
    });
    var cookie = s.cookieHeaderFor(uri);
    if (cookie.isEmpty && !s.hasTgc) {
      return Failure<TimetableImport>.reason(
        FailureKind.unauthorized,
        message: 'The session holds no cookie for ${uri.host} and no CAS '
            'grant to obtain one with. Sign in again.',
        endpoint: uri.path,
      );
    }

    // A POST with no service cookie does not bounce to CAS here: the data
    // endpoint answers 200 with an empty `kbList`, which reads exactly like a
    // term that has no courses. Walk the timetable page first, let the CAS hop
    // establish the 教务 session, and carry the cookie it set into the POST.
    if (cookie.isEmpty) {
      final page =
          Uri.parse(JwglOrigin.timetablePage).replace(queryParameters: {
        'gnmkdm': JwglOrigin.timetableGnmkdm,
        'layout': 'default',
      });
      final Result<RedirectedGet> warm;
      try {
        warm = await client.getFollowing(
          page,
          cookieFor: s.cookieHeaderFor,
          headers: {'referer': '${JwglOrigin.root}/xtgl/index.html'},
        ).timeout(const Duration(seconds: 90));
      } on TimeoutException {
        return Failure<TimetableImport>.reason(
          FailureKind.timeout,
          message: 'The timetable session handshake did not finish within 90s',
          endpoint: page.path,
        );
      }
      final warmFailure = warm.errorOrNull;
      if (warmFailure != null) return Failure<TimetableImport>(warmFailure);

      final got = warm.requireValue;
      if (got.finalUri.host.toLowerCase() != uri.host.toLowerCase()) {
        return Failure<TimetableImport>.reason(
          FailureKind.unauthorized,
          message: 'The CAS handshake ended at ${got.finalUri.host}, not '
              '${uri.host} — this sign-in still needs a second factor',
          endpoint: page.path,
        );
      }
      if (looksLikeHtml(got.response.body) &&
          looksLikeSignInPage(got.response.body)) {
        return Failure<TimetableImport>.reason(
          FailureKind.unauthorized,
          message: 'The academic system returned its sign-in page — the '
              'session is no longer valid',
          endpoint: page.path,
        );
      }
      cookie = got.cookieHeader;
      if (cookie.isEmpty) {
        return Failure<TimetableImport>.reason(
          FailureKind.unauthorized,
          message: 'The CAS grant did not establish a session on ${uri.host}',
          endpoint: page.path,
        );
      }
    }

    final request = http.Request('POST', uri)
      ..headers.addAll({
        'accept': 'application/json, text/javascript, */*; q=0.01',
        'x-requested-with': 'XMLHttpRequest',
        'referer': '${JwglOrigin.timetablePage}'
            '?gnmkdm=${JwglOrigin.timetableGnmkdm}&layout=default',
        'cookie': cookie,
      })
      ..bodyFields = {'xnm': year.trim(), 'xqm': term.trim()};

    final sent = await client.sendAnyStatus(request);
    final transportFailure = sent.errorOrNull;
    if (transportFailure != null) {
      return Failure<TimetableImport>(transportFailure);
    }

    final http.Response response;
    try {
      response = await client.readBody(sent.requireValue);
    } on TimeoutException {
      return Failure<TimetableImport>.reason(
        FailureKind.timeout,
        message: 'Headers came back but the body stalled for more than '
            '${client.bodyTimeout.inSeconds}s',
        endpoint: uri.path,
      );
    }

    if (response.statusCode >= 400) {
      final status = response.statusCode;
      return Failure<TimetableImport>.reason(
        status == 401 || status == 403
            ? FailureKind.unauthorized
            : (status >= 500 ? FailureKind.server : FailureKind.validation),
        message: 'HTTP $status',
        statusCode: status,
        endpoint: uri.path,
      );
    }

    // `http.Response.body` falls back to latin1 without a charset header, which
    // would turn every Chinese course name into mojibake. Decode UTF-8 here.
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);

    if (looksLikeHtml(body) && looksLikeSignInPage(body)) {
      return Failure<TimetableImport>.reason(
        FailureKind.unauthorized,
        message: 'The academic system returned its sign-in page — the session '
            'is no longer valid',
        endpoint: uri.path,
      );
    }
    if (body.trim().isEmpty) {
      return Failure<TimetableImport>.reason(
        FailureKind.invalidData,
        message: 'The timetable endpoint answered with an empty body',
        endpoint: uri.path,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      return Failure<TimetableImport>.reason(
        FailureKind.invalidData,
        message: 'The timetable answer was not JSON: ${e.message}',
        endpoint: uri.path,
      );
    }
    return parseJwglTimetable(decoded);
  }
}
