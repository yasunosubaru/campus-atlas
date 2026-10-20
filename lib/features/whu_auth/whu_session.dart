import 'cas_navigation.dart' show CookieData, cookieCovers;
import 'whu_endpoints.dart';

/// Which university web property a session unlocks.
///
/// A CAS ticket-granting cookie is *not* scoped to one service: the TGC is the
/// single sign-on token, and each service issues its own ST after a 302. So one
/// interactive sign-in can be reused across properties without burning another
/// login attempt, which matters because the origin rate-limits repeated
/// logins. The distinction that actually matters is whether *this* service has
/// been redeemed into a service-local session yet.
enum WhuProperty {
  /// `jwgl.whu.edu.cn` — 教务. Yields [JwglOrigin.gradeQuery].
  jwgl,

  /// `ugsqs.whu.edu.cn` — 教师评教. No public assets of any kind; the only
  /// reachable shape is to ride an already-live CAS session.
  teachingEvaluation,

  /// `seat.lib.whu.edu.cn` — 图书馆座位.
  librarySeat;

  String get host => switch (this) {
        WhuProperty.jwgl => 'jwgl.whu.edu.cn',
        WhuProperty.teachingEvaluation => 'ugsqs.whu.edu.cn',
        WhuProperty.librarySeat => 'seat.lib.whu.edu.cn',
      };

  /// The CAS `service` target for this property, or `null` when this project
  /// has not established one.
  ///
  /// A null here is a real answer, not an omission: it means "do not attempt a
  /// flow for this property yet", which is preferable to picking a plausible
  /// URL and producing a redirect loop.
  String? get casServiceUrl => switch (this) {
        // [V] verbatim in the Windows binary's string snapshot.
        WhuProperty.jwgl => JwglOrigin.casService,
        // [D] from the prior session's log; absent from this project's binary.
        WhuProperty.teachingEvaluation => TeachingEvalOrigin.casService,
        // [V-but-ambiguous] see LibrarySeatOrigin.casService — may be the
        // pre-CAS entry page rather than the service target, so withheld.
        WhuProperty.librarySeat => null,
      };

  /// The page a person would open in a browser to reach this property.
  ///
  /// Deliberately the **front door** rather than the CAS service URL. Starting
  /// here is what makes this client's flow match a browser's, and the difference
  /// is not cosmetic: the property sets its own session cookie on the way past and
  /// hands back the CAS URL *it* wants, with whatever parameters it puts there.
  /// Going straight to CAS skips that entirely, and the property is then asked to
  /// redeem a ticket while holding no session of its own — measured behaviour,
  /// not a guess: `GET /` answers
  /// `302 → https://jwgl.whu.edu.cn/sso/jznewsixlogin?ydtype=0`, and that in turn
  /// answers `302 → https://cas.whu.edu.cn/authserver/login?service=…`.
  String? get entryUrl => switch (this) {
        WhuProperty.jwgl => 'https://jwgl.whu.edu.cn/',
        WhuProperty.teachingEvaluation => 'https://ugsqs.whu.edu.cn/',
        // No established way in, for the same reason [casServiceUrl] is null.
        WhuProperty.librarySeat => null,
      };

  /// Every property this project can currently target with a CAS service URL.
  static List<WhuProperty> get targetable =>
      values.where((p) => p.casServiceUrl != null).toList(growable: false);
}

/// A live single-sign-on session, held **in memory for the process lifetime**.
///
/// Design constraint, stated up front because it is a security decision and not
/// an implementation detail: this object is never written to disk. The user
/// signs in interactively each time they use a protected feature, and when the
/// process exits the credential is gone. Persisting the cookie jar would mean
/// storing a single-sign-on credential in platform preferences, which on
/// desktop are plaintext files — not a trade worth making for the convenience
/// of skipping one WebView sign-in.
class WhuSession {
  /// Both collections are frozen on the way in, so a session cannot be edited by
  /// whoever happens to be holding a reference to it. That is enforced here
  /// rather than left to callers, because the one thing this object must never do
  /// is change out from under a request in flight.
  WhuSession({
    required Map<String, String> cookies,
    required List<CookieData> scoped,
    required this.acquiredAt,
    this.handshake = const <String>[],
    this.properties = const <WhuProperty>{},
  })  : cookies = Map.unmodifiable(cookies),
        scoped = List.unmodifiable(scoped) {
    if (cookies.isEmpty) {
      throw ArgumentError('A session needs at least one cookie');
    }
  }

  /// Cookie name to value. Values are opaque base64 CAS blobs and are treated
  /// as secrets: never log them, never include them in error text.
  ///
  /// ⚠️ **Diagnostics only.** Flattening by name threw away the domain and the
  /// path, so this cannot answer "does this cookie belong to that host?" — and
  /// in this system that question has a real answer, because `cas.whu.edu.cn`
  /// and `jwgl.whu.edu.cn` both issue a `JSESSIONID` and a `route`. Build
  /// request headers from [cookieHeaderFor] instead.
  final Map<String, String> cookies;

  /// Every cookie together with the host and path it belongs to.
  ///
  /// This is what a request is assembled from; [cookies] is the readable view.
  final List<CookieData> scoped;

  /// The requests that produced this session, as recorded by `CasHttpClient`.
  ///
  /// Carried on the session rather than kept in a global because it is the only
  /// evidence of *how* the session was obtained — and when a later request is
  /// refused, that is the first thing worth looking at. Safe to display: tickets
  /// are redacted and cookie values never appear.
  final List<String> handshake;

  /// When the CAS ticket-granting cookie was issued.
  final DateTime acquiredAt;

  /// Properties already redeemed into a service-local session. A property
  /// absent from this set still has a valid TGC, and can be redeemed without a
  /// second sign-in.
  final Set<WhuProperty> properties;

  /// The ticket-granting cookie, or null when the session has none — in which
  /// case this is a service-local session only and cannot be extended.
  ///
  /// Read out of [scoped] with the host checked, not out of the flattened [cookies]
  /// map. The grant belongs to the central host, and there is a real collision to
  /// lose: went the walk to the sign-in form puts the property's `JSESSIONID` in
  /// the jar first, and flattening then keeps whichever host came last by name
  /// alone. The names differ here — `CASTGC` is the central service's — but the
  /// same reasoning is why this cannot be left to a map keyed by name.
  String? get tgc {
    for (final c in scoped) {
      if (c.name != CasOrigin.tgcCookie) continue;
      final domain =
          c.domain.replaceFirst(RegExp(r'^\.'), '').trim().toLowerCase();
      if (domain == _casHost) return c.value;
    }
    return null;
  }

  static const String _casHost = 'cas.whu.edu.cn';

  bool get hasTgc => (tgc ?? '').isNotEmpty;

  bool isAuthenticatedTo(WhuProperty property) => properties.contains(property);

  /// Whether the session is still usable.
  ///
  /// [ttl] defaults to two hours. CAS ticket-granting cookies expire on the
  /// server's schedule and will simply start returning 401s; this is a
  /// client-side courtesy check to avoid showing an empty list as if it were
  /// the truth, not a claim about the server's expiry.
  bool isFresh({Duration ttl = const Duration(hours: 2), DateTime? now}) =>
      (now ?? DateTime.now()).difference(acquiredAt) < ttl;

  /// Age of the session, for display.
  Duration age({DateTime? now}) =>
      (now ?? DateTime.now()).difference(acquiredAt);

  /// Value for an outgoing `Cookie:` header addressed to [uri].
  ///
  /// Only the cookies that actually cover [uri] are sent. That is not tidiness:
  /// a sign-in spans two hosts that both issue a `JSESSIONID`, so a header
  /// assembled from names alone sent the central `CASTGC` to a service host and
  /// let one host's session cookie silently overwrite the other's.
  ///
  /// Sorted by name so the header is deterministic — which keeps tests
  /// meaningful and makes an accidental log easier to spot.
  String cookieHeaderFor(Uri uri) {
    final applicable = scoped
        .where((c) => cookieCovers(c, uri))
        .toList(growable: false)
      ..sort((a, b) => a.name.compareTo(b.name));
    return applicable.map((c) => '${c.name}=${c.value}').join('; ');
  }

  /// Whether anything at all would be sent to [uri].
  ///
  /// Lets a refusal be explained — "this session holds nothing for that host" —
  /// without bringing a cookie value anywhere near a message.
  bool sendsAnythingTo(Uri uri) => scoped.any((c) => cookieCovers(c, uri));

  /// Returns a copy with [property] marked as redeemed.
  WhuSession withProperty(WhuProperty property) => WhuSession(
        cookies: cookies,
        scoped: scoped,
        acquiredAt: acquiredAt,
        handshake: handshake,
        properties: {...properties, property},
      );

  /// Merges [incoming] over this session, newest value wins.
  ///
  /// A cookie is the *same* cookie when domain, path **and** name all match —
  /// exactly the key [CasCookieJar] stores under. Matching on the name alone is
  /// what let one host's `JSESSIONID` replace another's.
  ///
  /// [now] exists so callers — and tests — can supply the clock. Reading
  /// `DateTime.now()` inline would make "the age was re-stamped" impossible to
  /// assert: Windows' system clock granularity is around 15 ms, so two calls in
  /// the same tick compare equal and the assertion becomes flaky rather than
  /// meaningful.
  WhuSession merge(List<CookieData> incoming, {DateTime? now}) {
    if (incoming.isEmpty) return this;

    final byKey = <String, CookieData>{
      for (final c in scoped) _keyOf(c): c,
    };
    for (final c in incoming) {
      byKey[_keyOf(c)] = c;
    }
    final merged = byKey.values.toList(growable: false);

    return WhuSession(
      cookies: {for (final c in merged) c.name: c.value},
      scoped: merged,
      acquiredAt: now ?? DateTime.now(),
      handshake: handshake,
      properties: properties,
    );
  }

  static String _keyOf(CookieData c) => '${c.domain}|${c.path}|${c.name}';

  /// Cookie names only — safe to display. Values never are.
  Set<String> get cookieNames => cookies.keys.toSet();

  @override
  String toString() =>
      'WhuSession(${cookieNames.join(",")} · properties=${properties.map((p) => p.name).join(",")} '
      '· age=${age().inMinutes}m)';
}

/// What went wrong when an interactive sign-in did not complete.
enum SignInOutcome {
  /// The user reached a property page holding a valid service session.
  completed,

  /// The WebView was dismissed before a session was established.
  cancelled,

  /// A CAPTCHA was shown and, from this project's vantage point, left unsolved.
  ///
  /// This is an expected outcome, not an error: the person signing in clears it
  /// themselves. There is deliberately no code path that attempts to solve,
  /// infer, or synthesise a CAPTCHA result.
  challengeOutstanding,

  /// The origin refused or could not be reached.
  originUnreachable,
}
