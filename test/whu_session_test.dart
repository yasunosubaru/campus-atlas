import 'package:campus_atlas/features/whu_auth/cas_navigation.dart';
import 'package:campus_atlas/features/whu_auth/whu_endpoints.dart';
import 'package:campus_atlas/features/whu_auth/whu_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// The session object holds a single-sign-on credential, so most of these tests
/// are about what it must *not* do.
void main() {
  final t0 = DateTime.utc(2026, 10, 14, 12);

  CookieData cookie(
    String name,
    String value, {
    String domain = 'cas.whu.edu.cn',
    String path = '/authserver',
    bool hostOnly = true,
  }) =>
      (
        name: name,
        value: value,
        domain: domain,
        path: path,
        hostOnly: hostOnly,
      );

  /// The two cookies a CAS sign-in leaves on the central host.
  List<CookieData> casOnly() => [
        cookie(CasOrigin.tgcCookie, 'TGC-VALUE-abc123'),
        cookie(CasOrigin.sessionCookie, 'JSESSION-VALUE-xyz789'),
      ];

  WhuSession sessionOf(
    List<CookieData> scoped, {
    DateTime? at,
    Set<WhuProperty> properties = const {},
    List<String> handshake = const [],
  }) =>
      WhuSession(
        cookies: {for (final c in scoped) c.name: c.value},
        scoped: scoped,
        acquiredAt: at ?? t0,
        handshake: handshake,
        properties: properties,
      );

  WhuSession sessionAt(DateTime at, {Set<WhuProperty> properties = const {}}) =>
      sessionOf(casOnly(), at: at, properties: properties);

  group('construction', () {
    test('refuses an empty cookie jar', () {
      expect(
        () => WhuSession(cookies: const {}, scoped: const [], acquiredAt: t0),
        throwsArgumentError,
      );
    });

    test('reads the ticket-granting cookie', () {
      final s = sessionAt(t0);
      expect(s.hasTgc, isTrue);
      expect(s.tgc, 'TGC-VALUE-abc123');
    });

    test('a service-local session has no TGC and cannot be extended', () {
      final s = sessionOf([cookie(CasOrigin.sessionCookie, 'only-service')]);
      expect(s.hasTgc, isFalse);
      expect(s.tgc, isNull);
    });
  });

  group('freshness', () {
    test('is fresh just under the ttl', () {
      final s = sessionAt(t0);
      expect(
        s.isFresh(now: t0.add(const Duration(hours: 1, minutes: 59))),
        isTrue,
      );
    });

    test('is stale at the ttl', () {
      final s = sessionAt(t0);
      expect(s.isFresh(now: t0.add(const Duration(hours: 2))), isFalse);
      expect(s.isFresh(now: t0.add(const Duration(hours: 3))), isFalse);
    });

    test('honours a caller-supplied ttl', () {
      final s = sessionAt(t0);
      expect(
        s.isFresh(
            ttl: const Duration(minutes: 30),
            now: t0.add(const Duration(minutes: 20))),
        isTrue,
      );
      expect(
        s.isFresh(
            ttl: const Duration(minutes: 30),
            now: t0.add(const Duration(minutes: 40))),
        isFalse,
      );
    });

    test('reports age', () {
      expect(sessionAt(t0).age(now: t0.add(const Duration(minutes: 42))),
          const Duration(minutes: 42));
    });
  });

  group('the cookie header is scoped to the request', () {
    // These are the reason this group changed shape. The session used to hold a
    // map of name to value and emit all of it for every request, which sent the
    // central `CASTGC` to 教务 and let the two hosts' `JSESSIONID`s overwrite
    // each other.
    final cas = Uri.parse('https://cas.whu.edu.cn/authserver/anything');
    final jwgl = Uri.parse('https://jwgl.whu.edu.cn/xtgl/index_initMenu.html');

    test('a CAS-scoped grant is not sent to a service host', () {
      final s = sessionAt(t0);
      expect(s.cookieHeaderFor(cas), contains('CASTGC=TGC-VALUE-abc123'));
      expect(s.cookieHeaderFor(jwgl), isNot(contains('CASTGC')));
    });

    test('a host gets its own cookies, and only its own', () {
      final s = sessionOf([
        ...casOnly(),
        cookie('JSESSIONID', 'jwgl-session',
            domain: 'jwgl.whu.edu.cn', path: '/'),
      ]);

      expect(s.cookieHeaderFor(jwgl), 'JSESSIONID=jwgl-session');
      // The CAS one is a different cookie with the same name; it stays home.
      expect(
          s.cookieHeaderFor(cas), contains('JSESSIONID=JSESSION-VALUE-xyz789'));
      expect(s.cookieHeaderFor(cas), isNot(contains('jwgl-session')));
    });

    test('the same name on two hosts does not collapse into one', () {
      final s = sessionOf([
        cookie('JSESSIONID', 'cas-value'),
        cookie('JSESSIONID', 'jwgl-value',
            domain: 'jwgl.whu.edu.cn', path: '/'),
        cookie(CasOrigin.tgcCookie, 'TGC-VALUE-abc123'),
      ]);

      // Each host gets its own `JSESSIONID`. The CAS host also carries the grant,
      // which belongs to it alone.
      expect(s.cookieHeaderFor(jwgl), 'JSESSIONID=jwgl-value');
      expect(s.cookieHeaderFor(cas),
          'CASTGC=TGC-VALUE-abc123; JSESSIONID=cas-value');
    });

    test('a cookie scoped to one path is not sent to a sibling path', () {
      final s = sessionOf([
        cookie('JSESSIONID', 'v', path: '/authserver'),
        cookie(CasOrigin.tgcCookie, 'TGC-VALUE-abc123', path: '/authserver'),
      ]);

      expect(
          s.cookieHeaderFor(
              Uri.parse('https://cas.whu.edu.cn/authserver/login')),
          contains('JSESSIONID=v'));
      // `/authserverx` merely starts with the same characters.
      expect(
        s.cookieHeaderFor(Uri.parse('https://cas.whu.edu.cn/authserverx/x')),
        isEmpty,
      );
    });

    test('a host-only cookie does not cover a subdomain', () {
      final s = sessionOf([cookie('JSESSIONID', 'v', hostOnly: true)]);
      expect(s.cookieHeaderFor(Uri.parse('https://sso.cas.whu.edu.cn/x')),
          isEmpty);
    });

    test('a Domain= cookie does cover a subdomain', () {
      final s = sessionOf([
        cookie('route', 'node1',
            domain: 'whu.edu.cn', path: '/', hostOnly: false),
      ]);
      expect(s.cookieHeaderFor(Uri.parse('https://sso.cas.whu.edu.cn/x')),
          'route=node1');
    });

    test('is deterministic regardless of insertion order', () {
      final a = sessionOf([
        cookie('ZZZ', '3', path: '/'),
        cookie('AAA', '1', path: '/'),
        cookie('MMM', '2', path: '/'),
      ]);
      final b = sessionOf([
        cookie('MMM', '2', path: '/'),
        cookie('AAA', '1', path: '/'),
        cookie('ZZZ', '3', path: '/'),
      ]);
      final target = Uri.parse('https://cas.whu.edu.cn/');
      expect(a.cookieHeaderFor(target), 'AAA=1; MMM=2; ZZZ=3');
      expect(a.cookieHeaderFor(target), b.cookieHeaderFor(target));
    });

    test('a host nothing applies to yields an empty header, not a stale one',
        () {
      final s = sessionAt(t0);
      expect(s.cookieHeaderFor(Uri.parse('https://seat.lib.whu.edu.cn/')),
          isEmpty);
      expect(s.sendsAnythingTo(Uri.parse('https://seat.lib.whu.edu.cn/')),
          isFalse);
    });

    test('sendsAnythingTo agrees with the header it would build', () {
      final s = sessionAt(t0);
      for (final uri in [
        cas,
        jwgl,
        Uri.parse('https://seat.lib.whu.edu.cn/')
      ]) {
        expect(s.sendsAnythingTo(uri), s.cookieHeaderFor(uri).isNotEmpty);
      }
    });
  });

  group('immutability', () {
    test('withProperty does not mutate the original', () {
      final original = sessionAt(t0);
      final extended = original.withProperty(WhuProperty.jwgl);

      expect(original.properties, isEmpty);
      expect(extended.properties, {WhuProperty.jwgl});
      expect(extended.cookies, original.cookies);
      expect(extended.scoped, original.scoped);
    });

    test('withProperty accumulates', () {
      final s = sessionAt(t0)
          .withProperty(WhuProperty.jwgl)
          .withProperty(WhuProperty.teachingEvaluation);
      expect(s.properties, {WhuProperty.jwgl, WhuProperty.teachingEvaluation});
      expect(s.isAuthenticatedTo(WhuProperty.jwgl), isTrue);
      expect(s.isAuthenticatedTo(WhuProperty.librarySeat), isFalse);
    });

    test('the cookie map is unmodifiable', () {
      final s = sessionAt(t0);
      expect(() => s.cookies['EVIL'] = 'x', throwsUnsupportedError);
    });

    test('the hop log travels with the session', () {
      final s = sessionOf(casOnly(), handshake: const ['GET x → 200']);
      expect(s.handshake, ['GET x → 200']);
      expect(s.withProperty(WhuProperty.jwgl).handshake, s.handshake);
    });
  });

  group('merge', () {
    test('incoming values win, per host', () {
      final s = sessionOf([
        ...casOnly(),
        cookie('JSESSIONID', 'stale', domain: 'jwgl.whu.edu.cn', path: '/'),
      ]).merge([
        cookie('JSESSIONID', 'fresh', domain: 'jwgl.whu.edu.cn', path: '/'),
      ]);

      expect(s.cookieHeaderFor(Uri.parse('https://jwgl.whu.edu.cn/x')),
          'JSESSIONID=fresh');
      // The CAS-scoped pair is untouched. Asserted through the header rather than
      // the flat map, because the flat map is precisely what cannot tell these
      // two cookies apart — it holds one `JSESSIONID` and keeps whichever came
      // last, which is the defect this whole change removes.
      expect(
        s.cookieHeaderFor(Uri.parse('https://cas.whu.edu.cn/authserver/x')),
        'CASTGC=TGC-VALUE-abc123; JSESSIONID=JSESSION-VALUE-xyz789',
      );
    });

    test('a refresh of one host does not disturb another host', () {
      // The key is domain|path|name, so a same-named cookie elsewhere survives.
      final s = sessionOf([
        cookie('JSESSIONID', 'cas-value'),
        cookie('JSESSIONID', 'jwgl-value',
            domain: 'jwgl.whu.edu.cn', path: '/'),
      ]).merge([
        cookie('JSESSIONID', 'jwgl-new', domain: 'jwgl.whu.edu.cn', path: '/')
      ]);

      expect(
          s.cookieHeaderFor(Uri.parse('https://cas.whu.edu.cn/authserver/x')),
          'JSESSIONID=cas-value');
      expect(s.cookieHeaderFor(Uri.parse('https://jwgl.whu.edu.cn/x')),
          'JSESSIONID=jwgl-new');
    });

    test('merging nothing returns the same instance', () {
      final s = sessionAt(t0);
      expect(identical(s.merge(const []), s), isTrue);
    });

    test('a refresh re-stamps the age and keeps redeemed properties', () {
      final s = sessionAt(t0).withProperty(WhuProperty.jwgl);
      final later = t0.add(const Duration(minutes: 5));
      final merged = s.merge([cookie('NEW', 'n', path: '/')], now: later);

      expect(merged.acquiredAt, later);
      expect(merged.acquiredAt.isAfter(s.acquiredAt), isTrue);
      expect(merged.age(now: later), Duration.zero);
      expect(merged.properties, {WhuProperty.jwgl});
    });

    test('a refresh does not move the clock backwards', () {
      // An out-of-order now must not produce a session that claims to be younger
      // than it is.
      final s = sessionAt(t0);
      final merged = s.merge([cookie('NEW', 'n', path: '/')],
          now: t0.subtract(const Duration(hours: 1)));
      expect(merged.acquiredAt.isBefore(t0), isTrue);
    });
  });

  group('secret hygiene', () {
    test('toString never leaks a cookie value', () {
      final s = sessionAt(t0);
      final text = s.toString();
      expect(text, contains('CASTGC')); // the name is fine
      expect(text, isNot(contains('TGC-VALUE-abc123')));
      expect(text, isNot(contains('JSESSION-VALUE-xyz789')));
    });

    test('cookieNames exposes names only', () {
      expect(
        sessionAt(t0).cookieNames,
        {CasOrigin.tgcCookie, CasOrigin.sessionCookie},
      );
    });
  });

  group('WhuTerm', () {
    test('carries the codes the grade page selector uses', () {
      expect(WhuTerm.first.code, '3');
      expect(WhuTerm.second.code, '12');
      expect(WhuTerm.third.code, '16');
      expect(WhuTerm.fromCode('12'), WhuTerm.second);
      expect(WhuTerm.fromCode('nope'), isNull);
    });

    test('carries the labels that selector shows, not inferred seasons', () {
      // Read off the live `xqm` selector as `value:label` pairs. An earlier
      // version labelled these 秋季/冬季/夏季, which was an assumption and made the
      // app's term picker say something the university never says.
      expect(WhuTerm.first.label, '第1学期');
      expect(WhuTerm.second.label, '第2学期');
      expect(WhuTerm.third.label, '第3学期');
    });

    test('order is academic order, not lexical', () {
      final codes = WhuTerm.values.map((t) => t.code).toList();
      final lexical = [...codes]..sort();
      expect(codes, isNot(lexical),
          reason: 'lexical sort would give 12,16,3 and misorder the terms');
      expect(WhuTerm.values.map((t) => t.order), [0, 1, 2]);
    });
  });

  group('WhuProperty', () {
    test('maps to the right hosts', () {
      expect(WhuProperty.jwgl.host, 'jwgl.whu.edu.cn');
      expect(WhuProperty.teachingEvaluation.host, 'ugsqs.whu.edu.cn');
      expect(WhuProperty.librarySeat.host, 'seat.lib.whu.edu.cn');
    });
  });
}
