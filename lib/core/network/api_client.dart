import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../result.dart';

/// Thrown when the server answered, but not with JSON we can use.
class ProtocolException implements Exception {
  ProtocolException(this.message);
  final String message;

  @override
  String toString() => 'ProtocolException($message)';
}

typedef RequestInterceptor = Future<void> Function(http.Request request);

/// One place that all network traffic goes through.
///
/// Why a wrapper rather than calling `package:http` directly: every campus
/// integration we add needs the same four behaviours — a deadline, a bounded
/// retry on transient failure, typed failure classification, and a single
/// injection point for authentication headers. Putting that in one class means
/// a feature repository never has to remember any of it, and tests can swap in
/// a fake client without touching feature code.
class ApiClient {
  ApiClient({
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 20),
    this.bodyTimeout = const Duration(seconds: 30),
    this.maxRetries = 2,
    List<RequestInterceptor>? interceptors,
  })  : _http = httpClient ?? http.Client(),
        _interceptors = List.unmodifiable(interceptors ?? const []);

  final http.Client _http;
  final Duration timeout;

  /// Deadline for reading a whole body once the headers have arrived.
  ///
  /// [timeout] bounds only the wait for the response *headers*. `package:http`
  /// buffers a body with no deadline at all, so a server that sends headers and
  /// then stalls the body hangs its caller forever — measured on the
  /// evaluation host (`学生评教`): its caslogin hop answered with headers and
  /// never completed the body, and the screen sat on a loader with no error
  /// until the app itself was restarted.
  final Duration bodyTimeout;

  final int maxRetries;
  final List<RequestInterceptor> _interceptors;

  /// Injectable clock so tests can exercise expiry without sleeping.
  DateTime Function() _now = DateTime.now;

  /// Injectable sleeper so retries are testable in milliseconds.
  Future<void> Function(Duration) _sleep = Future<void>.delayed;

  set clock(DateTime Function() f) => _now = f;
  set sleeper(Future<void> Function(Duration) f) => _sleep = f;

  Future<Result<Map<String, Object?>>> getJson(
    Uri uri, {
    Map<String, String> headers = const {},
  }) =>
      send('GET', uri, headers: headers);

  Future<Result<Map<String, Object?>>> postJson(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
  }) =>
      send('POST', uri, body: body, headers: headers);

  /// Opens a chunked response without buffering it, for SSE/streaming reads.
  ///
  /// Separate from [send] because streaming callers must classify failures
  /// before reading the body — retrying a stream mid-flight would duplicate
  /// output the user has already seen.
  Future<Result<http.StreamedResponse>> rawSend(http.Request request) async {
    final sent = await sendAnyStatus(request);
    final failure = sent.errorOrNull;
    if (failure != null) return Failure<http.StreamedResponse>(failure);

    final response = sent.requireValue;
    final status = response.statusCode;

    if (status == 401 || status == 403) {
      return Failure<http.StreamedResponse>.reason(
        FailureKind.unauthorized,
        message: 'Authentication required',
        statusCode: status,
        endpoint: request.url.toString(),
      );
    }
    if (status == 429) {
      return Failure<http.StreamedResponse>.reason(
        FailureKind.rateLimited,
        message: 'Rate limited',
        statusCode: status,
        endpoint: request.url.toString(),
      );
    }
    if (status >= 500) {
      return Failure<http.StreamedResponse>.reason(
        FailureKind.server,
        message: 'HTTP $status',
        statusCode: status,
        endpoint: request.url.toString(),
      );
    }
    if (status >= 400) {
      return Failure<http.StreamedResponse>.reason(
        FailureKind.validation,
        message: 'HTTP $status',
        statusCode: status,
        endpoint: request.url.toString(),
      );
    }
    return Success(response);
  }

  /// Sends a request and returns the response for **any** status, failing only
  /// on transport-level problems.
  ///
  /// Why this sits beside [rawSend] rather than replacing it: most callers want
  /// a 4xx turned into a typed failure and do not care about the body. Some do
  /// care, because for those endpoints the error body is the only actionable
  /// part of the response — a field-level `errors[]` array naming the property
  /// the schema expected, or a plain sentence naming a missing header.
  Future<Result<http.StreamedResponse>> sendAnyStatus(
    http.Request request,
  ) async {
    try {
      for (final interceptor in _interceptors) {
        await interceptor(request);
      }
      final response = await _http.send(request).timeout(timeout);
      return Success(response);
    } on TimeoutException catch (e) {
      return Failure<http.StreamedResponse>.reason(
        FailureKind.timeout,
        message: 'No response within ${timeout.inSeconds}s',
        cause: e,
        endpoint: request.url.toString(),
      );
    } on SocketException catch (e) {
      return Failure<http.StreamedResponse>.reason(
        FailureKind.network,
        message: e.message,
        cause: e,
        endpoint: request.url.toString(),
      );
    } on http.ClientException catch (e) {
      return Failure<http.StreamedResponse>.reason(
        FailureKind.network,
        message: e.message,
        cause: e,
        endpoint: request.url.toString(),
      );
    } catch (e) {
      return Failure<http.StreamedResponse>.reason(
        FailureKind.unknown,
        message: e.toString(),
        cause: e,
        endpoint: request.url.toString(),
      );
    }
  }

  /// Reads a whole response body, bounded by [bodyTimeout].
  ///
  /// Every `http.Response.fromStream` on a stream that came from this client
  /// should go through here: `package:http`'s buffering has no deadline, so one
  /// stalled hop would otherwise take the screen that is waiting on it with it.
  Future<http.Response> readBody(http.StreamedResponse streamed) =>
      http.Response.fromStream(streamed).timeout(bodyTimeout);

  /// GETs [start], following redirects **manually** so that every hop carries
  /// the cookie header belonging to *its* host.
  ///
  /// Why not let `package:http` follow: it resends the original request's
  /// headers verbatim, so a cross-host redirect such as
  /// `ugsqs.whu.edu.cn` → `cas.whu.edu.cn` carries the first host's cookies and
  /// never the CAS grant (CASTGC). Measured on 2026-10-18: with automatic
  /// following, the evaluation host's caslogin hop landed on the CAS sign-in
  /// page even though the session held a fresh CASTGC — the cookie simply never
  /// travelled to the host that needed it. Recomputing per hop is what turns
  /// "one sign-in" into a session that actually spans properties.
  ///
  /// `Set-Cookie` headers from earlier hops are kept in a small per-call jar and
  /// offered to later hops on the same domain, because the host that redeems a
  /// CAS ticket establishes its own session in the same response and every
  /// request after that needs it.
  ///
  /// The hop list is returned alongside the final response because a refusal
  /// that names the hop it happened on is a diagnosis, while "it didn't work"
  /// is not.
  Future<Result<RedirectedGet>> getFollowing(
    Uri start, {
    required String Function(Uri uri) cookieFor,
    Map<String, String> headers = const {},
    int maxRedirects = 6,
  }) async {
    var current = start;
    final hops = <HttpHop>[];
    final setCookies = <String, List<String>>{};
    final domainRe = RegExp(r';\s*domain\s*=\s*([^;]+)', caseSensitive: false);

    String jarFor(String host) {
      final out = <String>[];
      for (final e in setCookies.entries) {
        if (host == e.key || host.endsWith('.${e.key}')) {
          out.addAll(e.value);
        }
      }
      return out.join('; ');
    }

    for (var hop = 0; hop <= maxRedirects; hop++) {
      final host = current.host.toLowerCase();
      final cookie = [cookieFor(current), jarFor(host)]
          .where((c) => c.isNotEmpty)
          .join('; ');
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll({
          'accept':
              'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
          'user-agent': 'campus-atlas/0.1 (+open-source)',
          if (cookie.isNotEmpty) 'cookie': cookie,
          ...headers,
        });

      final sent = await sendAnyStatus(request);
      final failure = sent.errorOrNull;
      if (failure != null) return Failure<RedirectedGet>(failure);

      final http.Response response;
      try {
        response = await readBody(sent.requireValue);
      } on TimeoutException {
        return Failure<RedirectedGet>.reason(
          FailureKind.timeout,
          message: 'Headers came back but the body stalled for more than '
              '${bodyTimeout.inSeconds}s at '
              '${current.host}${current.path}',
          endpoint: current.toString(),
        );
      } catch (e) {
        return Failure<RedirectedGet>.reason(
          FailureKind.protocol,
          message: 'Could not read the response body',
          cause: e,
          endpoint: current.path,
        );
      }

      // Absorb this hop's cookies before looking at the Location, so the next
      // hop already has them.
      for (final sc
          in response.headersSplitValues['set-cookie'] ?? const <String>[]) {
        final pair = sc.split(';').first.trim();
        if (pair.isEmpty || !pair.contains('=')) continue;
        var domain = host;
        final m = domainRe.firstMatch(sc);
        if (m != null) {
          domain = (m.group(1) ?? '').trim().toLowerCase();
          if (domain.startsWith('.')) domain = domain.substring(1);
          if (domain.isEmpty) domain = host;
        }
        (setCookies[domain] ??= []).add(pair);
      }

      hops.add(HttpHop(response.statusCode, current));

      final location = response.headers['location'];
      final isRedirect =
          response.statusCode >= 300 && response.statusCode < 400;
      if (isRedirect && location != null && location.isNotEmpty) {
        final Uri next;
        try {
          next = current.resolve(location);
        } on FormatException catch (e) {
          // A malformed Location must surface as a failure, not as a thrown
          // exception: an exception here escapes through callers that only
          // handle Results, and whatever screen was waiting stays busy forever.
          return Failure<RedirectedGet>.reason(
            FailureKind.protocol,
            message: 'Redirect target is not a usable URL: $location',
            cause: e,
            endpoint: current.path,
          );
        }
        current = next;
        continue;
      }
      final finalHost = current.host.toLowerCase();
      final finalCookie = [cookieFor(current), jarFor(finalHost)]
          .where((c) => c.isNotEmpty)
          .join('; ');
      return Success(
        RedirectedGet(response, current, hops, cookieHeader: finalCookie),
      );
    }
    return Failure<RedirectedGet>.reason(
      FailureKind.protocol,
      message: 'More than $maxRedirects redirects; giving up',
      endpoint: start.path,
    );
  }

  /// Core request path. Always returns a [Result]; never throws for
  /// transport-level problems.
  Future<Result<Map<String, Object?>>> send(
    String method,
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
  }) async {
    var attempt = 0;
    while (true) {
      attempt += 1;
      final outcome = await _attempt(method, uri, body: body, headers: headers);

      // Retry only what a retry can fix: being offline, timing out, or a 5xx.
      // Retrying a 401 or a parse failure would just hammer a server that has
      // already told us the answer is not going to change.
      final retriable = switch (outcome) {
        Failure(:final failure) => failure.kind == FailureKind.network ||
            failure.kind == FailureKind.timeout ||
            failure.kind == FailureKind.server,
        Success() => false,
      };

      if (!retriable || attempt > maxRetries) return outcome;
      await _sleep(Duration(milliseconds: 300 * attempt));
    }
  }

  Future<Result<Map<String, Object?>>> _attempt(
    String method,
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
  }) async {
    final requestId = '${_now().microsecondsSinceEpoch}';
    final request = http.Request(method, uri)
      ..headers.addAll({
        'accept': 'application/json',
        'user-agent': 'campus-atlas/0.1 (+open-source)',
        'x-request-id': requestId,
        ...headers,
      });

    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    try {
      for (final interceptor in _interceptors) {
        await interceptor(request);
      }
      final http.StreamedResponse streamed;
      try {
        streamed = await _http.send(request).timeout(timeout);
      } on TimeoutException catch (e) {
        return Failure<Map<String, Object?>>.reason(
          FailureKind.timeout,
          message: 'No response within ${timeout.inSeconds}s',
          cause: e,
          endpoint: uri.toString(),
        );
      }
      // A separate catch below reports a stalled *body* with its own budget —
      // the two deadlines are different numbers and merging them would name the
      // wrong one.
      final response = await readBody(streamed);

      return _classify(response, uri);
    } on TimeoutException catch (e) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.timeout,
        message: 'The response body never completed within '
            '${bodyTimeout.inSeconds}s',
        cause: e,
        endpoint: uri.toString(),
      );
    } on SocketException catch (e) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.network,
        message: e.message,
        cause: e,
        endpoint: uri.toString(),
      );
    } on http.ClientException catch (e) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.network,
        message: e.message,
        cause: e,
        endpoint: uri.toString(),
      );
    } on FormatException catch (e) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.protocol,
        message: e.message,
        cause: e,
        endpoint: uri.toString(),
      );
    } catch (e) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.unknown,
        message: e.toString(),
        cause: e,
        endpoint: uri.toString(),
      );
    }
  }

  Result<Map<String, Object?>> _classify(http.Response r, Uri uri) {
    final status = r.statusCode;

    if (status == 401 || status == 403) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.unauthorized,
        message: 'Authentication required',
        statusCode: status,
        endpoint: uri.toString(),
      );
    }
    if (status == 429) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.rateLimited,
        message: 'Rate limited',
        statusCode: status,
        endpoint: uri.toString(),
      );
    }
    if (status >= 500) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.server,
        message: 'HTTP $status',
        statusCode: status,
        endpoint: uri.toString(),
      );
    }
    if (status >= 400) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.validation,
        message: 'HTTP $status',
        statusCode: status,
        endpoint: uri.toString(),
      );
    }

    // A captive portal answers a probe URL with an HTML login page. The body is
    // technically a 200, so status checks alone would happily report success.
    final contentType = r.headers['content-type'] ?? '';
    if (!contentType.contains('json')) {
      final looksLikeHtml = RegExp(r'<\s*(html|!doctype)', caseSensitive: false)
          .hasMatch(r.body.length > 256 ? r.body.substring(0, 256) : r.body);
      if (looksLikeHtml) {
        return Failure<Map<String, Object?>>.reason(
          FailureKind.protocol,
          message: 'Expected JSON, received an HTML document '
              '(captive portal or error page)',
          statusCode: status,
          endpoint: uri.toString(),
        );
      }
    }

    try {
      final decoded = jsonDecode(r.body);
      if (decoded is Map<String, Object?>) {
        return Success(decoded);
      }
      // Some endpoints wrap payloads in a bare array; surface it rather than
      // dropping it, under the conventional `data` key.
      if (decoded is List) {
        return Success(<String, Object?>{'data': decoded});
      }
      return Failure<Map<String, Object?>>.reason(
        FailureKind.invalidData,
        message: 'Top-level JSON was ${decoded.runtimeType}, expected object',
        statusCode: status,
        endpoint: uri.toString(),
      );
    } on FormatException catch (e) {
      return Failure<Map<String, Object?>>.reason(
        FailureKind.invalidData,
        message: 'Malformed JSON: ${e.message}',
        cause: e,
        statusCode: status,
        endpoint: uri.toString(),
      );
    }
  }

  void dispose() => _http.close();
}

/// One hop of a manually followed redirect chain: the status a request to
/// [uri] answered with.
class HttpHop {
  const HttpHop(this.statusCode, this.uri);

  final int statusCode;
  final Uri uri;

  /// `302 ugsqs.whu.edu.cn/caslogin` — host and path only. Query strings are
  /// left out deliberately: a CAS `ticket=` parameter is a credential, and this
  /// string is shown to the reader.
  String get label => '$statusCode ${uri.host}${uri.path}';
}

/// The end of a manually followed redirect chain, with its hop list.
class RedirectedGet {
  const RedirectedGet(
    this.response,
    this.finalUri,
    this.hops, {
    this.cookieHeader = '',
  });

  final http.Response response;
  final Uri finalUri;
  final List<HttpHop> hops;

  /// The `Cookie` header for [finalUri] after the chain's `Set-Cookie` headers
  /// were absorbed.
  ///
  /// A POST that follows a session handshake needs the service cookie the last
  /// hop set; without it the service answers as an anonymous caller. The
  /// per-call jar in [ApiClient.getFollowing] already holds it, so it is
  /// exported here instead of being rebuilt by the caller.
  final String cookieHeader;

  /// One line per hop, `GET /caslogin` first — the shape a diagnosis wants.
  String get chainText => [
        'GET ${hops.isEmpty ? finalUri.path : hops.first.uri.path}',
        for (final h in hops) '  ${h.label}'
      ].join('\n');
}
