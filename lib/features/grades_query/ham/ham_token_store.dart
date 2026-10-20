/// Persists the Ham authorisation so it survives a restart.
///
/// ## The trade-off, stated plainly
///
/// This project's rule has been that bearer credentials do not go to disk. The
/// user asked for this exception explicitly, because re-authorising on every
/// launch is worse than the risk on their own machine. What that means in
/// practice, so nobody is surprised later:
///
///   * the access token is written **in plaintext** by `shared_preferences` to
///     the app's own configuration directory — any process running as this user
///     can read it;
///   * it is a bearer credential for the user's Ham account, revocable at
///     `ham.nowcent.cn/console/tokens` and from the screen this store backs;
///   * it expires. A stored token past its deadline is treated as **absent**, not
///     as valid-but-stale, so an expired entry cannot make a request look like an
///     authorization failure.
///
/// The `client_id` is stored too, but that one is not a secret: it only saves
/// re-registering an OAuth client each time, and it has its own 30-day life.
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'ham_oauth.dart';

class HamTokenStore {
  const HamTokenStore();

  static const String _tokenKey = 'ham.token.access';
  static const String _obtainedKey = 'ham.token.obtained_at';
  static const String _expiresKey = 'ham.token.expires_at';

  static const String _clientIdKey = 'ham.oauth.client_id';
  static const String _redirectKey = 'ham.oauth.redirect_uri';
  static const String _clientExpiresKey = 'ham.oauth.client_expires_at';

  /// The stored token, or null when there is none **or it has expired**.
  ///
  /// An expired token is cleared on read rather than returned: handing back a
  /// dead token would make the next query fail with a 401, which reads as "your
  /// key is wrong" when the truthful message is "your authorisation ran out".
  Future<HamToken?> loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_tokenKey);
    if (raw == null || raw.isEmpty) return null;

    final obtained = DateTime.tryParse(prefs.getString(_obtainedKey) ?? '');
    final expires = DateTime.tryParse(prefs.getString(_expiresKey) ?? '');
    if (obtained == null || expires == null) {
      await clearToken();
      return null;
    }

    final token = HamToken(
      accessToken: raw,
      obtainedAt: obtained,
      expiresAt: expires,
    );
    if (token.isExpired) {
      await clearToken();
      return null;
    }
    return token;
  }

  Future<void> saveToken(HamToken token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token.accessToken);
    await prefs.setString(_obtainedKey, token.obtainedAt.toIso8601String());
    await prefs.setString(_expiresKey, token.expiresAt.toIso8601String());
  }

  Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_obtainedKey);
    await prefs.remove(_expiresKey);
  }

  /// A cached client registration, or null when there is none or it lapsed.
  Future<HamClientRegistration?> loadClient() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_clientIdKey);
    final redirect = prefs.getString(_redirectKey);
    final expires = DateTime.tryParse(prefs.getString(_clientExpiresKey) ?? '');
    if (id == null || id.isEmpty || redirect == null || expires == null) {
      return null;
    }
    final client = HamClientRegistration(
      clientId: id,
      redirectUri: redirect,
      expiresAt: expires,
    );
    return client.isUsable ? client : null;
  }

  Future<void> saveClient(HamClientRegistration client) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_clientIdKey, client.clientId);
    await prefs.setString(_redirectKey, client.redirectUri);
    await prefs.setString(
        _clientExpiresKey, client.expiresAt.toIso8601String());
  }

  /// Removes the token **and** the cached client.
  ///
  /// Both, because a revocation should leave nothing behind that could be used to
  /// re-establish the grant without the user's involvement.
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in const [
      _tokenKey,
      _obtainedKey,
      _expiresKey,
      _clientIdKey,
      _redirectKey,
      _clientExpiresKey,
    ]) {
      await prefs.remove(key);
    }
  }
}
