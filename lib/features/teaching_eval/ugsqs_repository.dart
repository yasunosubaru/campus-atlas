import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/network/api_client.dart';
import '../../core/result.dart';
import '../whu_auth/whu_endpoints.dart' show CasOrigin, TeachingEvalOrigin;
import '../whu_auth/whu_session.dart';

/// Resolves the teaching-evaluation entry the way the landing page itself does.
///
/// ## The evidence
///
/// On 2026-10-18 the evaluation host's `/caslogin` landing page (679 B) was
/// captured with its own inline script:
///
/// ```js
/// $.ajax({
///   type: 'POST',
///   data: {"userId": '<student id>'},
///   url: '/loginSSO',
///   success: function (data) {
///     if (data.success) { location.href = data.forwardURL; }
///     else { $("#errorMsg").html(data.msg); }
///   }
/// });
/// ```
///
/// So the contract is not a guess: POST form field `userId` to `/loginSSO`, read
/// JSON `{success, forwardURL, msg}`. This repository does exactly that and
/// nothing more. It does **not** fill or submit the evaluation form — that form
/// has never been captured, and inventing its fields would be worse than leaving
/// the last step to the person in the browser.
class UgsqsRepository {
  UgsqsRepository({required this.client, required this.session});

  final ApiClient client;
  final WhuSession? session;

  /// [V] The landing page whose script was captured.
  static const String landing = '${TeachingEvalOrigin.root}/caslogin';

  /// [V] The endpoint the landing page's script posts to.
  static const String loginSso = '${TeachingEvalOrigin.root}/loginSSO';

  /// POSTs the student id and answers the `forwardURL` the page would navigate
  /// to.
  ///
  /// The returned URL may carry a one-time ticket. It is handed back to the
  /// caller to open and is never logged or written to storage by this class.
  Future<Result<String>> resolveEntry({required String userId}) async {
    final id = userId.trim();
    if (id.isEmpty) {
      return Failure<String>.reason(
        FailureKind.validation,
        message: 'The student id is required',
        endpoint: '/loginSSO',
      );
    }
    final s = session;
    if (s == null) {
      return Failure<String>.reason(
        FailureKind.unauthorized,
        message: 'Sign in to the university single sign-on first',
        endpoint: '/loginSSO',
      );
    }

    final uri = Uri.parse(loginSso);
    var cookie = s.cookieHeaderFor(uri);

    // The /loginSSO answer is only useful after the evaluation host's own
    // service session exists. Arriving with just the central grant is not
    // enough: the service answers the POST with a relative / error-shaped
    // hand-off instead of the real forwardURL. Walk the same CAS hop the
    // browser's landing page walks, then keep the cookies that hop set.
    if (s.hasTgc) {
      final warm = await client.getFollowing(
        Uri.parse(TeachingEvalOrigin.casService),
        cookieFor: s.cookieHeaderFor,
        headers: {
          'referer': '${CasOrigin.login}'
              '${Uri.encodeComponent(TeachingEvalOrigin.casService)}',
        },
      );
      final failure = warm.errorOrNull;
      if (failure != null) return Failure<String>(failure);

      final chain = warm.requireValue;
      if (!chain.finalUri.host.toLowerCase().endsWith('ugsqs.whu.edu.cn')) {
        return Failure<String>.reason(
          FailureKind.unauthorized,
          message: 'The evaluation host still asks for a sign-in',
          endpoint: '/loginSSO',
        );
      }
      // getFollowing exports the final hop's Cookie header, including the
      // service session cookie it just established. This is what makes the
      // POST below an authenticated one.
      cookie = chain.cookieHeader;
    }

    final request = http.Request('POST', uri)
      ..headers.addAll({
        'accept': 'application/json, text/javascript, */*; q=0.01',
        'x-requested-with': 'XMLHttpRequest',
        'referer': landing,
        'origin': TeachingEvalOrigin.root,
        'user-agent': 'campus-atlas/0.1 (+open-source)',
        if (cookie.isNotEmpty) 'cookie': cookie,
      })
      ..bodyFields = {'userId': id};

    final sent = await client.sendAnyStatus(request);
    final transportFailure = sent.errorOrNull;
    if (transportFailure != null) return Failure<String>(transportFailure);

    final http.Response response;
    try {
      response = await client.readBody(sent.requireValue);
    } on TimeoutException {
      return Failure<String>.reason(
        FailureKind.timeout,
        message: 'Headers came back but the body stalled for more than '
            '${client.bodyTimeout.inSeconds}s',
        endpoint: '/loginSSO',
      );
    }

    if (response.statusCode >= 400) {
      final status = response.statusCode;
      return Failure<String>.reason(
        status == 401 || status == 403
            ? FailureKind.unauthorized
            : (status >= 500 ? FailureKind.server : FailureKind.validation),
        message: 'HTTP $status',
        statusCode: status,
        endpoint: '/loginSSO',
      );
    }

    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      // An HTML answer here is the sign-in page, not a JSON error.
      return Failure<String>.reason(
        FailureKind.unauthorized,
        message: 'The evaluation host answered with a page instead of JSON — '
            'the session is not valid there. Sign in again.',
        endpoint: '/loginSSO',
      );
    }
    if (decoded is! Map) {
      return Failure<String>.reason(
        FailureKind.invalidData,
        message: 'The /loginSSO answer was not a JSON object',
        endpoint: '/loginSSO',
      );
    }

    final success = decoded['success'] == true || decoded['success'] == 'true';
    if (!success) {
      final message = '${decoded['msg'] ?? ''}'.trim();
      return Failure<String>.reason(
        FailureKind.validation,
        message: message.isEmpty
            ? 'The evaluation host refused the sign-in hand-off.'
            : message,
        endpoint: '/loginSSO',
      );
    }

    final forward = decoded['forwardURL'];
    if (forward is! String || forward.trim().isEmpty) {
      return Failure<String>.reason(
        FailureKind.invalidData,
        message: 'The answer said success but carried no forwardURL',
        endpoint: '/loginSSO',
      );
    }

    final target = resolveForwardUrl(forward);
    if (target == null) {
      // Deliberately does not echo the value: a malformed forwardURL is still
      // something the server sent, and it may contain a ticket.
      return Failure<String>.reason(
        FailureKind.protocol,
        message: 'The forwardURL is not an http(s) URL',
        endpoint: '/loginSSO',
      );
    }
    return Success(target.toString());
  }

  /// Resolves the `forwardURL` the host returns.
  ///
  /// The live host can answer with an absolute URL or with a path relative to
  /// its own origin (`/eval/...`, `//ugsqs.whu.edu.cn/...`). The landing page
  /// simply assigns the value to `location.href`, so a relative value is valid
  /// there; rejecting it here made a working hand-off look like a protocol
  /// error. Anything with a non-http scheme is still refused.
  static Uri? resolveForwardUrl(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final parsed = Uri.tryParse(text);
    if (parsed == null) return null;
    if (parsed.hasScheme) {
      return parsed.isScheme('http') || parsed.isScheme('https')
          ? parsed
          : null;
    }
    final target = Uri.parse('${TeachingEvalOrigin.root}/').resolveUri(parsed);
    return target.isScheme('http') || target.isScheme('https') ? target : null;
  }
}
