import 'dart:convert';

import 'package:campus_atlas/core/network/api_client.dart';
import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/features/grades_query/grades_query_repository.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Transport-level tests for the grade-query client.
///
/// The response *shapes* here are hand-authored: the real endpoints are
/// auth-walled and no body was ever recorded. What these tests therefore pin
/// down is not "the server sends this" but the behaviour that has to hold
/// whatever the server sends — sign-in gating, HTML-vs-JSON classification, and
/// the diagnostic buffer never capturing a credential.
void main() {
  GradesQueryRepository repoWith(
    http.Response Function(http.Request) handler,
  ) =>
      GradesQueryRepository(
        client: ApiClient(httpClient: MockClient((r) async => handler(r))),
      );

  /// A signed-in repository with a scripted transport.
  GradesQueryRepository signedIn(
    http.Response Function(http.Request) handler,
  ) {
    final repo = repoWith(handler);
    repo.token = 'test-token';
    return repo;
  }

  group('sign-in gating', () {
    test('every protected query refuses before the network when signed out',
        () async {
      var calls = 0;
      final repo = repoWith((_) {
        calls++;
        return http.Response('{}', 200);
      });

      final a = await repo.byName('高等数学');
      final b = await repo.teachers('uid');
      final c = await repo.view('offering');

      for (final r in [a, b, c]) {
        expect(r.errorOrNull?.kind, FailureKind.unauthorized);
        expect(r.errorOrNull?.message, contains('Sign in'));
      }
      expect(calls, 0, reason: 'nothing should have gone on the wire');
    });

    test('reviews is public, so it does not require sign-in', () async {
      var calls = 0;
      final repo = repoWith((_) {
        calls++;
        return http.Response('{"reviews":[],"total":0}', 200);
      });
      final r = await repo.reviews();
      expect(r.isSuccess, isTrue);
      expect(calls, 1);
    });

    test('signing out restores the gate', () async {
      final repo = signedIn((_) => http.Response('{}', 200));
      expect(repo.isSignedIn, isTrue);
      repo.signOut();
      expect(repo.isSignedIn, isFalse);
      final r = await repo.byName('x');
      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
    });
  });

  group('query validation', () {
    test('a blank course name is rejected locally', () async {
      var calls = 0;
      final repo = signedIn((_) {
        calls++;
        return http.Response('{}', 200);
      });
      final r = await repo.byName('   ');
      expect(r.errorOrNull?.kind, FailureKind.validation);
      expect(calls, 0);
    });

    test('a blank offering id is rejected locally', () async {
      final repo = signedIn((_) => http.Response('{}', 200));
      expect((await repo.view('')).errorOrNull?.kind, FailureKind.validation);
      expect(
          (await repo.teachers(' ')).errorOrNull?.kind, FailureKind.validation);
    });

    test('the course uid is path-encoded, not interpolated raw', () async {
      late Uri seen;
      final repo = signedIn((r) {
        seen = r.url;
        return http.Response('{"teachers":[]}', 200);
      });
      await repo.teachers('a b/c');
      expect(seen.path, contains('a%20b%2Fc'));
    });
  });

  group('body classification', () {
    test('a 200 HTML sign-in page is a protocol failure, not empty data',
        () async {
      // The failure that matters most: a status-code-only check would report
      // "no courses found" for a page that says "please sign in".
      final repo = signedIn((_) => http.Response(
            '<!DOCTYPE html><html><title>统一身份认证</title></html>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ));
      final r = await repo.byName('高等数学');
      expect(r.isFailure, isTrue);
      expect(r.errorOrNull?.kind, FailureKind.protocol);
      expect(r.errorOrNull?.message, contains('HTML'));
    });

    test('a non-JSON, non-HTML body is an invalid payload', () async {
      final repo = signedIn((_) => http.Response('please try again', 200));
      final r = await repo.byName('x');
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });

    test('a bare JSON array is accepted under the data key', () async {
      final repo = signedIn((_) => http.Response(
            '[{"name":"高等数学","id":"1"}]',
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
      final r = await repo.byName('x');
      expect(r.isSuccess, isTrue);
      expect(r.requireValue, hasLength(1));
      expect(r.requireValue.single.name, '高等数学');
    });

    test('a JSON scalar root is rejected', () async {
      final repo = signedIn((_) => http.Response('42', 200));
      final r = await repo.byName('x');
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });

    test('the root object IS the course, per the live response', () async {
      // ⚠️ A real signed-in response, captured verbatim. Not modelled.
      //
      //   {"course_name":"高等数学","offerings":[]}
      //
      // There is no array of courses: the root is the course, with its
      // offerings hanging off it. Looking only for a course-shaped *list*
      // misses the root entirely and reports "nothing found" for a course the
      // server did find.
      final repo = signedIn((_) => http.Response(
            '{"course_name":"高等数学","offerings":[]}',
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));

      final r = await repo.byName('高等数学');
      expect(r.isSuccess, isTrue,
          reason: 'an empty offerings list is a successful answer');
      expect(r.requireValue, hasLength(1),
          reason: 'the course was found; it simply has no offerings');
      expect(r.requireValue.single.name, '高等数学');
      expect(r.requireValue.single.isEmpty, isTrue);
      expect(r.requireValue.single.teachers, isEmpty);
    });

    test('a 422 is an error, not a successful empty result', () async {
      // A 422 body is valid JSON, so without explicit status handling it falls
      // through the row extractor and reads as "no course found" — which is
      // the exact opposite of what happened.
      final repo = signedIn((_) => http.Response(
            '{"status":422,"detail":"validation failed","errors":['
            '{"message":"required query parameter is missing",'
            '"location":"query.course_name","value":""}]}',
            422,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
      final r = await repo.byName('高等数学');
      expect(r.isFailure, isTrue);
      expect(r.errorOrNull?.kind, FailureKind.validation);
      expect(r.errorOrNull?.message, contains('course_name'),
          reason: 'the field error is the only actionable part');
    });

    test('sends the parameter as course_name, not query', () async {
      // Pinned from a live 422: {"location":"query.course_name"}. The 422 only
      // surfaces behind authentication, so it cannot be found unsigned.
      late Uri seen;
      final repo = signedIn((r) {
        seen = r.url;
        return http.Response('{"courses":[]}', 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      });
      await repo.byName('高等数学');
      expect(seen.queryParameters['course_name'], '高等数学');
      expect(seen.queryParameters.containsKey('query'), isFalse);
      expect(seen.path, '/api/v1/course/grades/by-name');
    });

    test('a 401 maps through as unauthorized', () async {
      final repo = signedIn((_) => http.Response(
            '{"status":401,"code":"UNAUTHORIZED"}',
            401,
          ));
      expect(
          (await repo.byName('x')).errorOrNull?.kind, FailureKind.unauthorized);
    });
  });

  group('diagnostic buffer', () {
    test('captures the body of a data query', () async {
      const body = '{"courses":[{"name":"线性代数","id":"9"}]}';
      // charset is explicit: package:http encodes with latin1 when a
      // content-type carries no charset, which throws on these characters.
      final repo = signedIn((_) => http.Response(
            body,
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));

      expect(repo.hasDiagnostics, isFalse);
      await repo.byName('线性代数');

      expect(repo.hasDiagnostics, isTrue);
      expect(repo.lastRawResponse, body);
      expect(repo.lastRawEndpoint, contains('/api/v1/course/grades/by-name'));
    });

    test('captures the body even when the request fails to parse', () async {
      // The whole point: when the shape is wrong, the reader needs to see what
      // actually arrived. Capturing only on success would hide the diagnosis.
      const body = '{"unexpected":{"deeply":{"nested":true}}}';
      final repo = signedIn((_) => http.Response(body, 200));
      await repo.byName('x');
      expect(repo.lastRawResponse, body);
    });

    test('the login response is never captured', () async {
      // It carries the access token, and this buffer exists to be copied into
      // a message. A credential must not be able to reach it.
      const tokenBody =
          '{"access_token":"super-secret-token-value","token_type":"bearer"}';

      final repo = repoWith((r) {
        if (r.url.path.endsWith('/verification/altcha')) {
          return http.Response(
            '{"algorithm":"SHA-256","challenge":"${_sha256('s1')}",'
            '"salt":"s","signature":"g","maxnumber":1}',
            200,
          );
        }
        return http.Response(tokenBody, 200);
      });

      final result =
          await repo.login(identifier: '00000000000', password: 'pw');
      expect(result.isSuccess, isTrue);
      expect(repo.token, 'super-secret-token-value');

      expect(repo.hasDiagnostics, isFalse,
          reason: 'the token must not be in a buffer meant for sharing');
      expect(repo.lastRawResponse ?? '', isNot(contains('super-secret')));
    });

    test('clearDiagnostics empties it', () async {
      final repo = signedIn((_) => http.Response('{"courses":[]}', 200));
      await repo.byName('x');
      expect(repo.hasDiagnostics, isTrue);

      repo.clearDiagnostics();
      expect(repo.hasDiagnostics, isFalse);
      expect(repo.lastRawResponse, isNull);
      expect(repo.lastRawEndpoint, isNull);
    });

    test('a huge body is truncated rather than held whole', () async {
      final body = '{"courses":[${'"x":1,' * 20000}"done":1]}';
      final repo = signedIn((_) => http.Response(body, 200));
      await repo.byName('x');
      expect(repo.lastRawResponse!.length, lessThanOrEqualTo(40000));
    });
  });

  group('login', () {
    test('an unsolvable challenge fails without sending a login', () async {
      var loginAttempts = 0;

      final repo = repoWith((r) {
        if (r.url.path.endsWith('/verification/altcha')) {
          // No number below 10 hashes to "c", so this cannot be solved. The
          // caller must surface that rather than posting a malformed login.
          return http.Response(
            '{"algorithm":"SHA-256","challenge":"c","salt":"s",'
            '"signature":"g","maxnumber":10}',
            200,
          );
        }
        loginAttempts++;
        return http.Response('{"access_token":"tok"}', 200);
      });

      final r = await repo.login(identifier: '00000000000', password: 'pw');
      expect(r.isFailure, isTrue);
      expect(r.errorOrNull?.kind, FailureKind.protocol);
      expect(r.errorOrNull?.message, contains('could not be solved'));
      expect(repo.token, isNull);
      expect(loginAttempts, 0, reason: 'a bad login must not be posted');
    });

    test('carries the solution in X-Altcha, the header this service reads',
        () async {
      late http.Request loginRequest;

      final repo = repoWith((r) {
        if (r.url.path.endsWith('/verification/altcha')) {
          // Salt "s" with answer 1, inside a budget of 5 — solvable.
          return http.Response(
            '{"algorithm":"SHA-256",'
            '"challenge":"${_sha256('s1')}",'
            '"salt":"s","signature":"g","maxnumber":5}',
            200,
          );
        }
        loginRequest = r;
        return http.Response('{"access_token":"tok"}', 200);
      });

      final r = await repo.login(identifier: '00000000000', password: 'pw');
      expect(r.isSuccess, isTrue);
      expect(repo.token, 'tok');

      // `X-Altcha`, not Altcha's own `Authorization: Altcha …`. Using the
      // vendor-standard header draws
      // 400 {"detail":"X-Altcha header required","business_code":1018} —
      // verified against the live service.
      final header = loginRequest.headers.entries
          .firstWhere((e) => e.key.toLowerCase() == 'x-altcha')
          .value;
      expect(header, isNot(startsWith('Altcha ')),
          reason: 'the payload goes in the header value bare');

      final payload = jsonDecode(utf8.decode(base64Url.decode(header)))
          as Map<String, Object?>;
      expect(payload['number'], 1);
      expect(payload['salt'], 's');
    });

    test('the body is exactly {identifier, password}', () async {
      late http.Request loginRequest;

      final repo = repoWith((r) {
        if (r.url.path.endsWith('/verification/altcha')) {
          return http.Response(
            '{"algorithm":"SHA-256","challenge":"${_sha256('s1')}",'
            '"salt":"s","signature":"g","maxnumber":5}',
            200,
          );
        }
        loginRequest = r;
        return http.Response('{"access_token":"tok"}', 200);
      });

      await repo.login(identifier: '202300000000', password: 'pw1234');

      // The model forbids extras: any other property draws
      // 422 "unexpected property". And `identifier` is the only name it
      // accepts — email/account/username all draw
      // "expected required property identifier to be present".
      final body = jsonDecode(loginRequest.body) as Map<String, Object?>;
      expect(body.keys, unorderedEquals(['identifier', 'password']));
      expect(body['identifier'], '202300000000');
    });

    test('the password travels in the body, never the URL', () async {
      late http.Request loginRequest;

      final repo = repoWith((r) {
        if (r.url.path.endsWith('/verification/altcha')) {
          return http.Response(
            '{"algorithm":"SHA-256","challenge":"${_sha256('s1')}",'
            '"salt":"s","signature":"g","maxnumber":5}',
            200,
          );
        }
        loginRequest = r;
        return http.Response('{"access_token":"tok"}', 200);
      });

      await repo.login(identifier: '00000000000', password: 'hunter2');

      // A password in a query string lands in server logs and browser history.
      expect(loginRequest.url.query, isEmpty);
      expect(loginRequest.url.toString(), isNot(contains('hunter2')));
      expect(loginRequest.body, contains('hunter2'));
    });

    test('a 422 field error is surfaced, not just "validation failed"',
        () async {
      // The field-level `errors[]` array is the only actionable part of a 422:
      // `detail` reads just "validation failed" and names nothing.
      final repo = repoWith((r) {
        if (r.url.path.endsWith('/verification/altcha')) {
          return http.Response(
            '{"algorithm":"SHA-256","challenge":"${_sha256('s1')}",'
            '"salt":"s","signature":"g","maxnumber":5}',
            200,
          );
        }
        return http.Response(
          '{"title":"Unprocessable Entity","status":422,'
          '"detail":"validation failed","errors":['
          '{"message":"expected required property identifier to be present",'
          '"location":"body"}]}',
          422,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final r = await repo.login(identifier: 'x', password: 'y');
      expect(r.isFailure, isTrue);
      final message = r.errorOrNull?.message ?? '';
      expect(message, contains('identifier'));
      expect(message, contains('body'));
      expect(message, isNot(contains('validation failed')),
          reason: 'the generic detail must not shadow the specific error');
      expect(repo.token, isNull);
    });

    test('refuses a blank identifier or password before the network', () async {
      var calls = 0;
      final repo = repoWith((_) {
        calls++;
        return http.Response('{}', 200);
      });

      expect(
          (await repo.login(identifier: '  ', password: 'pw'))
              .errorOrNull
              ?.kind,
          FailureKind.validation);
      expect(
          (await repo.login(identifier: 'a@b', password: '')).errorOrNull?.kind,
          FailureKind.validation);
      expect(calls, 0);
    });

    test('reads a token from each of the common envelope shapes', () async {
      for (final body in const [
        '{"access_token":"T1"}',
        '{"token":"T2"}',
        '{"data":{"access_token":"T3"}}',
      ]) {
        final repo = repoWith((r) {
          if (r.url.path.endsWith('/verification/altcha')) {
            // A solvable challenge: SHA-256("s1") is the target.
            return http.Response(
              '{"algorithm":"SHA-256",'
              '"challenge":"${_sha256('s1')}",'
              '"salt":"s","signature":"g","maxnumber":5}',
              200,
            );
          }
          return http.Response(body, 200);
        });
        final r = await repo.login(identifier: '00000000000', password: 'pw');
        expect(r.isSuccess, isTrue, reason: body);
        expect(repo.token, startsWith('T'));
      }
    });

    test('a challenge that is not a challenge yields a protocol failure',
        () async {
      final repo = repoWith((r) {
        if (r.url.path.endsWith('/verification/altcha')) {
          return http.Response('<html>gate is off</html>', 200);
        }
        return http.Response('{}', 200);
      });
      final r = await repo.login(identifier: '00000000000', password: 'pw');
      expect(r.errorOrNull?.kind, FailureKind.protocol);
      expect(repo.token, isNull);
    });
  });

  group('routes', () {
    test('the declared route list matches what the client calls', () {
      // A cheap guard against the surface drifting away from its own
      // documentation.
      expect(GradesQueryRepository.routes, hasLength(7));
      expect(
        GradesQueryRepository.routes.join('\n'),
        allOf(
          contains('/api/v1/verification/altcha'),
          contains('/api/v1/user/login'),
          contains('/api/v1/course/grades/by-name'),
          contains('/api/v1/course/grades/teachers/'),
          contains('/api/v1/course/grades/view/'),
          contains('/api/v1/reviews'),
        ),
      );
    });
  });
}

/// SHA-256, used only to build a challenge the solver can actually solve.
///
/// `package:crypto` rather than a reimplementation: this test is about the
/// solver's behaviour, not about hashing, and the altcha_test already pins the
/// hash against the solver's own output.
String _sha256(String input) => sha256.convert(utf8.encode(input)).toString();
