import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/features/whu_auth/cas_navigation.dart';
import 'package:campus_atlas/features/whu_auth/whu_endpoints.dart';
import 'package:campus_atlas/features/whu_auth/whu_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the pure core of an interactive sign-in. None of these touch a
/// WebView or the network, which is why the decisions live out here at all.
void main() {
  CookieData cookie(
    String name,
    String value,
    String domain, {
    String path = '/',
    bool hostOnly = false,
  }) =>
      (
        name: name,
        value: value,
        domain: domain,
        path: path,
        hostOnly: hostOnly,
      );

  group('CasNavigationIntent.classify', () {
    test('still on the CAS sign-in form', () {
      final i = CasNavigationIntent.classify(
        'https://cas.whu.edu.cn/authserver/login?service=https%3A%2F%2Fjwgl.whu.edu.cn',
      );
      expect(i.hop, CasHop.cas);
      expect(i.isComplete, isFalse);
      expect(i.isKnownProperty, isFalse);
    });

    test('reaching a property completes sign-in', () {
      for (final url in [
        'https://jwgl.whu.edu.cn/sso/jznewsixlogin?ticket=ST-123456',
        'https://ugsqs.whu.edu.cn/caslogin/',
        'https://seat.lib.whu.edu.cn/seat',
      ]) {
        final i = CasNavigationIntent.classify(url);
        expect(i.hop, CasHop.property, reason: url);
        expect(i.isComplete, isTrue, reason: url);
        expect(i.isKnownProperty, isTrue, reason: url);
      }
    });

    test('challenge paths are recognised', () {
      final paths = [
        'https://cas.whu.edu.cn/authserver/common/openSliderCaptcha.htl',
        'https://cas.whu.edu.cn/authserver/common/verifySliderCaptcha.htl',
        'https://cas.whu.edu.cn/authserver/checkNeedCaptcha.htl',
        'https://cas.whu.edu.cn/authserver/captcha',
        'https://cas.whu.edu.cn/authserver/dynamicCode/getDynamicCode.htl',
      ];
      for (final p in paths) {
        final i = CasNavigationIntent.classify(p);
        expect(i.hop, CasHop.challenge, reason: p);
        expect(i.challengeNavigated, isTrue, reason: p);
      }
    });

    test('challenge detection is case-insensitive', () {
      expect(
        CasNavigationIntent.classify(
          'https://cas.whu.edu.cn/authserver/OpenSliderCaptcha.HTL',
        ).hop,
        CasHop.challenge,
      );
    });

    test('an unrelated host is unknown, not a failure', () {
      final i = CasNavigationIntent.classify('https://example.com/x');
      expect(i.hop, CasHop.unknown);
      expect(i.isComplete, isFalse);
      expect(i.isKnownProperty, isFalse);
    });

    test('an unparsable URL does not throw', () {
      final i = CasNavigationIntent.classify('::::not a url');
      expect(i.hop, CasHop.unknown);
      expect(i.host, '');
    });

    test('an empty URL does not throw', () {
      expect(CasNavigationIntent.classify('').hop, CasHop.unknown);
    });
  });

  group('parseChallengeState', () {
    test('reads the live response shape', () {
      expect(parseChallengeState('{"isNeed":false}'),
          CasChallengeState.notRequired);
      expect(
          parseChallengeState('{"isNeed":true}'), CasChallengeState.required);
    });

    test('tolerates whitespace inside the JSON', () {
      expect(parseChallengeState('{"isNeed": false}'),
          CasChallengeState.notRequired);
      expect(parseChallengeState('  {"isNeed": true}\n'),
          CasChallengeState.required);
    });

    test('an unreadable body is unknown, never "not required"', () {
      // Reporting unknown as "not required" would let a sign-in flow proceed
      // and then surprise the person with a challenge they were not warned
      // about, so the failure direction has to be toward caution.
      expect(parseChallengeState(''), CasChallengeState.unknown);
      expect(
          parseChallengeState('<html>error</html>'), CasChallengeState.unknown);
      expect(parseChallengeState('{}'), CasChallengeState.unknown);
    });
  });

  group('casLoginUrlFor', () {
    test('builds an encoded service URL for 教务', () {
      final r = casLoginUrlFor(WhuProperty.jwgl);
      expect(r.isSuccess, isTrue);
      final url = r.requireValue;

      expect(url.startsWith(CasOrigin.login), isTrue);
      final service =
          Uri.decodeComponent(url.substring(CasOrigin.login.length));
      expect(service, JwglOrigin.casService);
      expect(service, 'https://jwgl.whu.edu.cn/sso/jznewsixlogin');
    });

    test('the service is fully percent-encoded, then decodes back exactly', () {
      // `jwgl`'s service is path-only, so the round-trip assertion is that the
      // scheme separator is encoded and the decoded value is byte-identical.
      final url = casLoginUrlFor(WhuProperty.jwgl).requireValue;
      final raw = url.substring(CasOrigin.login.length);

      expect(raw, isNot(contains('://')),
          reason: 'the service must be encoded');
      expect(raw, isNot(contains('/')));
      expect(Uri.decodeComponent(raw), JwglOrigin.casService);
    });

    test('a service carrying its own query survives encodeComponent', () {
      // The hard case: a service URL containing `?`, `&` and `=` of its own.
      // Encoding with Uri.encodeQueryComponent instead of encodeComponent here
      // would mangle the target and CAS would reject it as not a service URL.
      // The withheld library target exercises this because it is the one
      // constant we have that carries a query.
      final service = LibrarySeatOrigin.casService;
      expect(service, contains('?redirectUrl='));

      final encoded = Uri.encodeComponent(service);
      expect(encoded, isNot(contains('?')));
      expect(encoded, isNot(contains('=')));
      expect(encoded, isNot(contains('/')));
      expect(Uri.decodeComponent(encoded), service);
    });

    test('a library seat target is withheld rather than guessed', () {
      expect(WhuProperty.librarySeat.casServiceUrl, isNull);
      final r = casLoginUrlFor(WhuProperty.librarySeat);
      expect(r.isFailure, isTrue);
      expect(r.errorOrNull?.kind, FailureKind.validation);
      expect(r.errorOrNull?.message, contains('refusing to guess'));
    });

    test('every targetable property yields a URL', () {
      for (final p in WhuProperty.targetable) {
        expect(casLoginUrlFor(p).isSuccess, isTrue, reason: p.name);
      }
      expect(WhuProperty.targetable, isNot(contains(WhuProperty.librarySeat)));
    });
  });

  group('the grant cookie\'s scope', () {
    // The regression these guard: `CASTGC` is scoped to the CAS context path,
    // so anything that looks the grant up by host alone comes back empty and the
    // sign-in reports "no ticket" while holding a valid one.
    //
    // The *matching* behaviour now lives in `CasCookieJar` and is tested there
    // (`test/cas_cookie_jar_test.dart`, "path scoping"). What is asserted here
    // is only the constant the server itself stated, so a change to it is
    // visible in one place.
    test('the CAS root carries the /authserver/ context path', () {
      final uri = Uri.parse(CasOrigin.authserverRoot);

      expect(uri.host, 'cas.whu.edu.cn');
      expect(uri.path, '/authserver/');
      expect(uri.path, isNot('/'),
          reason: 'a cookie scoped to /authserver does not match path "/"');
    });

    test('the sign-in form and the grant are both under that path', () {
      // `path=/authserver/` is what the server sends in Set-Cookie for CASTGC,
      // and the form posts to `/authserver/login`, which sits under it.
      expect(Uri.parse(CasOrigin.loginPost).path, '/authserver/login');
      expect(CasOrigin.login.startsWith(CasOrigin.authserverRoot), isTrue);
    });
  });

  group('filterCookies', () {
    final target = WhuProperty.jwgl;

    test('keeps the CAS grant alongside the property session', () {
      // The regression this guards: filtering on the property host alone drops
      // CASTGC, and the jar then looks fine while being unable to extend.
      final out = filterCookies(
        [
          cookie(CasOrigin.tgcCookie, 'TGC-SECRET', 'cas.whu.edu.cn'),
          cookie(CasOrigin.sessionCookie, 'SVC-SECRET', 'jwgl.whu.edu.cn'),
        ],
        target,
      );
      expect(out[CasOrigin.tgcCookie], 'TGC-SECRET');
      expect(out[CasOrigin.sessionCookie], 'SVC-SECRET');
      expect(out, hasLength(2));
    });

    test('keeps a parent-domain cookie', () {
      final out = filterCookies(
        [cookie('scoped', 'v', 'whu.edu.cn')],
        target,
      );
      expect(out['scoped'], 'v');
    });

    test('keeps a leading-dot domain', () {
      final out = filterCookies(
        [cookie('dot', 'v', '.jwgl.whu.edu.cn')],
        target,
      );
      expect(out['dot'], 'v');
    });

    test('drops a sibling property cookie', () {
      final out = filterCookies(
        [cookie('seat', 'v', 'seat.lib.whu.edu.cn')],
        target,
      );
      expect(out, isEmpty,
          reason: 'a seat cookie has no business riding a 教务 session');
    });

    test('drops an unrelated domain', () {
      final out = filterCookies(
        [cookie('evil', 'v', 'attacker.example')],
        target,
      );
      expect(out, isEmpty);
    });

    test('drops empty names and values', () {
      final out = filterCookies(
        [
          cookie('  ', 'v', 'jwgl.whu.edu.cn'),
          cookie('x', '   ', 'jwgl.whu.edu.cn'),
        ],
        target,
      );
      expect(out, isEmpty);
    });

    test('a later duplicate of the same name wins', () {
      final out = filterCookies(
        [
          cookie('k', 'old', 'jwgl.whu.edu.cn'),
          cookie('k', 'new', 'jwgl.whu.edu.cn'),
        ],
        target,
      );
      expect(out['k'], 'new');
    });

    test('filters correctly for the teaching-evaluation target', () {
      final out = filterCookies(
        [
          cookie(CasOrigin.tgcCookie, 'TGC', 'cas.whu.edu.cn'),
          cookie('sess', 'A', 'ugsqs.whu.edu.cn'),
          cookie('sess', 'B', 'jwgl.whu.edu.cn'),
        ],
        WhuProperty.teachingEvaluation,
      );
      expect(out[CasOrigin.tgcCookie], 'TGC');
      expect(out['sess'], 'A');
      expect(out, hasLength(2));
    });

    test('an empty jar yields an empty map', () {
      expect(filterCookies(const [], target), isEmpty);
    });
  });

  group('requireGrant', () {
    test('rejects an empty jar', () {
      final r = requireGrant(const {}, WhuProperty.jwgl);
      expect(r.isFailure, isTrue);
      expect(r.errorOrNull?.kind, FailureKind.validation);
    });

    test('rejects a service-only session', () {
      // Usable on the property it came from, but it cannot be extended — say
      // so instead of letting a later flow fail with a bare 401.
      final r = requireGrant(
        const {CasOrigin.sessionCookie: 'service-only'},
        WhuProperty.jwgl,
      );
      expect(r.isFailure, isTrue);
      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
      expect(r.errorOrNull?.message, contains('no CASTGC'));
    });

    test('accepts a jar carrying the grant', () {
      final r = requireGrant(
        const {
          CasOrigin.tgcCookie: 'TGC',
          CasOrigin.sessionCookie: 'SVC',
        },
        WhuProperty.jwgl,
      );
      expect(r.isSuccess, isTrue);
      expect(r.requireValue[CasOrigin.sessionCookie], 'SVC');
    });

    test('a blank grant value counts as missing', () {
      final r = requireGrant(
        const {CasOrigin.tgcCookie: '   '},
        WhuProperty.jwgl,
      );
      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
    });

    test('error text never contains a cookie value', () {
      // The whole point of failures being typed rather than thrown is that the
      // UI can show them. A jar full of base64 must not leak into one.
      const secret = 'TGC-super-secret-base64-blob';
      for (final result in [
        requireGrant(const {}, WhuProperty.jwgl),
        requireGrant(
          const {CasOrigin.sessionCookie: secret},
          WhuProperty.jwgl,
        ),
        requireGrant(const {CasOrigin.tgcCookie: '   '}, WhuProperty.jwgl),
      ]) {
        final text =
            '${result.errorOrNull?.message} ${result.errorOrNull?.displayLabel}';
        expect(text, isNot(contains(secret)));
        expect(text, isNot(contains('TGC-super-secret')));
      }
    });
  });
}
