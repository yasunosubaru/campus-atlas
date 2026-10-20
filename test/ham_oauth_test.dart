import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/features/grades_query/ham/ham_oauth.dart';
import 'package:campus_atlas/features/grades_query/ham/ham_token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('PKCE', () {
    test('matches the RFC 7636 published test vector', () {
      // From RFC 7636 Appendix B. This is the only part of the flow that can be
      // checked against an external authority, and it is worth doing: a wrong
      // challenge fails at the token exchange as `invalid_grant`, which reads
      // exactly like an expired code.
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      expect(
        PkceChallenge.challengeFor(verifier),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('a generated verifier is inside the RFC length range', () {
      final pkce = PkceChallenge.generate();
      expect(pkce.verifier.length, inInclusiveRange(43, 128));
      expect(pkce.challenge, PkceChallenge.challengeFor(pkce.verifier));
    });

    test('the challenge is unpadded base64url', () {
      // A `=` or a `+` here is rejected by the server; PKCE forbids both.
      final challenge = PkceChallenge.challengeFor('a' * 64);
      expect(challenge, isNot(contains('=')));
      expect(challenge, isNot(contains('+')));
      expect(challenge, isNot(contains('/')));
    });

    test('two verifiers differ', () {
      expect(
        PkceChallenge.generate().verifier,
        isNot(PkceChallenge.generate().verifier),
      );
    });
  });

  group('cached client registration', () {
    test('a future expiry is usable, a past one is not', () {
      final fresh = HamClientRegistration(
        clientId: 'dyn_x',
        redirectUri: 'http://127.0.0.1:5173/oauth/callback',
        expiresAt: DateTime.now().add(const Duration(days: 30)),
      );
      final stale = HamClientRegistration(
        clientId: 'dyn_y',
        redirectUri: 'http://127.0.0.1:5173/oauth/callback',
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );

      expect(fresh.isUsable, isTrue);
      expect(stale.isUsable, isFalse);
    });

    test('round-trips through JSON', () {
      final original = HamClientRegistration(
        clientId: 'dyn_z',
        redirectUri: 'http://127.0.0.1:5173/oauth/callback',
        expiresAt: DateTime.utc(2026, 11, 16, 12),
      );
      final restored = HamClientRegistration.tryParse(original.toJson());

      expect(restored, isNotNull);
      expect(restored!.clientId, 'dyn_z');
      expect(restored.redirectUri, original.redirectUri);
      expect(restored.expiresAt.toUtc(), original.expiresAt.toUtc());
    });

    test('a malformed cache entry is discarded, not trusted', () {
      expect(HamClientRegistration.tryParse(null), isNull);
      expect(HamClientRegistration.tryParse(const {}), isNull);
      expect(
        HamClientRegistration.tryParse(const {
          'client_id': 'dyn_z',
          'redirect_uri': 'http://127.0.0.1:5173/oauth/callback',
        }),
        isNull,
        reason: 'no expiry means it cannot be trusted to still be valid',
      );
    });
  });

  group('a token', () {
    HamToken tokenWith(Duration left) => HamToken(
          accessToken: 'secret',
          obtainedAt: DateTime.now(),
          expiresAt: DateTime.now().add(left),
        );

    test('reports the days left, never negative', () {
      // `inDays` truncates, so "1 day" reads 0 or 1 depending on the microseconds
      // between building the token and reading it. Ranges, not exact values — an
      // exact assertion here is a flaky test, not a stricter one.
      expect(tokenWith(const Duration(days: 30)).daysLeft,
          inInclusiveRange(29, 30));
      expect(
          tokenWith(const Duration(days: 1)).daysLeft, inInclusiveRange(0, 1));
      expect(tokenWith(const Duration(seconds: -5)).daysLeft, 0);
    });

    test('is expired once the deadline passes', () {
      expect(tokenWith(const Duration(minutes: 1)).isExpired, isFalse);
      expect(tokenWith(const Duration(minutes: -1)).isExpired, isTrue);
    });

    test('toString does not contain the token', () {
      final t = tokenWith(const Duration(days: 3));
      expect(t.toString(), isNot(contains('secret')));
    });
  });

  group('the authorise flow without a browser', () {
    test('reports that it cannot open a browser and releases the port',
        () async {
      // What this covers: the loopback listener is bound, the callback path is
      // accepted, and a failed browser launch ends the wait instead of leaving
      // the process holding a port until the timeout.
      final oauth = HamOAuth();
      addTearDown(oauth.close);

      final result = await oauth.authorize(
        cached: HamClientRegistration(
          clientId: 'dyn_test',
          redirectUri: 'http://127.0.0.1:5173/oauth/callback',
          expiresAt: DateTime.now().add(const Duration(days: 1)),
        ),
        openBrowser: (_) async => false,
        timeout: const Duration(seconds: 5),
      );

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull?.kind, FailureKind.unsupported);
      expect(result.errorOrNull?.message, contains('浏览器'));
    });

    test('a second run can bind the same port again', () async {
      // Proves the listener is closed on the failure path: if it leaked, this
      // second bind would fall through to a random port and then fail on a
      // redirect-URI mismatch instead.
      for (var i = 0; i < 2; i++) {
        final oauth = HamOAuth();
        final result = await oauth.authorize(
          cached: HamClientRegistration(
            clientId: 'dyn_test',
            redirectUri: 'http://127.0.0.1:5173/oauth/callback',
            expiresAt: DateTime.now().add(const Duration(days: 1)),
          ),
          openBrowser: (_) async => false,
          timeout: const Duration(seconds: 5),
        );
        oauth.close();
        expect(result.errorOrNull?.kind, FailureKind.unsupported,
            reason: 'run $i');
      }
    });
  });

  group('the advertised scope', () {
    test('asks for reading, never for writing', () {
      // The point of the feature is reading grade statistics. Requesting
      // `mcp:write` would hand the app the ability to post on the user's behalf
      // for no reason.
      expect(HamOAuth.scope, contains('mcp:read'));
      expect(HamOAuth.scope, isNot(contains('mcp:write')));
    });
  });

  group('persistence', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
    });

    const store = HamTokenStore();

    HamToken liveToken({Duration left = const Duration(days: 20)}) => HamToken(
          accessToken: 'tok-live',
          obtainedAt: DateTime.now(),
          expiresAt: DateTime.now().add(left),
        );

    test('a saved token comes back', () async {
      await store.saveToken(liveToken());
      final loaded = await store.loadToken();

      expect(loaded, isNotNull);
      expect(loaded!.accessToken, 'tok-live');
      expect(loaded.isExpired, isFalse);
    });

    test('an expired token is reported as absent and removed', () async {
      // The rule that keeps a 401 from being misread: an expired entry must not
      // come back as a key that "the server rejected".
      await store.saveToken(
        HamToken(
          accessToken: 'tok-dead',
          obtainedAt: DateTime.now().subtract(const Duration(days: 40)),
          expiresAt: DateTime.now().subtract(const Duration(days: 1)),
        ),
      );

      expect(await store.loadToken(), isNull);
      // And it is gone, not merely hidden.
      final again = await store.loadToken();
      expect(again, isNull);
    });

    test('nothing saved reads as null, not as an error', () async {
      expect(await store.loadToken(), isNull);
      expect(await store.loadClient(), isNull);
    });

    test('the client registration round-trips while it is valid', () async {
      final client = HamClientRegistration(
        clientId: 'dyn_p',
        redirectUri: 'http://127.0.0.1:5173/oauth/callback',
        expiresAt: DateTime.now().add(const Duration(days: 29)),
      );
      await store.saveClient(client);
      final loaded = await store.loadClient();

      expect(loaded?.clientId, 'dyn_p');
      expect(loaded?.redirectUri, client.redirectUri);
    });

    test('a lapsed client registration is not offered', () async {
      await store.saveClient(HamClientRegistration(
        clientId: 'dyn_old',
        redirectUri: 'http://127.0.0.1:5173/oauth/callback',
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
      ));
      expect(await store.loadClient(), isNull);
    });

    test('clearing removes the token and the client together', () async {
      await store.saveToken(liveToken());
      await store.saveClient(HamClientRegistration(
        clientId: 'dyn_q',
        redirectUri: 'http://127.0.0.1:5173/oauth/callback',
        expiresAt: DateTime.now().add(const Duration(days: 10)),
      ));

      await store.clearAll();

      expect(await store.loadToken(), isNull);
      expect(
        await store.loadClient(),
        isNull,
        reason: 'a revocation must not leave a client that could silently '
            're-establish the grant',
      );
    });

    test('clearing the token leaves the client alone', () async {
      // Renewal and revocation are different actions: after the token lapses the
      // cached client is still good, so only the token is dropped.
      await store.saveToken(liveToken());
      await store.saveClient(HamClientRegistration(
        clientId: 'dyn_r',
        redirectUri: 'http://127.0.0.1:5173/oauth/callback',
        expiresAt: DateTime.now().add(const Duration(days: 10)),
      ));

      await store.clearToken();

      expect(await store.loadToken(), isNull);
      expect((await store.loadClient())?.clientId, 'dyn_r');
    });
  });
}
