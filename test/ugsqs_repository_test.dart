import 'dart:convert';

import 'package:campus_atlas/core/network/api_client.dart';
import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/features/teaching_eval/ugsqs_repository.dart';
import 'package:campus_atlas/features/whu_auth/whu_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

WhuSession session() => WhuSession(
      cookies: const {'JSESSIONID': 'UGSQS-SESSION'},
      scoped: const [
        (
          name: 'JSESSIONID',
          value: 'UGSQS-SESSION',
          domain: 'ugsqs.whu.edu.cn',
          path: '/',
          hostOnly: true,
        ),
      ],
      acquiredAt: DateTime.now(),
    );

void main() {
  group('UgsqsRepository.resolveEntry', () {
    test('posts the student id and answers the forwardURL', () async {
      late http.Request captured;
      final client = ApiClient(
        maxRetries: 0,
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'success': true,
              'forwardURL': 'https://ugsqs.whu.edu.cn/eval?ticket=abc',
            })),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await UgsqsRepository(
        client: client,
        session: session(),
      ).resolveEntry(userId: ' STUDENT-0000 ');

      expect(result.isSuccess, isTrue, reason: result.errorOrNull?.message);
      expect(result.requireValue,
          'https://ugsqs.whu.edu.cn/eval?ticket=abc');
      expect(captured.method, 'POST');
      expect(captured.url.path, '/loginSSO');
      expect(captured.bodyFields, {'userId': 'STUDENT-0000'});
      expect(captured.headers['cookie'], contains('JSESSIONID=UGSQS-SESSION'));
      expect(captured.headers['referer'], endsWith('/caslogin'));
    });

    test('a refusal carries the message the page would have shown', () async {
      final client = ApiClient(
        maxRetries: 0,
        httpClient: MockClient((_) async => http.Response.bytes(
              utf8.encode(jsonEncode({
                'success': false,
                'msg': '用户不存在',
              })),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );

      final result = await UgsqsRepository(
        client: client,
        session: session(),
      ).resolveEntry(userId: '1');

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull?.kind, FailureKind.validation);
      expect(result.errorOrNull?.message, contains('用户不存在'));
    });

    test('success without a forwardURL is invalid data', () async {
      final client = ApiClient(
        maxRetries: 0,
        httpClient: MockClient((_) async => http.Response(
              '{"success":true}',
              200,
              headers: {'content-type': 'application/json'},
            )),
      );

      final result = await UgsqsRepository(
        client: client,
        session: session(),
      ).resolveEntry(userId: '1');

      expect(result.errorOrNull?.kind, FailureKind.invalidData);
    });

    test('a non-http forwardURL is refused', () async {
      final client = ApiClient(
        maxRetries: 0,
        httpClient: MockClient((_) async => http.Response(
              '{"success":true,"forwardURL":"javascript:alert(1)"}',
              200,
              headers: {'content-type': 'application/json'},
            )),
      );

      final result = await UgsqsRepository(
        client: client,
        session: session(),
      ).resolveEntry(userId: '1');

      expect(result.errorOrNull?.kind, FailureKind.protocol);
    });

    test('an HTML answer is reported as an expired session', () async {
      final client = ApiClient(
        maxRetries: 0,
        httpClient: MockClient((_) async => http.Response(
              '<html><body>authserver</body></html>',
              200,
              headers: {'content-type': 'text/html'},
            )),
      );

      final result = await UgsqsRepository(
        client: client,
        session: session(),
      ).resolveEntry(userId: '1');

      expect(result.errorOrNull?.kind, FailureKind.unauthorized);
    });

    test('no session never sends a request', () async {
      final client = ApiClient(httpClient: MockClient((_) async {
        fail('no request should be sent without a session');
      }));

      final result = await UgsqsRepository(
        client: client,
        session: null,
      ).resolveEntry(userId: '1');

      expect(result.errorOrNull?.kind, FailureKind.unauthorized);
    });

    test('an empty id is refused before any request', () async {
      final client = ApiClient(httpClient: MockClient((_) async {
        fail('no request should be sent without an id');
      }));

      final result = await UgsqsRepository(
        client: client,
        session: session(),
      ).resolveEntry(userId: '   ');

      expect(result.errorOrNull?.kind, FailureKind.validation);
    });
  });
}
