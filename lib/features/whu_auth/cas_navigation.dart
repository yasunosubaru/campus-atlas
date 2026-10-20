/// Pure, platform-independent logic for an interactive CAS sign-in.
///
/// Everything here is a function of its inputs, deliberately: the WebView half
/// of this feature cannot be exercised in a test environment, so the decisions
/// that matter — which hop we are on, what URL to load, which cookies to keep —
/// are lifted out of the widget and tested directly.
library;

import '../../core/result.dart';
import 'whu_endpoints.dart';
import 'whu_session.dart';

/// What the URL under navigation tells us about progress.
enum CasHop {
  /// Still on the CAS host (the sign-in form itself).
  cas,

  /// Navigated to something this project recognises as a CAPTCHA page.
  challenge,

  /// Landed on a university property with a granted ticket — sign-in is done.
  property,

  /// Some other host entirely; neither progress nor necessarily a problem.
  unknown,
}

/// A classified navigation URL.
class CasNavigationIntent {
  const CasNavigationIntent({
    required this.hop,
    required this.url,
    required this.host,
  });

  final CasHop hop;
  final String url;
  final String host;

  /// Sign-in succeeded: we are on a property, not on CAS.
  bool get isComplete => hop == CasHop.property;

  /// Navigated away from CAS because of a challenge page.
  ///
  /// **Limitation, stated because it matters:** WHU's CAS renders the slider
  /// *inline* on the login form rather than on a separate URL, so URL
  /// classification alone cannot see a challenge that is being shown. Treat a
  /// `false` here as "no challenge *navigation* occurred", never as "no
  /// challenge is on screen". [CasChallengeState] covers the other half.
  bool get challengeNavigated => hop == CasHop.challenge;

  /// Whether this property is one this project cares about.
  bool get isKnownProperty => WhuProperty.values.any((p) => p.host == host);

  static final List<String> _challengePathSnippets = [
    'slidercaptcha',
    'checkneedcaptcha',
    'opencaptcha',
    'verifycaptcha',
    '/captcha',
    'verifyslidercaptcha',
    'getdynamiccode',
  ];

  static CasNavigationIntent classify(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      return CasNavigationIntent(hop: CasHop.unknown, url: rawUrl, host: '');
    }
    final host = uri.host;
    final lowerPath = uri.path.toLowerCase();

    if (host == 'cas.whu.edu.cn') {
      final isChallenge = _challengePathSnippets.any(lowerPath.contains);
      return CasNavigationIntent(
        hop: isChallenge ? CasHop.challenge : CasHop.cas,
        url: rawUrl,
        host: host,
      );
    }

    final isProperty = WhuProperty.values.any((p) => p.host == host);
    return CasNavigationIntent(
      hop: isProperty ? CasHop.property : CasHop.unknown,
      url: rawUrl,
      host: host,
    );
  }

  @override
  String toString() => 'CasNavigationIntent($hop on $host)';
}

/// The server's verdict on whether an interactive CAPTCHA is demanded.
///
/// **There is no client-side switch.** The binary's only `validate=` literal is
/// `validate=no`, and the earlier assumption that a `validate=1` parameter
/// would skip the CAPTCHA is not supported by anything: the gate is
/// [CasOrigin.checkNeedCaptcha], which answers `{"isNeed": <bool>}` server-side.
enum CasChallengeState {
  /// We have not asked, or the answer was unusable.
  unknown,

  /// The server says no CAPTCHA is needed right now. This can flip on a timer,
  /// a rate limit, or a change of IP — it is a policy, not a property.
  notRequired,

  /// The server says it wants one. The person must clear it themselves.
  required,
}

/// Turns a `{"isNeed": ...}` body into a [CasChallengeState].
///
/// Returns [CasChallengeState.unknown] for any body that is not that shape
/// rather than throwing, because a challenge verdict we cannot read must not
/// crash a sign-in flow.
CasChallengeState parseChallengeState(String body) {
  final trimmed = body.trimLeft();
  if (trimmed.isEmpty) return CasChallengeState.unknown;
  if (trimmed.contains('"isNeed":true')) return CasChallengeState.required;
  if (trimmed.contains('"isNeed":false')) return CasChallengeState.notRequired;
  if (trimmed.contains('"isNeed": true')) return CasChallengeState.required;
  if (trimmed.contains('"isNeed": false')) {
    return CasChallengeState.notRequired;
  }
  return CasChallengeState.unknown;
}

/// Builds the full CAS sign-in URL for a property.
///
/// Fails when no service target is established for it — returning a plausible
/// guess instead would produce a redirect loop against a university login page,
/// which is worse than a typed failure.
Result<String> casLoginUrlFor(WhuProperty property) {
  final service = property.casServiceUrl;
  if (service == null || service.isEmpty) {
    return Failure<String>.reason(
      FailureKind.validation,
      message: 'No CAS service target established for ${property.name}; '
          'refusing to guess one.',
    );
  }
  // encodeComponent, not Uri.encodeQueryComponent: the service is itself a
  // URL containing ? and =, which must arrive intact or CAS rejects it.
  final encoded = Uri.encodeComponent(service);
  return Success('${CasOrigin.login}$encoded');
}

/// The service target a given property redirects to, if one is established.
Uri? serviceUriFor(WhuProperty property) {
  final s = property.casServiceUrl;
  return s == null || s.isEmpty ? null : Uri.parse(s);
}

/// Raw cookie data, independent of any platform cookie-store type.
///
/// A record so the pure core stays free of plugin types and the tests never
/// touch a platform channel.
///
/// [path] is part of the identity rather than decoration. The two hosts involved
/// both scope a `JSESSIONID`, and the CAS grant lives at `/authserver` while a
/// service session lives at `/`; without the path, two genuinely different
/// cookies look like one name and quietly overwrite each other.
typedef CookieData = ({
  String name,
  String value,
  String domain,
  String path,
  bool hostOnly,
});

/// Whether a stored cookie should ride along on a request to [uri].
///
/// RFC 6265 §5.1.3 for the domain and §5.1.4 for the path — the same rules
/// [CasCookieJar] applies while it is *receiving* cookies. It lives here as a
/// free function so the jar and the session cannot drift apart on it.
///
/// Two boundaries bite in practice. The **path**: a cookie scoped to
/// `/authserver` covers `/authserver/login` and must not cover `/authserverx`,
/// which merely starts with the same characters. The **host-only flag**: a
/// cookie sent without a `Domain` attribute belongs to exactly the host that set
/// it and to no subdomain of it.
bool cookieCovers(CookieData c, Uri uri) {
  final host = uri.host.toLowerCase();
  final domain = c.domain.replaceFirst(RegExp(r'^\.'), '').trim().toLowerCase();
  if (domain.isEmpty) return false;

  if (host != domain) {
    if (c.hostOnly) return false;
    if (!host.endsWith('.$domain')) return false;
  }

  final path = c.path.isEmpty ? '/' : c.path;
  final target = uri.path.isEmpty ? '/' : uri.path;
  if (target == path) return true;
  if (!target.startsWith(path)) return false;
  // A path ending in '/' is a prefix in its own right; otherwise the next
  // character has to be a separator. `target.length > path.length` holds here,
  // because the equal-length case returned above.
  return path.endsWith('/') || target[path.length] == '/';
}

/// Selects the cookies worth keeping out of a jar, **scope intact**.
///
/// This is what a session is built from. A jar spans two hosts: the
/// ticket-granting cookie sits on `cas.whu.edu.cn` while the service session
/// sits on the property. The filter therefore keeps anything that covers the
/// **target property** *or* **the CAS host** — filtering on the property alone
/// silently discards the grant, and the jar then looks valid while being unable
/// to extend to any other property.
///
/// Siblings are still dropped: a `seat.lib.whu.edu.cn` cookie has no business
/// riding along in a 教务 session.
///
/// The returned values are secrets. Callers must not log them or place them in
/// error text.
List<CookieData> scopeCookies(
  Iterable<CookieData> incoming,
  WhuProperty target,
) {
  const casHost = 'cas.whu.edu.cn';
  final targetHost = target.host;
  final out = <CookieData>[];

  for (final c in incoming) {
    if (c.name.trim().isEmpty || c.value.trim().isEmpty) continue;

    final domain =
        c.domain.replaceFirst(RegExp(r'^\.'), '').trim().toLowerCase();
    if (domain.isNotEmpty &&
        !_domainMatches(domain, targetHost) &&
        !_domainMatches(domain, casHost)) {
      continue;
    }

    out.add(c);
  }
  return out;
}

/// The cookie names and values, **flattened by name**.
///
/// ⚠️ **Never use this to build a `Cookie:` header.** Flattening discards the
/// domain and the path, and in this system that is not a tidy-up but a defect:
/// `cas.whu.edu.cn` and `jwgl.whu.edu.cn` both issue a `JSESSIONID` and a
/// `route`, so one of each pair overwrites the other, and the surviving CAS
/// cookie is then sent to the service host — including `CASTGC`, which no
/// service has any business receiving.
///
/// Use [scopeCookies] with [cookieCovers] for requests. This exists for asking
/// whether a grant is present at all ([requireGrant]), for diagnostics, and for
/// the tests that pin the grant rule.
Map<String, String> filterCookies(
  Iterable<CookieData> incoming,
  WhuProperty target,
) {
  final out = <String, String>{};
  for (final c in scopeCookies(incoming, target)) {
    // Last write wins: a refreshed cookie supersedes an older one of the same
    // name. That is exactly the ambiguity this function must not be trusted to
    // resolve for a request.
    out[c.name.trim()] = c.value.trim();
  }
  return out;
}

/// Whether a cookie's domain covers [host].
///
/// Two cases: the cookie is scoped to exactly this host, or to a parent of it
/// (`whu.edu.cn` matching `jwgl.whu.edu.cn`). A cookie scoped to a *sibling*
/// host never covers this one.
bool _domainMatches(String domain, String host) {
  final d = domain.toLowerCase();
  final h = host.toLowerCase();
  if (d == h) return true;
  return h.endsWith('.$d');
}

/// Whether a cookie jar is sufficient to reach [property].
///
/// A jar with no ticket-granting cookie is a service-local session: it can
/// still talk to *one* host, but it cannot be extended to another property
/// without another interactive sign-in.
Result<Map<String, String>> requireGrant(
  Map<String, String> cookies,
  WhuProperty property,
) {
  if (cookies.isEmpty) {
    // `Failure.reason` is deliberately non-const (see result.dart), so this
    // cannot be a const expression either.
    return Failure<Map<String, String>>.reason(
      FailureKind.validation,
      message: 'No cookies captured',
    );
  }
  final tgc = cookies[CasOrigin.tgcCookie]?.trim() ?? '';
  if (tgc.isEmpty) {
    return Failure<Map<String, String>>.reason(
      FailureKind.unauthorized,
      message: 'Captured a service session on ${property.host} but no '
          '${CasOrigin.tgcCookie}; the CAS grant is missing, so this cannot be '
          'extended to another property.',
    );
  }
  return Success(Map<String, String>.from(cookies));
}
