import 'dart:async';
import 'dart:convert';

import '../../../core/network/api_client.dart';
import '../../../core/network/body_shape.dart';
import '../../../core/result.dart';
import '../../whu_auth/whu_endpoints.dart' show JwglOrigin;
import '../../whu_auth/whu_session.dart';
import 'jwgl_menu.dart';

/// Reads 正方教务 using a CAS session the person obtained interactively.
///
/// No credential handling, no CAPTCHA solving, and no storage: the session
/// comes from the WebView sign-in in `features/whu_auth` and is used for the
/// life of the process only. Everything here is a read of the reader's own
/// academic record.
class JwglRepository {
  JwglRepository({
    required this.client,
    this.session,
  });

  final ApiClient client;

  /// The CAS session obtained interactively, or null when not signed in.
  ///
  /// In memory only, for the life of the process: the sign-in screen hands this
  /// back and nothing persists it.
  final WhuSession? session;

  /// True when requests can be issued at all.
  bool get hasSession => session != null;

  /// The body of the last response, for diagnosis.
  ///
  /// ⚠️ Not populated by anything that could carry a credential. The menu and
  /// the grade query return academic records, not secrets, and the menu's
  /// shape is not established — seeing it is the whole point of having this.
  String? lastRawResponse;
  String? lastRawEndpoint;

  static const int _rawLimit = 200000;

  void clearDiagnostics() {
    lastRawResponse = null;
    lastRawEndpoint = null;
  }

  /// Records what was sent and what came back.
  ///
  /// [endpointLine] is the request line plus its redirect chain, one line per
  /// hop — host and path only, because a CAS ticket lives in a query string and
  /// this text is shown to the reader.
  void _capture(String endpointLine, String body) {
    lastRawEndpoint = endpointLine;
    lastRawResponse =
        body.length > _rawLimit ? body.substring(0, _rawLimit) : body;
  }

  /// Fetches the student function menu.
  ///
  /// This is the **discovery point**. Every route under jwgl returns the same
  /// SPA shell, so an endpoint cannot be probed into existence and a 404 proves
  /// nothing; the set of student functions is delivered here instead, and what
  /// appears depends on the account. The teaching-evaluation entry is not in
  /// this project's binary at all, which is exactly why it has to be read from
  /// the menu rather than hardcoded.
  Future<Result<JwglMenu>> fetchMenu() async {
    final guard = _requireSession<JwglMenu>();
    if (guard != null) return guard;

    final uri = Uri.parse(JwglOrigin.menu).replace(queryParameters: {
      'jsdm': JwglOrigin.studentJsdm,
      'echarts': '1',
    });

    return (await _request(uri)).map<JwglMenu>(JwglMenu.parse);
  }

  /// The student's own grades for a term.
  ///
  /// `GET {gradeQuery}?doType=query&gnmkdm=N305005&xnm=…&xqm=…` — the
  /// endpoint and the code both come from the live menu rather than from a
  /// document. A student session served this page renders the real grid, with the
  /// GPA and the `任课教师` column; an earlier `[D]`-sourced guess named a
  /// different path and a `-xs` discriminator, and neither was right.
  ///
  /// The query itself is protected by the system's own CAPTCHA — a slider, served
  /// from `dx_captcha_*` markup — so a session that has never been judged will
  /// answer this with the challenge page rather than with rows. That is a wall
  /// this client reports and does not climb; see the class docs.
  Future<Result<String>> fetchGrades({
    required String year,
    required String xqm,
  }) async {
    final guard = _requireSession<String>();
    if (guard != null) return guard;

    if (year.trim().isEmpty || xqm.trim().isEmpty) {
      return Failure<String>.reason(
        FailureKind.validation,
        message: 'Both academic year and term are required',
        endpoint: 'cjcx_cxDgXscj',
      );
    }

    final uri = Uri.parse(JwglOrigin.gradeQuery).replace(queryParameters: {
      'doType': 'query',
      'gnmkdm': JwglOrigin.gradeGnmkdm,
      'xnm': year.trim(),
      'xqm': xqm.trim(),
    });

    // The body is returned rather than parsed: the grade grid's exact shape is
    // established only behind a session, and a raw capture is worth more than
    // a wrong guess at a model.
    return _request(uri);
  }

  /// Opens a page from the menu, returning its body.
  ///
  /// Takes the URL **from the menu** rather than constructing one, because for
  /// a page that has never been seen the menu is the only authority on what it
  /// is called and how it is parameterised.
  Future<Result<String>> openMenuPage(JwglMenuEntry entry) async {
    final guard = _requireSession<String>();
    if (guard != null) return guard;

    if (entry.url.trim().isEmpty) {
      return Failure<String>.reason(
        FailureKind.validation,
        message: 'This menu entry carries no page URL',
      );
    }

    final uri = Uri.parse(entry.url.startsWith('http')
        ? entry.url
        : '${JwglOrigin.root}${entry.url}');

    // `gnmkdm` is what the page's own grid needs; the menu always supplies it
    // for a real entry.
    final params = <String, String>{};
    if (entry.gnmkdm.isNotEmpty) {
      params['gnmkdm'] = entry.gnmkdm;
      params['layout'] = 'default';
    }

    final target = params.isEmpty ? uri : uri.replace(queryParameters: params);
    return _request(target);
  }

  /// Every route this class calls, so the surface is readable at a glance.
  static const List<String> routes = [
    'GET  /xtgl/index_initMenu.html?jsdm=xs&echarts=1',
    'GET  /cjcx/cjcx_cxDgXscj.html?doType=query&gnmkdm=N305005',
    'GET  {path from the menu}?gnmkdm=…&layout=default',
  ];

  // ------------------------------------------------------------------ helpers

  Failure<T>? _requireSession<T>() {
    if (hasSession) return null;
    return Failure<T>.reason(
      FailureKind.unauthorized,
      message: 'Sign in to the university single sign-on first',
    );
  }

  /// A GET that keeps the raw body and classifies the response itself.
  ///
  /// `ApiClient.getJson` is unusable here: jwgl is HTML-first, and a
  /// 200-with-HTML answer — the sign-in wall — would be reported as a protocol
  /// error rather than as an expired session.
  Future<Result<String>> _request(Uri uri) async {
    final s = session;
    if (s == null) {
      return Failure<String>.reason(
        FailureKind.unauthorized,
        message: 'No academic-system session',
      );
    }
    if (!s.hasTgc) {
      return Failure<String>.reason(
        FailureKind.unauthorized,
        message: 'the CAS ticket is missing',
      );
    }
    if (!s.isFresh(ttl: WhuSessionTtl.value)) {
      return Failure<String>.reason(
        FailureKind.unauthorized,
        message: 'the session is older than ${WhuSessionTtl.minutes} minutes',
      );
    }

    // Cookies are matched against the URL, so only those belonging to this host
    // are sent. Building the header from names alone sent the CAS grant to 教务
    // and let the two hosts' `JSESSIONID`s overwrite each other.
    //
    // A missing cookie for this host is *not* by itself a refusal: entering a
    // property that has never been visited is exactly what the CAS grant is
    // for — the hop to cas.whu.edu.cn will present it, and the property's own
    // session comes back as Set-Cookie on the way through. The refusal is kept
    // only for the case where neither a host cookie nor the grant exists.
    final cookie = s.cookieHeaderFor(uri);
    if (cookie.isEmpty && !s.hasTgc) {
      // Named plainly, because this is the difference between "the menu is
      // empty" and "the sign-in never produced a session here" — and those call
      // for completely different next steps.
      return Failure<String>.reason(
        FailureKind.unauthorized,
        message: 'The session holds no cookie for ${uri.host} and no CAS '
            'grant to obtain one with. Sign in again.',
        endpoint: uri.path,
      );
    }

    // A marker set *before* the request runs, so the diagnostics sheet can
    // distinguish "this request is in flight and nothing has answered yet" from
    // "this request never started" — two states that used to look identical.
    lastRawEndpoint = 'GET ${uri.path}\n  (in flight — no hop answered yet)';

    // Redirects are followed by hand, one hop at a time, so that each hop can
    // present the cookie that belongs to *its* host — the evaluation entry
    // bounces 教务 → ugsqs → CAS, and only the per-hop cookie carries the CAS
    // grant to the hop that needs it. `package:http`'s automatic following
    // resends the first host's cookies to every host, which is how a fresh
    // sign-in still ended up showing the CAS sign-in page.
    final Result<RedirectedGet> got;
    try {
      got = await client.getFollowing(
        uri,
        cookieFor: s.cookieHeaderFor,
        headers: {'referer': '${JwglOrigin.root}/xtgl/index.html'},
      ).timeout(const Duration(seconds: 90));
    } on TimeoutException {
      // Belt over the client's own per-hop deadlines. If this fires, one of the
      // inner timeouts did not — which is itself the finding.
      return Failure<String>.reason(
        FailureKind.timeout,
        message: 'Nothing completed within 90s — an inner per-hop deadline '
            'did not fire',
        endpoint: uri.path,
      );
    }
    final failure = got.errorOrNull;
    if (failure != null) return Failure<String>(failure);

    final chain = got.requireValue;
    final response = chain.response;
    _capture(chain.chainText, response.body);

    if (response.statusCode >= 400) {
      final status = response.statusCode;
      return Failure<String>.reason(
        status == 401 || status == 403
            ? FailureKind.unauthorized
            : (status >= 500 ? FailureKind.server : FailureKind.validation),
        message: _serverMessage(response.body) ?? 'HTTP $status',
        statusCode: status,
        endpoint: uri.path,
      );
    }

    if (looksLikeHtml(response.body) && looksLikeSignInPage(response.body)) {
      return Failure<String>.reason(
        FailureKind.unauthorized,
        message: 'The academic system returned its sign-in page — the '
            'session is no longer valid',
        endpoint: uri.path,
      );
    }

    return Success(response.body);
  }
}

/// Freshness budget for a 教务 session, stated once so the error text and the
/// check cannot drift apart.
class WhuSessionTtl {
  const WhuSessionTtl._();

  /// Two hours. Generous on purpose: the point of the interactive sign-in is
  /// to reuse one session, and a tight window pushes callers back to signing in
  /// repeatedly against an origin that rate-limits logins.
  static const Duration value = Duration(hours: 2);

  /// 120 — spelled out because `Duration.inMinutes` is not a constant
  /// expression and this needs to be usable in a const context.
  static const int minutes = 120;
}

/// A quotable reason from a JSON error body, or null.
String? _serverMessage(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    for (final k in const ['detail', 'message', 'msg', 'error']) {
      final v = decoded[k];
      if (v is String && v.isNotEmpty) return v;
    }
  } catch (_) {
    // Not JSON: a server error page carries nothing quotable.
  }
  return null;
}
