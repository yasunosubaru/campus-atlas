import 'package:campus_atlas/core/network/api_client.dart';
import 'package:campus_atlas/core/result.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  /// Builds a client whose backoff never actually waits, so retry counts can
  /// be asserted without slowing the suite down.
  ApiClient clientWith(
    MockClient handler, {
    int maxRetries = 2,
    Duration timeout = const Duration(seconds: 5),
  }) {
    final client = ApiClient(
      httpClient: handler,
      maxRetries: maxRetries,
      timeout: timeout,
    );
    client.sleeper = (_) async {};
    return client;
  }

  final uri = Uri.parse('https://api.example.test/v1/ping');

  group('success paths', () {
    test('returns a JSON object as Success', () async {
      final client = clientWith(
        MockClient((request) async => http.Response(
              '{"hello":"world"}',
              200,
              headers: {'content-type': 'application/json'},
            )),
      );
      final r = await client.getJson(uri);
      expect(r.isSuccess, isTrue);
      expect(r.requireValue['hello'], 'world');
    });

    test('wraps a bare JSON array under the conventional data key', () async {
      final client = clientWith(
        MockClient((request) async => http.Response(
              '[1,2,3]',
              200,
              headers: {'content-type': 'application/json'},
            )),
      );
      final r = await client.getJson(uri);
      expect(r.isSuccess, isTrue);
      expect(r.requireValue['data'], [1, 2, 3]);
    });
  });

  group('status classification', () {
    Future<Result<Map<String, Object?>>> statusOf(int status) async {
      final client = clientWith(
        MockClient((request) async => http.Response(
              '{}',
              status,
              headers: {'content-type': 'application/json'},
            )),
        maxRetries: 0,
      );
      return client.getJson(uri);
    }

    test('401 becomes unauthorized', () async {
      final r = await statusOf(401);
      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
      expect(r.errorOrNull?.statusCode, 401);
    });

    test('403 becomes unauthorized', () async {
      final r = await statusOf(403);
      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
    });

    test('429 becomes rateLimited', () async {
      final r = await statusOf(429);
      expect(r.errorOrNull?.kind, FailureKind.rateLimited);
    });

    test('404 becomes validation rather than a retryable server error',
        () async {
      final r = await statusOf(404);
      expect(r.errorOrNull?.kind, FailureKind.validation);
    });

    test('500 becomes server', () async {
      final r = await statusOf(500);
      expect(r.errorOrNull?.kind, FailureKind.server);
    });
  });

  group('content classification', () {
    test('an HTML body with a non-JSON content type is a protocol failure',
        () async {
      final client = clientWith(
        MockClient((request) async => http.Response(
              '<!DOCTYPE html><html><body>Portal login</body></html>',
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            )),
        maxRetries: 0,
      );
      final r = await client.getJson(uri);
      expect(r.errorOrNull?.kind, FailureKind.protocol);
      expect(r.errorOrNull!.message, contains('captive portal'));
    });

    test('malformed JSON with a JSON content type is invalidData', () async {
      final client = clientWith(
        MockClient((request) async => http.Response(
              '{not json',
              200,
              headers: {'content-type': 'application/json'},
            )),
        maxRetries: 0,
      );
      final r = await client.getJson(uri);
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });

    test('valid JSON that is not an object is invalidData', () async {
      final client = clientWith(
        MockClient((request) async => http.Response(
              '"just a string"',
              200,
              headers: {'content-type': 'application/json'},
            )),
        maxRetries: 0,
      );
      final r = await client.getJson(uri);
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });
  });

  group('retry policy', () {
    test('retries a 500 exactly maxRetries times before giving up', () async {
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts += 1;
          return http.Response(
            '{}',
            500,
            headers: {'content-type': 'application/json'},
          );
        }),
        maxRetries: 2,
      );

      final r = await client.getJson(uri);
      expect(r.errorOrNull?.kind, FailureKind.server);
      expect(attempts, 3, reason: '1 initial attempt + 2 retries');
    });

    test('stops at the first success', () async {
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts += 1;
          if (attempts < 3) {
            return http.Response(
              '{}',
              503,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            '{"ok":true}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        maxRetries: 5,
      );

      final r = await client.getJson(uri);
      expect(r.isSuccess, isTrue);
      expect(attempts, 3);
    });

    test('does not retry an unauthorized response', () async {
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts += 1;
          return http.Response(
            '{}',
            401,
            headers: {'content-type': 'application/json'},
          );
        }),
        maxRetries: 3,
      );

      await client.getJson(uri);
      expect(attempts, 1, reason: 'a 401 will not become a 200 by retrying');
    });

    test('does not retry a protocol failure', () async {
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts += 1;
          return http.Response('<html>oops</html>', 200,
              headers: {'content-type': 'text/html'});
        }),
        maxRetries: 3,
      );

      await client.getJson(uri);
      expect(attempts, 1);
    });

    test('backs off for an increasing interval on each attempt', () async {
      final delays = <Duration>[];
      var attempts = 0;
      final client = clientWith(
        MockClient((request) async {
          attempts += 1;
          return http.Response(
            '{}',
            500,
            headers: {'content-type': 'application/json'},
          );
        }),
        maxRetries: 2,
      );
      client.sleeper = (d) async => delays.add(d);

      await client.getJson(uri);
      expect(attempts, 3);
      expect(delays.length, 2);
      expect(delays[1].inMilliseconds, greaterThan(delays[0].inMilliseconds));
    });
  });

  group('POST', () {
    test('serialises the body as JSON and sets the content type', () async {
      http.Request? captured;
      final client = clientWith(
        MockClient((request) async {
          captured = request;
          return http.Response(
            '{"ok":true}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await client.postJson(uri, body: {'a': 1});
      expect(captured, isNotNull);
      expect(captured!.headers['content-type'], contains('application/json'));
      expect(captured!.body, '{"a":1}');
    });
  });
}
