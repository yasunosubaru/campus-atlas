import 'dart:convert';

import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/features/grades_query/ham/ham_token_console.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A stand-in for Ham's token console BFF.
///
/// The shapes here are transcribed from `ham-web/services/token/api.ts` — the
/// console's own client — so the fixture and the real thing agree on names even
/// though the transport is being faked.
http.Client _console({
  Map<String, Object?>? listBody,
  Map<String, Object?>? createBody,
  int status = 200,
  void Function(http.Request)? onRequest,
}) =>
    MockClient((request) async {
      onRequest?.call(request);
      if (status != 200) {
        return http.Response(
          jsonEncode({'code': '$status', 'message': '登录失败了'}),
          status,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      switch (request.method) {
        case 'GET':
          return http.Response(jsonEncode(listBody ?? <Object?>[]), 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        case 'POST':
          return http.Response(
            jsonEncode(createBody ?? const <String, Object?>{}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        default:
          return http.Response('', 204);
      }
    });

/// One item as `TokenListItem` describes it.
Map<String, Object?> _item(String id, {String? expires}) => {
      'id': id,
      'name': 'campus-atlas',
      'last4': 'a1b2',
      'scopes': ['mcp', 'mcp:read'],
      'last_used_at': null,
      'expires_at': expires ??
          DateTime.now().add(const Duration(days: 30)).toIso8601String(),
      'created_at': DateTime.now().toIso8601String(),
    };

void main() {
  group('listing keys', () {
    test('reads the array the console returns', () async {
      final console = HamTokenConsole(
        httpClient: _console(listBody: {
          'data': [_item('tok_1'), _item('tok_2')],
        }),
      );
      final r = await console.list('oauth-token');
      console.close();

      expect(r.isSuccess, isTrue);
      expect(r.requireValue.map((t) => t.id), ['tok_1', 'tok_2']);
      expect(r.requireValue.first.scopes, contains('mcp:read'));
    });

    test('accepts a bare array as well as a `data` envelope', () async {
      // The BFF passes the backend's body straight through, and which of the two
      // it is has not been observed — so both are read.
      final console = HamTokenConsole(
        httpClient: _console(listBody: null),
      );
      // An empty body means "no keys", not an error.
      final r = await console.list('oauth-token');
      console.close();

      expect(r.isSuccess, isTrue);
      expect(r.requireValue, isEmpty);
    });
  });

  group('creating a key', () {
    test('returns the raw token and its metadata', () async {
      final console = HamTokenConsole(
        httpClient: _console(createBody: {
          'raw_token': 'ham_created_value',
          'token': _item('tok_new'),
        }),
      );
      final r = await console.create('oauth-token', ttlDays: 30);
      console.close();

      expect(r.isSuccess, isTrue);
      expect(r.requireValue.rawToken, 'ham_created_value');
      expect(r.requireValue.token.id, 'tok_new');
    });

    test('sends the console\'s own request shape', () async {
      http.Request? seen;
      final console = HamTokenConsole(
        httpClient: _console(
          createBody: {'raw_token': 'x', 'token': _item('t')},
          onRequest: (r) => seen = r,
        ),
      );
      await console.create('oauth-token', ttlDays: 30);
      console.close();

      final body = jsonDecode(seen!.body) as Map<String, Object?>;
      // `ttl_days` is the console's vocabulary and the reason to call it at all.
      expect(body['ttl_days'], 30);
      expect(body['name'], 'campus-atlas');
      expect(body['scopes'], isA<List<Object?>>());
      expect(seen!.headers['authorization'], 'Bearer oauth-token');
    });

    test('accepts a `data` envelope around the result', () async {
      final console = HamTokenConsole(
        httpClient: _console(createBody: {
          'data': {
            'raw_token': 'ham_wrapped',
            'token': _item('tok_w'),
          },
        }),
      );
      final r = await console.create('oauth-token');
      console.close();

      expect(r.requireValue.rawToken, 'ham_wrapped');
    });

    test('a response without raw_token is a parse failure, not an empty key',
        () async {
      final console = HamTokenConsole(
        httpClient: _console(createBody: {'token': _item('tok_n')}),
      );
      final r = await console.create('oauth-token');
      console.close();

      expect(r.isFailure, isTrue);
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
      expect(r.errorOrNull?.message, contains('raw_token'));
    });
  });

  group('a refused credential', () {
    test('403 is reported as the console wanting a web session', () async {
      // This is the branch that matters: the app tries the console with an OAuth
      // token and is expected to cope with a refusal, because the query feature
      // works without it.
      final console = HamTokenConsole(httpClient: _console(status: 403));
      final r = await console.create('oauth-token');
      console.close();

      expect(r.isFailure, isTrue);
      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
      expect(r.errorOrNull?.message, contains('网页登录会话'));
      // Whatever happens, the credential must not be echoed back.
      expect(r.errorOrNull?.message, isNot(contains('oauth-token')));
    });

    test('401 behaves the same way', () async {
      final console = HamTokenConsole(httpClient: _console(status: 401));
      final r = await console.list('oauth-token');
      console.close();

      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
    });

    test('a 500 is a server failure, so the caller can tell them apart',
        () async {
      final console = HamTokenConsole(httpClient: _console(status: 500));
      final r = await console.list('oauth-token');
      console.close();

      expect(r.errorOrNull?.kind, FailureKind.server);
    });
  });

  group('revoking and rotating', () {
    test('revoke treats an empty 204 as success', () async {
      final console = HamTokenConsole(
        httpClient: MockClient((_) async => http.Response('', 204)),
      );
      final r = await console.revoke('oauth-token', 'tok_1');
      console.close();

      expect(r.isSuccess, isTrue);
    });

    test('rotate returns a new raw token', () async {
      final console = HamTokenConsole(
        httpClient: _console(createBody: {
          'raw_token': 'ham_rotated',
          'token': _item('tok_1'),
        }),
      );
      final r = await console.rotate('oauth-token', 'tok_1', ttlDays: 30);
      console.close();

      expect(r.requireValue.rawToken, 'ham_rotated');
    });
  });

  group('a listed token', () {
    test('knows when it has expired', () {
      final live = HamConsoleToken.tryParse(_item(
        'tok_live',
        expires: DateTime.now().add(const Duration(days: 1)).toIso8601String(),
      ));
      final dead = HamConsoleToken.tryParse(_item(
        'tok_dead',
        expires:
            DateTime.now().subtract(const Duration(days: 1)).toIso8601String(),
      ));

      expect(live!.isExpired, isFalse);
      expect(dead!.isExpired, isTrue);
    });

    test('an entry without an id is discarded', () {
      expect(HamConsoleToken.tryParse(const {'name': 'x'}), isNull);
      expect(HamConsoleToken.tryParse(null), isNull);
    });
  });
}
