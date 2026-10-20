import 'package:campus_atlas/features/whu_auth/cas_cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';

/// The jar decides whether a sign-in that *succeeded* is reported as one. The
/// bug this file exists to prevent was exactly that: `CASTGC` is scoped to
/// `path=/authserver`, a lookup at path `/` missed it, and a perfectly good
/// sign-in came back as "you are not signed in". Every assertion below is about
/// scoping, not about storage.
void main() {
  Uri cas(String path) => Uri.parse('https://cas.whu.edu.cn$path');
  Uri jwgl(String path) => Uri.parse('https://jwgl.whu.edu.cn$path');

  group('domain scoping', () {
    test('a cookie with no Domain covers exactly the host that set it', () {
      final jar = CasCookieJar()
        ..absorb(
            cas('/authserver/login'), ['JSESSIONID=abc; Path=/authserver']);

      expect(
          jar.headerFor(cas('/authserver/login')), contains('JSESSIONID=abc'));
      expect(jar.headerFor(cas('/authserver/x')), contains('JSESSIONID=abc'));
      // Host-only: a subdomain is a *different* host and must not receive it.
      expect(
          jar.headerFor(Uri.parse('https://sso.cas.whu.edu.cn/authserver/x')),
          isNull);
      expect(jar.headerFor(jwgl('/sso/jznewsixlogin')), isNull);
    });

    test('a Domain attribute covers subdomains as well', () {
      final jar = CasCookieJar()
        ..absorb(
          cas('/authserver/login'),
          ['route=node1; Domain=whu.edu.cn; Path=/'],
        );

      expect(jar.headerFor(cas('/authserver/login')), contains('route=node1'));
      expect(
        jar.headerFor(Uri.parse('https://jwgl.whu.edu.cn/sso/login')),
        contains('route=node1'),
      );
      expect(jar.headerFor(Uri.parse('https://notwhu.edu.cn/')), isNull);
    });

    test('a leading dot on Domain is stripped and treated the same', () {
      final jar = CasCookieJar()
        ..absorb(cas('/authserver/login'), ['a=1; Domain=.whu.edu.cn; Path=/']);

      expect(jar.headerFor(jwgl('/x')), contains('a=1'));
    });

    test('a Domain that does not cover the setter is refused', () {
      // Otherwise a response could plant a cookie on somebody else's site.
      final jar = CasCookieJar()
        ..absorb(
            cas('/authserver/login'), ['evil=1; Domain=example.com; Path=/']);

      expect(jar.length, 0);
      expect(jar.headerFor(Uri.parse('https://example.com/')), isNull);
    });
  });

  group('path scoping', () {
    test('/authserver covers /authserver/login but not /authserverx', () {
      final jar = CasCookieJar()
        ..absorb(cas('/authserver/login'), ['CASTGC=ST-123; Path=/authserver']);

      expect(
          jar.headerFor(cas('/authserver/login')), contains('CASTGC=ST-123'));
      expect(jar.headerFor(cas('/authserver')), contains('CASTGC=ST-123'));
      // The boundary rule. Without it a sibling context path whose name merely
      // starts the same way would inherit the grant.
      expect(jar.headerFor(cas('/authserverx/thing')), isNull);
    });

    test('a trailing slash on the cookie path behaves the same', () {
      // The server's clearing header spells the path `/authserver/`, the real
      // grant spells it `/authserver`. Both must cover the same requests.
      final jar = CasCookieJar()
        ..absorb(cas('/authserver/login'), ['CASTGC=ST-1; Path=/authserver/']);

      expect(jar.headerFor(cas('/authserver/login')), contains('CASTGC=ST-1'));
    });

    test('/ covers everything on the host', () {
      final jar = CasCookieJar()
        ..absorb(cas('/authserver/login'), ['route=n; Path=/']);

      expect(jar.headerFor(cas('/')), contains('route=n'));
      expect(jar.headerFor(cas('/authserver/login')), contains('route=n'));
    });

    test('a missing Path defaults to the request path directory', () {
      final jar = CasCookieJar()
        ..absorb(cas('/authserver/login'), ['JSESSIONID=x']);

      // RFC 6265 §5.1.4: everything up to, but not including, the last '/'.
      expect(jar.headerFor(cas('/authserver/login')), contains('JSESSIONID=x'));
      expect(jar.headerFor(cas('/authserver/other')), contains('JSESSIONID=x'));
      // One level up is *outside* `/authserver`.
      expect(jar.headerFor(cas('/')), isNull);
    });
  });

  group('replacement and removal', () {
    test('a repeated cookie at the same path replaces rather than accumulating',
        () {
      final jar = CasCookieJar()
        ..absorb(
            cas('/authserver/login'), ['JSESSIONID=first; Path=/authserver'])
        ..absorb(
            cas('/authserver/login'), ['JSESSIONID=second; Path=/authserver']);

      expect(jar.length, 1);
      expect(jar.headerFor(cas('/authserver/login')), 'JSESSIONID=second');
    });

    test('the same name at a different path stays distinct', () {
      // The server really does use both `/` and `/authserver/`, so collapsing
      // by name alone would lose one of them.
      final jar = CasCookieJar()
        ..absorb(cas('/authserver/login'), ['JSESSIONID=root; Path=/'])
        ..absorb(
            cas('/authserver/login'), ['JSESSIONID=ctx; Path=/authserver']);

      expect(jar.length, 2);
      final header = jar.headerFor(cas('/authserver/login'))!;
      expect(header, contains('JSESSIONID=ctx'));
      expect(header, contains('JSESSIONID=root'));
    });

    test('Max-Age=0 removes a cookie', () {
      final jar = CasCookieJar()
        ..absorb(cas('/authserver/login'), ['CASTGC=real; Path=/authserver'])
        ..absorb(
            cas('/authserver/login'), ['CASTGC=; Max-Age=0; Path=/authserver']);

      expect(jar.length, 0);
      expect(jar.headerFor(cas('/authserver/login')), isNull);
    });

    test('an empty quoted value with an expiry in the past removes a cookie',
        () {
      // This is the shape the server actually sends on an unauthenticated page:
      // an `Expires` attribute whose value contains a comma. Splitting the
      // Set-Cookie header on commas — which is the obvious way to handle a list
      // of headers — mangles the date and leaves a stale cookie behind.
      final jar = CasCookieJar()
        ..absorb(cas('/authserver/login'), ['CASTGC=real; Path=/authserver'])
        ..absorb(cas('/authserver/login'), [
          'CASTGC=""; Expires=Thu, 01 Jan 1970 00:00:10 GMT; Path=/authserver',
        ]);

      expect(jar.length, 0);
    });

    test('an expiry in the future is kept', () {
      final jar = CasCookieJar()
        ..absorb(cas('/authserver/login'), [
          'CASTGC=real; Expires=Fri, 31 Dec 2100 23:59:59 GMT; Path=/authserver',
        ]);

      expect(jar.length, 1);
    });

    test('an unparseable expiry keeps the cookie rather than dropping it', () {
      // Failing open is right here: the alternative is losing a live session
      // because the server formatted a date in a way this build has not seen.
      final jar = CasCookieJar()
        ..absorb(cas('/authserver/login'), [
          'CASTGC=real; Expires=whenever; Path=/authserver',
        ]);

      expect(jar.length, 1);
    });
  });

  group('request headers', () {
    test('a quoted value keeps its contents verbatim', () {
      final jar = CasCookieJar()
        ..absorb(cas('/authserver/login'), ['CASTGC="ST-1-abc"; Path=/']);

      expect(jar.headerFor(cas('/x')), 'CASTGC=ST-1-abc');
    });

    test('longer paths are presented first', () {
      final jar = CasCookieJar()
        ..absorb(cas('/authserver/login'), ['a=root; Path=/'])
        ..absorb(cas('/authserver/login'), ['b=ctx; Path=/authserver']);

      expect(jar.headerFor(cas('/authserver/login')), 'b=ctx; a=root');
    });

    test('no applicable cookie yields null, not an empty header', () {
      final jar = CasCookieJar();
      expect(jar.headerFor(cas('/authserver/login')), isNull);
    });

    test('all carries the scope, which is what keeps two hosts distinct', () {
      final jar = CasCookieJar()
        ..absorb(cas('/authserver/login'), ['CASTGC=ST-1; Path=/authserver']);

      // Path and host-only are part of the record deliberately. Without them a
      // `JSESSIONID` from the CAS host and one from 教务 are indistinguishable,
      // and anything keyed by name alone silently replaces one with the other.
      expect(jar.all, [
        (
          name: 'CASTGC',
          value: 'ST-1',
          domain: 'cas.whu.edu.cn',
          path: '/authserver',
          hostOnly: true,
        ),
      ]);
    });

    test('names lists diagnostics without any value', () {
      final jar = CasCookieJar()
        ..absorb(cas('/authserver/login'), ['CASTGC=SECRET; Path=/authserver']);

      // Values are single-sign-on material. Only names may reach a log.
      expect(jar.names, ['CASTGC']);
      expect(jar.names.join(), isNot(contains('SECRET')));
    });
  });

  group('unusable headers', () {
    test('a header with no name is ignored', () {
      final jar = CasCookieJar()
        ..absorb(cas('/authserver/login'), ['=value; Path=/', 'nonsense']);

      expect(jar.length, 0);
    });
  });
}
