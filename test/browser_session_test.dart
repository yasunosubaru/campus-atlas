import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/features/grades_query/jwgl/native_webview.dart'
    show BrowserCookie;
import 'package:campus_atlas/features/whu_auth/browser_session.dart';
import 'package:campus_atlas/features/whu_auth/whu_endpoints.dart';
import 'package:campus_atlas/features/whu_auth/whu_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// The cookies below are the shape a real sign-in leaves behind: the grant on
/// the CAS host at `/authserver`, and the service's own session on the property.
/// Nothing here is a value anyone could use — the real ones are never written
/// into a test.
List<BrowserCookie> signedIn(
        {bool withGrant = true, bool withSibling = false}) =>
    [
      if (withGrant)
        const BrowserCookie(
          name: 'CASTGC',
          value: 'TGT-1-abc',
          domain: 'cas.whu.edu.cn',
          path: '/authserver',
        ),
      const BrowserCookie(
        name: 'JSESSIONID',
        value: 'jwgl-session',
        domain: 'jwgl.whu.edu.cn',
        path: '/',
      ),
      const BrowserCookie(
        name: '_dx_uzZo5y',
        value: 'dx-value',
        domain: 'jwgl.whu.edu.cn',
        path: '/',
      ),
      if (withSibling)
        const BrowserCookie(
          name: 'JSESSIONID',
          value: 'library-seat-session',
          domain: 'seat.lib.whu.edu.cn',
          path: '/',
        ),
    ];

void main() {
  group('harvesting the browser session', () {
    test('a signed-in browser becomes the app session', () {
      final result = sessionFromBrowserCookies(signedIn());
      final session = result.dataOrNull;

      expect(session, isNotNull);
      expect(session!.hasTgc, isTrue);
      expect(session.tgc, 'TGT-1-abc');
      expect(session.isAuthenticatedTo(WhuProperty.jwgl), isTrue);
    });

    test('the grant is kept, but never sent to the service host', () {
      // This is the defect the scoped list exists to prevent: flattening by name
      // lets the CAS grant ride along to a property, which no service has any
      // business receiving.
      final session = sessionFromBrowserCookies(signedIn()).requireValue;

      final toJwgl = session.cookieHeaderFor(
        Uri.parse('${JwglOrigin.root}/cjcx/cjcx_cxDgXscj.html'),
      );
      expect(toJwgl, contains('JSESSIONID=jwgl-session'));
      expect(toJwgl, isNot(contains('CASTGC')));

      final toCas = session.cookieHeaderFor(
        Uri.parse(CasOrigin.authserverRoot),
      );
      expect(toCas, contains('CASTGC=TGT-1-abc'));
    });

    test('siblings are dropped rather than carried along', () {
      final session =
          sessionFromBrowserCookies(signedIn(withSibling: true)).requireValue;

      final hosts = session.scoped.map((c) => c.domain).toSet();
      expect(hosts, isNot(contains('seat.lib.whu.edu.cn')));
      expect(hosts, contains('jwgl.whu.edu.cn'));
    });

    test('a jar with no grant is refused, not half-accepted', () {
      // A service-local session can talk to one host and cannot be extended, so
      // accepting it would show a working screen now and a refusal later.
      final result = sessionFromBrowserCookies(signedIn(withGrant: false));

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull!.kind, FailureKind.unauthorized);
      // The message has to name the missing cookie, because that is the
      // difference between "sign in first" and "something is wrong".
      expect(result.errorOrNull!.message, contains('CASTGC'));
    });

    test('nothing harvested is a validation failure', () {
      final result = sessionFromBrowserCookies(const <BrowserCookie>[]);

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull!.kind, FailureKind.validation);
    });

    test('cookies without a value are ignored rather than kept as blanks', () {
      final result = sessionFromBrowserCookies([
        ...signedIn(),
        const BrowserCookie(
            name: 'route', value: '   ', domain: 'jwgl.whu.edu.cn', path: '/'),
      ]);

      final session = result.requireValue;
      expect(session.scoped.every((c) => c.value.trim().isNotEmpty), isTrue);
    });

    test('an empty path is treated as the root', () {
      // WebView2 can report a cookie with no path; `/` is what that means, and
      // an empty string would match nothing at all.
      final session = sessionFromBrowserCookies(
        signedIn().map((c) => BrowserCookie(
              name: c.name,
              value: c.value,
              domain: c.domain,
              path: '',
            )),
      ).requireValue;

      expect(session.cookieHeaderFor(Uri.parse('${JwglOrigin.root}/x')),
          contains('JSESSIONID=jwgl-session'));
    });

    test('the handshake records where the session came from, without secrets',
        () {
      final session = sessionFromBrowserCookies(signedIn()).requireValue;

      expect(session.handshake.single, contains('browser sign-in'));
      for (final line in session.handshake) {
        expect(line, isNot(contains('TGT-1-abc')));
        expect(line, isNot(contains('jwgl-session')));
      }
    });

    test('the harvest asks for both origins', () {
      // The regression this pins: asking only for the property's host returns no
      // CASTGC, because the grant is scoped to `/authserver` on the CAS host, and
      // a perfectly good sign-in then looks unticketable.
      final urls = browserHarvestUrls(WhuProperty.jwgl);

      expect(urls, contains('https://jwgl.whu.edu.cn/'));
      expect(urls, contains(CasOrigin.authserverRoot));
      expect(urls.length, 2);
    });
  });
}
