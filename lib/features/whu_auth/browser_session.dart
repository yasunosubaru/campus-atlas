/// Turning a browser sign-in into the app's own session.
///
/// ## The problem this solves
///
/// The app had two sessions that could not see each other. Its own CAS client
/// held a cookie jar in memory; the browser hosted by the Windows runner held a
/// separate one. Only the browser's could get past the anti-bot puzzle the 教务
/// grade query sits behind, so a person who had just signed in there still found
/// the app's other features locked — and signing in again at the app's own
/// prompt did not help, because the puzzle would not be presented there at all.
///
/// Harvesting the browser's cookies and building the session from them collapses
/// that to **one sign-in**: the person signs in in the browser, and everything
/// that does not itself need the puzzle runs off the same cookies.
///
/// ## Why the session is built by the same rules
///
/// Because it is the same object. A session assembled any more loosely would
/// differ from one the HTTP client produced in ways that only show up later, as
/// a request that looks authenticated and is refused. [scopeCookies] and
/// [requireGrant] are therefore reused rather than re-implemented.
library;

import '../../core/result.dart';
import '../grades_query/jwgl/native_webview.dart' show BrowserCookie;
import 'cas_navigation.dart'
    show CookieData, filterCookies, requireGrant, scopeCookies;
import 'whu_endpoints.dart';
import 'whu_session.dart';

/// The URLs a harvest has to ask for, to see every cookie involved.
///
/// **One is not enough.** WebView2 matches cookies on the path as well as the
/// host: the CAS grant lives at `/authserver` and a property's session at `/`, so
/// a harvest that asked only for the property would come back without the grant
/// and report a good sign-in as unticketable. This project has already shipped
/// that bug once — see [CasOrigin.authserverRoot].
List<String> browserHarvestUrls(WhuProperty property) => [
      'https://${property.host}/',
      CasOrigin.authserverRoot,
    ];

/// Builds the app's session out of cookies harvested from the browser.
///
/// Returns a failure rather than a half-session when the grant is missing: a
/// service-local jar can talk to one host and cannot be extended, so treating it
/// as a sign-in would show a working screen now and a refusal later.
Result<WhuSession> sessionFromBrowserCookies(
  Iterable<BrowserCookie> cookies, {
  WhuProperty property = WhuProperty.jwgl,
  DateTime? now,
}) {
  final records = <CookieData>[
    for (final c in cookies)
      if (c.name.trim().isNotEmpty && c.value.trim().isNotEmpty)
        (
          name: c.name,
          value: c.value,
          domain: c.domain,
          path: c.path.isEmpty ? '/' : c.path,
          // WebView2's cookie interface does not expose the host-only flag, so
          // every cookie is treated as a domain cookie. That is the tolerant
          // direction: it may cover a subdomain it should not, which costs
          // nothing here, while the other choice would drop a cookie the
          // sign-in depends on.
          hostOnly: false,
        ),
  ];

  final grant = requireGrant(filterCookies(records, property), property);
  if (grant.isFailure) {
    return Failure<WhuSession>(grant.errorOrNull!);
  }

  final scoped = scopeCookies(records, property);
  return Success(WhuSession(
    cookies: grant.requireValue,
    scoped: scoped,
    acquiredAt: now ?? DateTime.now(),
    // How the session was obtained, with no secret in it.
    handshake: [
      'browser sign-in: ${cookies.length} cookies harvested, '
          '${scoped.length} kept for ${property.host}',
    ],
    properties: {property},
  ));
}
