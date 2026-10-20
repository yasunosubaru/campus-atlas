import 'dart:math' show Random;

import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' as http;

import '../../core/network/api_client.dart';
import '../../core/result.dart';
import '../whu_auth/whu_endpoints.dart';
import '../whu_auth/whu_session.dart';
import 'grade_models.dart';

/// One student grade query.
///
/// The parameter set here is deliberately narrower than the origin accepts.
///
/// [Documented] and therefore sent:
///   * `xnm` — academic year label.
///   * `xqm` — term.
///   * `sy_id`, `sq_id` — named by the origin's own `paramMap()` as part of the
///     student-only branch.
///   * `gnmkdm=N305005` — the function code the page is served under. Read off a
///     live student menu. An earlier version's `zd_fzdm=N305005-xs` is **not**
///     what the page uses, and the note it came with — that following the menu
///     hits the staff branch and produces an answer the server never processes —
///     was wrong in both halves.
///
/// [Deliberately absent]: jQuery Grid's pagination parameters. Their real
/// names depend on a `prmNames` configuration this project cannot read without
/// a session, and guessing them wrong gets a silently short page that looks
/// like a short term. [GradeSheet.truncated] exists instead: if the server
/// declares more rows than were parsed, we know we paginated by accident and
/// can add the observed names once.
@immutable
class GradeQuery {
  const GradeQuery({
    required this.year,
    required this.xqm,
    this.sessionId = '',
    this.squareId = '',
    this.validateToken,
  });

  /// Academic year exactly as the form sends it, e.g. `"2025-2026"`.
  final String year;

  /// Raw `xqm` term code. **Not** translated to a term enum — the mapping is
  /// unestablished, so the value is passed through untouched.
  final String xqm;

  /// `sy_id`. Meaning and default not established; blank is what the page sends
  /// when the corresponding field is unset.
  final String sessionId;

  /// `sq_id`. Same caveat as [sessionId].
  final String squareId;

  /// `validate`, present only once the page has a CAPTCHA token from a
  /// completed interactive challenge.
  ///
  /// **Never synthesised.** The token is bound to one human-completed
  /// verification — the page writes it into `#validate` *after* the fact and
  /// the next request carries it — so fabricating a value produces a request
  /// the server rejects. It is supplied by the caller only.
  final String? validateToken;

  bool get hasToken => (validateToken ?? '').trim().isNotEmpty;
}

/// Read-only client for the student grade view.
///
/// Boundary, stated plainly: this talks to **WHU's own system using a session
/// the user obtained interactively**. There is no credential handling, no
/// credential storage, no CAPTCHA automation, and no retry against a rejected
/// token. The repository refuses to send anything when the session is missing
/// or stale rather than failing later with a bare 401.
class GradeRepository {
  GradeRepository({required this.client, required this.session});

  final ApiClient client;
  final WhuSession session;

  /// Bound rather than read from globals so a test can exercise URL building
  /// without any network.
  Uri get endpoint => Uri.parse(JwglOrigin.gradeQuery);

  /// Default freshness budget for a 教务 session.
  static const Duration sessionTtl = Duration(hours: 2);

  bool get hasUsableSession =>
      session.hasTgc && session.isFresh(ttl: sessionTtl);

  /// Builds the query URL. Pure — no network, no session needed.
  ///
  /// [V] The **query string carries only the addressing**, not the term: the term
  /// travels in the POST body. That split is what a working implementation does,
  /// and it is observable in the request it sends.
  Uri buildUri(GradeQuery query) => endpoint.replace(queryParameters: {
        'doType': 'query',
        'gnmkdm': JwglOrigin.gradeGnmkdm,
      });

  /// Builds the form body the grade query is posted with.
  ///
  /// [V] Four fields, from a working implementation:
  ///
  /// ```
  /// validate=…&xnm=2025&xqm=3&queryModel.showCount=150
  /// ```
  ///
  /// `validate` is **a nonce, not a CAPTCHA answer**: the working implementation
  /// generates it as `'sl' + random + timestamp`. The slider a person meets in a
  /// browser comes from a client-side panel that a plain HTTP client never loads.
  Map<String, String> buildBody(GradeQuery query, {String? validate}) => {
        'validate': validate ?? _nonce(),
        'xnm': query.year,
        'xqm': query.xqm,
        JwglOrigin.gradePageSizeField: JwglOrigin.gradePageSize,
      };

  /// The `validate` nonce, shaped like the one a working client sends.
  ///
  /// Deliberately **not** a security token and deliberately not presented as one:
  /// it is a random marker the grid uses to tell one query from another. Naming it
  /// honestly matters, because a reader who mistakes it for a solved challenge
  /// would conclude this client defeats a CAPTCHA, which it does not.
  static String _nonce() {
    // `nextInt` is capped at 2^32, unlike the JS original's `Math.random()*1e10`,
    // so the random part is 32-bit. What matters is the shape — `sl` + base36
    // random + base36 timestamp — not the width.
    final rnd = Random().nextInt(0x100000000).toRadixString(36);
    final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    return 'sl$rnd$stamp';
  }

  /// Fetches and parses one page of grades.
  Future<Result<GradeSheet>> fetch(GradeQuery query) async {
    if (query.year.trim().isEmpty || query.xqm.trim().isEmpty) {
      return Failure<GradeSheet>.reason(
        FailureKind.validation,
        message: 'Both academic year and term are required',
        endpoint: 'cjcx_cxDgXscj',
      );
    }

    // Checked before the network so a stale session fails as "sign in again"
    // and not as an empty term.
    if (!hasUsableSession) {
      final why = !session.hasTgc
          ? 'the CAS ticket is missing'
          : 'the session is older than ${sessionTtl.inMinutes} minutes';
      return Failure<GradeSheet>.reason(
        FailureKind.unauthorized,
        message: 'Academic-system session is not usable: $why',
        endpoint: 'cjcx_cxDgXscj',
      );
    }

    final uri = buildUri(query);

    // [V] POST, not GET. A working client posts the term in a form body; sending
    // it as query parameters is a shape the endpoint was never observed to accept.
    final request = http.Request('POST', uri)
      ..headers.addAll({
        'accept': 'application/json, text/javascript, */*; q=0.01',
        'content-type': 'application/x-www-form-urlencoded; charset=utf-8',
        'user-agent': 'campus-atlas/0.1 (+open-source)',
        // Scoped to this URL: sending every cookie in the session would hand
        // the CAS grant to 教务 and let same-named cookies from the two hosts
        // overwrite each other.
        'cookie': session.cookieHeaderFor(uri),
        // Referer matches the page that owns the endpoint; some ZFWeb
        // deployments reject a query that does not look like it came from
        // their own grid.
        'referer': '${JwglOrigin.root}/cjcx/',
      })
      ..bodyFields = buildBody(query, validate: query.validateToken);

    // `rawSend` rather than `getJson`: this feature needs the *body*, and it
    // needs to classify HTML itself. ApiClient maps an HTML document to
    // FailureKind.protocol (captive portal), whereas here an HTML body means
    // the session expired — a different answer for the user.
    final sent = await client.rawSend(request);
    final failure = sent.errorOrNull;
    if (failure != null) {
      return Failure<GradeSheet>(failure);
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(sent.requireValue);
    } catch (e) {
      return Failure<GradeSheet>.reason(
        FailureKind.protocol,
        message: 'Could not read the response body',
        cause: e,
        endpoint: uri.toString(),
      );
    }

    // A redirect into the sign-in page arrives as 200 with HTML — see
    // parseGradeBody. The HTML-vs-JSON decision has to happen here rather than
    // in ApiClient, because a non-JSON body means "session expired" for this
    // endpoint, not "captive portal".
    return parseGradeBody(response.body, year: query.year, xqm: query.xqm);
  }
}
