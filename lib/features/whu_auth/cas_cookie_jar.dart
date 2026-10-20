/// A cookie jar for the sign-in conversation, small enough to read in one go.
///
/// ## Why not a package
///
/// Three reasons, in order:
///
///   * **Path matching is the whole point.** An earlier version of this project
///     handed the sign-in result to the caller by asking the platform for
///     cookies at `https://cas.whu.edu.cn` — path `/` — and the server scopes
///     `CASTGC` to `path=/authserver/`. The grant was never returned, so a
///     perfectly good sign-in was reported as "you are not signed in". That bug
///     is only visible if the matching rule is somewhere you can test it.
///   * The conversation spans exactly two hosts and a `Set-Cookie` on a
///     redirect, and nothing else.
///   * A general cookie library brings a public-suffix list, SameSite policy,
///     partitioned storage and a persistence layer — all of which are correct
///     things to have and none of which this needs.
///
/// ## What is deliberately not implemented
///
/// No public-suffix list (the same reason as above, and no user-supplied host
/// ever reaches this jar), no SameSite enforcement, no persistence — the jar
/// lives in memory for one sign-in and is dropped.
///
/// ## Matching rules that are implemented
///
/// RFC 6265 §5.1.4 for paths and §5.1.3 for domains, because those two decide
/// whether the grant survives:
///
///   * a `Domain` attribute makes a cookie cover that domain **and its
///     subdomains**; without one the cookie is host-only and covers exactly the
///     host that set it;
///   * a cookie path covers a request path that equals it, or extends it at a
///     `/` boundary — so `/authserver` covers `/authserver/login` but **not**
///     `/authserverx`, and `/` covers everything.
library;

import 'dart:io' show HttpDate;

import 'cas_navigation.dart' show CookieData, cookieCovers;

/// One cookie, as stored.
class CasCookie {
  const CasCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.hostOnly,
  });

  final String name;
  final String value;

  /// Lower-cased, with any leading dot removed.
  final String domain;

  final String path;

  /// True when the server did not send a `Domain` attribute, which means the
  /// cookie covers exactly [domain] and no subdomain of it.
  final bool hostOnly;

  /// Whether this cookie should ride along on a request to [uri].
  ///
  /// Delegates to [cookieCovers] instead of reimplementing the rule: the session
  /// built out of this jar answers the same question again for every later
  /// request, and two copies of this logic is precisely how the two ends start
  /// disagreeing.
  bool covers(Uri uri) => cookieCovers(record, uri);

  /// This cookie in the form a session stores and matches.
  CookieData get record => (
        name: name,
        value: value,
        domain: domain,
        path: path,
        hostOnly: hostOnly,
      );

  @override
  String toString() => 'CasCookie($name on $domain$path'
      '${hostOnly ? ", host-only" : ""})';
}

/// Stores cookies across the redirects of one sign-in.
class CasCookieJar {
  /// Keyed by `domain|path|name` so that a refreshed cookie of the same name
  /// replaces the old one rather than accumulating, while a same-named cookie
  /// at a different path stays distinct — which is what the server's own use of
  /// `/authserver/` versus `/` relies on.
  final Map<String, CasCookie> _cookies = {};

  /// Absorbs the `Set-Cookie` headers from one response.
  ///
  /// [requestUrl] is needed because a cookie with no `Domain` attribute is
  /// host-only for the host that was asked, and a cookie with no `Path`
  /// attribute defaults to the request path's directory (RFC 6265 §5.1.4).
  void absorb(Uri requestUrl, Iterable<String> setCookieHeaders) {
    for (final header in setCookieHeaders) {
      final parsed = _parse(header, requestUrl);
      if (parsed == null) continue;

      final key = '${parsed.domain}|${parsed.path}|${parsed.name}';

      if (parsed.value == null) {
        // Expiry in the past, or Max-Age=0: the server is clearing it.
        _cookies.remove(key);
        continue;
      }

      _cookies[key] = CasCookie(
        name: parsed.name,
        value: parsed.value!,
        domain: parsed.domain,
        path: parsed.path,
        hostOnly: parsed.hostOnly,
      );
    }
  }

  /// The `Cookie` header value for a request to [uri], or null when nothing
  /// applies.
  ///
  /// Ordering follows RFC 6265 §5.4: longer paths first, so a more specific
  /// cookie is presented first. Servers that naively take the first duplicate
  /// then get the more specific one, which is the intended reading.
  String? headerFor(Uri uri) {
    final applicable = _cookies.values.where((c) => c.covers(uri)).toList()
      ..sort((a, b) => b.path.length.compareTo(a.path.length));

    if (applicable.isEmpty) return null;
    return applicable.map((c) => '${c.name}=${c.value}').join('; ');
  }

  /// Every stored cookie, for handing to [scopeCookies] or [filterCookies].
  ///
  /// The path and the host-only flag travel with it. Dropping either was the
  /// bug: `cas.whu.edu.cn` and `jwgl.whu.edu.cn` both scope a `JSESSIONID`, so
  /// without them the two collapse into one name.
  List<CookieData> get all =>
      _cookies.values.map((c) => c.record).toList(growable: false);

  /// The names currently held, for diagnostics. **Names only** — values are
  /// single-sign-on material and must never be logged.
  List<String> get names =>
      (_cookies.values.map((c) => c.name).toList()..sort());

  int get length => _cookies.length;

  void clear() => _cookies.clear();

  /// Parses one `Set-Cookie` header.
  ///
  /// Returns null when the header is not usable. A returned record with a null
  /// `value` means "delete this cookie".
  _ParsedSetCookie? _parse(String header, Uri requestUrl) {
    final parts = header.split(';');
    if (parts.isEmpty) return null;

    // The first segment is `name=value`. Everything after it is attributes.
    // Splitting on ';' rather than on ',' matters: an `Expires` attribute
    // contains a comma, so comma-splitting corrupts any header carrying one.
    final first = parts.first;
    final eq = first.indexOf('=');
    if (eq <= 0) return null;

    final name = first.substring(0, eq).trim();
    var value = first.substring(eq + 1).trim();
    if (name.isEmpty) return null;

    // A quoted value is legal; strip the quotes but keep the contents verbatim.
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }

    String? domain;
    var hostOnly = true;
    String? path;
    var expired = false;

    for (final attr in parts.skip(1)) {
      final idx = attr.indexOf('=');
      final key =
          (idx < 0 ? attr : attr.substring(0, idx)).trim().toLowerCase();
      final val = idx < 0 ? '' : attr.substring(idx + 1).trim();

      switch (key) {
        case 'domain':
          final d = val.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
          if (d.isNotEmpty) {
            domain = d;
            hostOnly = false;
          }
        case 'path':
          if (val.startsWith('/')) path = val;
        case 'max-age':
          final seconds = int.tryParse(val);
          if (seconds != null && seconds <= 0) expired = true;
        case 'expires':
          final when = _tryParseHttpDate(val);
          // An unparseable date is treated as "not expired", which is the
          // forgiving direction: the alternative is dropping a live session
          // cookie because its date format is unfamiliar.
          if (when != null && !when.isAfter(DateTime.now().toUtc())) {
            expired = true;
          }
      }
    }

    // A cookie whose Domain was given must actually cover the host that set it,
    // or the response is trying to set a cookie for somebody else's site.
    final host = requestUrl.host.toLowerCase();
    if (domain != null) {
      if (host != domain && !host.endsWith('.$domain')) return null;
    }

    return _ParsedSetCookie(
      name: name,
      value: expired ? null : value,
      domain: domain ?? host,
      path: path ?? _defaultPath(requestUrl.path),
      hostOnly: hostOnly,
    );
  }

  /// RFC 6265 §5.1.4 default-path: the request path up to, but not including,
  /// its last `/` — or `/` when there is nothing before it.
  static String _defaultPath(String requestPath) {
    if (requestPath.isEmpty || !requestPath.startsWith('/')) return '/';
    final lastSlash = requestPath.lastIndexOf('/');
    if (lastSlash <= 0) return '/';
    return requestPath.substring(0, lastSlash);
  }

  static DateTime? _tryParseHttpDate(String value) {
    // `HttpDate` handles all three date formats RFC 7231 allows, which
    // hand-rolled parsing does not. Wrapped because a malformed date must not
    // take the sign-in down.
    try {
      return HttpDate.parse(value).toUtc();
    } catch (_) {
      return null;
    }
  }
}

class _ParsedSetCookie {
  const _ParsedSetCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.hostOnly,
  });

  final String name;

  /// Null means "delete this cookie".
  final String? value;
  final String domain;
  final String path;
  final bool hostOnly;
}
