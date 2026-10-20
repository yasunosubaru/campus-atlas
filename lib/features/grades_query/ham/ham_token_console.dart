/// Drives Ham's token console from inside the app.
///
/// ## What this is
///
/// `ham.nowcent.cn/console/tokens` is a small web app: a Next.js BFF
/// (`app/api/tokens/route.ts`) that proxies `/api/tokens` to the backend's
/// `/web/tokens`. Its own client uses `credentials: 'include'`, i.e. a cookie
/// session — but the proxy **forwards every request header except `Host`** [V,
/// read from `_proxy.ts`], which means an `Authorization: Bearer …` sent to it
/// reaches the backend intact.
///
/// So the console's token management may be drivable with the OAuth access token
/// this app already obtains, which is what makes "manage keys from inside the app"
/// possible at all.
///
/// ## What is verified and what is not
///
/// [V] `GET ham.nowcent.cn/api/tokens` with an **API key** (`ham_…`) answers
/// `403 登录失败`. An API key is a gateway credential, not an identity, so that
/// is expected and says nothing about OAuth tokens.
///
/// [未决] Whether the same endpoint accepts an **OAuth access token**. That needs
/// one real authorisation to settle. This class therefore reports a 401/403 as
/// "the console wants a web session" and leaves the caller to fall back to the
/// token it already has — never as a fatal error, because the feature works
/// without it.
///
/// ## The endpoints, from `services/token/api.ts`
///
/// ```
/// GET    /web/tokens                → list
/// POST   /web/tokens                → {name, scopes, ttl_days} → {raw_token, token}
/// POST   /web/tokens/{id}/rotate    → {ttl_days} → {raw_token, token}
/// DELETE /web/tokens/{id}           → revoke
/// ```
///
/// `ttl_days` is why creating a key here is worth trying: the console can mint one
/// with a fixed 30-day life, which is a better credential to hold than a short
/// OAuth access token.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/result.dart';

/// One key as the console lists it. The value is **not** in here — it was shown
/// once at creation and the server only keeps `last4`.
class HamConsoleToken {
  const HamConsoleToken({
    required this.id,
    required this.name,
    required this.last4,
    required this.scopes,
    required this.expiresAt,
    this.createdAt,
    this.lastUsedAt,
  });

  final String id;
  final String name;
  final String last4;
  final List<String> scopes;
  final DateTime? expiresAt;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;

  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  static HamConsoleToken? tryParse(Object? node) {
    if (node is! Map) return null;
    final id = node['id'];
    if (id is! String || id.isEmpty) return null;
    final scopes = node['scopes'];
    return HamConsoleToken(
      id: id,
      name: '${node['name'] ?? ''}',
      last4: '${node['last4'] ?? ''}',
      scopes: scopes is List ? scopes.map((s) => '$s').toList() : const [],
      expiresAt: DateTime.tryParse('${node['expires_at'] ?? ''}'),
      createdAt: DateTime.tryParse('${node['created_at'] ?? ''}'),
      lastUsedAt: DateTime.tryParse('${node['last_used_at'] ?? ''}'),
    );
  }
}

/// A freshly created key. The raw value exists only in this response.
class HamConsoleKey {
  const HamConsoleKey({required this.rawToken, required this.token});

  /// The key itself. **Shown once** — never logged, never persisted separately
  /// from the token store.
  final String rawToken;

  final HamConsoleToken token;
}

class HamTokenConsole {
  HamTokenConsole({http.Client? httpClient, this.baseUrl = defaultBaseUrl})
      : _http = httpClient ?? http.Client();

  /// [V] The BFF the console's own client talks to.
  static const String defaultBaseUrl = 'https://ham.nowcent.cn/api';

  final http.Client _http;
  final String baseUrl;

  void close() => _http.close();

  /// Lists the account's keys.
  Future<Result<List<HamConsoleToken>>> list(String accessToken) async {
    final r = await _send(accessToken, 'GET', '/tokens');
    if (r.isFailure) return Failure<List<HamConsoleToken>>(r.errorOrNull!);

    final data = r.requireValue;
    final list = data is List ? data : (data is Map ? data['data'] : null);
    if (list is! List) {
      return Failure<List<HamConsoleToken>>.reason(
        FailureKind.invalidData,
        message: '控制台返回的令牌列表形状不认识。',
        endpoint: '$baseUrl/tokens',
      );
    }
    return Success([
      for (final item in list)
        if (HamConsoleToken.tryParse(item) != null)
          HamConsoleToken.tryParse(item)!,
    ]);
  }

  /// Creates a key with a fixed lifetime in days.
  ///
  /// `ttlDays: 30` is the console's own vocabulary and the reason this is worth
  /// calling: a 30-day key is a better thing to keep than a short OAuth token.
  Future<Result<HamConsoleKey>> create(
    String accessToken, {
    String name = 'campus-atlas',
    List<String> scopes = const ['mcp', 'mcp:read'],
    int ttlDays = 30,
  }) async {
    final r = await _send(accessToken, 'POST', '/tokens', body: {
      'name': name,
      'scopes': scopes,
      'ttl_days': ttlDays,
    });
    if (r.isFailure) return Failure<HamConsoleKey>(r.errorOrNull!);
    return _keyFrom(r.requireValue);
  }

  /// Replaces an existing key's value and resets its lifetime.
  Future<Result<HamConsoleKey>> rotate(
    String accessToken,
    String id, {
    int ttlDays = 30,
  }) async {
    final r = await _send(
      accessToken,
      'POST',
      '/tokens/${Uri.encodeComponent(id)}/rotate',
      body: {'ttl_days': ttlDays},
    );
    if (r.isFailure) return Failure<HamConsoleKey>(r.errorOrNull!);
    return _keyFrom(r.requireValue);
  }

  /// Revokes a key.
  Future<Result<void>> revoke(String accessToken, String id) async {
    final r = await _send(
        accessToken, 'DELETE', '/tokens/${Uri.encodeComponent(id)}');
    if (r.isFailure) return Failure<void>(r.errorOrNull!);
    return const Success(null);
  }

  Result<HamConsoleKey> _keyFrom(Object? data) {
    final map =
        data is Map ? (data['data'] is Map ? data['data'] as Map : data) : null;
    if (map == null) {
      return Failure<HamConsoleKey>.reason(
        FailureKind.invalidData,
        message: '控制台创建了令牌，但响应里没有可解析的内容。',
        endpoint: '$baseUrl/tokens',
      );
    }
    final raw = map['raw_token'];
    final token = HamConsoleToken.tryParse(map['token']);
    if (raw is! String || raw.isEmpty || token == null) {
      return Failure<HamConsoleKey>.reason(
        FailureKind.invalidData,
        message: '控制台创建了令牌，但响应里缺少 raw_token 或令牌信息。',
        endpoint: '$baseUrl/tokens',
      );
    }
    return Success(HamConsoleKey(rawToken: raw, token: token));
  }

  Future<Result<Object?>> _send(
    String accessToken,
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final request = http.Request(method, uri)
      ..headers['accept'] = 'application/json'
      ..headers['authorization'] = 'Bearer $accessToken'
      // The console is a different origin from the API; its BFF allows
      // credentials from the front-end origin, and this header identifies the
      // caller as that kind of client rather than a cross-site form post.
      ..headers['origin'] = 'https://ham.nowcent.cn';

    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _http.send(request).timeout(const Duration(seconds: 30)),
      );
    } on Exception catch (e) {
      return Failure<Object?>.reason(
        FailureKind.network,
        message: '无法连接 Ham 控制台：$e',
        endpoint: uri.toString(),
      );
    }

    final text = utf8.decode(response.bodyBytes, allowMalformed: true);

    if (response.statusCode == 401 || response.statusCode == 403) {
      // Not a bug in the token: the console authenticates with a web session, and
      // an access token may simply not be accepted there. The caller falls back.
      return Failure<Object?>.reason(
        FailureKind.unauthorized,
        statusCode: response.statusCode,
        endpoint: uri.toString(),
        message: 'Ham 控制台要求网页登录会话，这个凭据不被接受。',
      );
    }

    if (response.statusCode >= 400) {
      return Failure<Object?>.reason(
        FailureKind.server,
        statusCode: response.statusCode,
        endpoint: uri.toString(),
        message: 'Ham 控制台返回 HTTP ${response.statusCode}。',
      );
    }

    if (text.trim().isEmpty) return const Success(null);
    try {
      return Success(jsonDecode(text));
    } on FormatException {
      return Failure<Object?>.reason(
        FailureKind.invalidData,
        message: 'Ham 控制台的响应不是 JSON。',
        endpoint: uri.toString(),
      );
    }
  }
}
