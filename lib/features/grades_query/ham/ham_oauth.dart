/// The 「快捷授权」 flow: get a Ham token without the user copying anything.
///
/// ## Why OAuth and not a scripted login
///
/// A button that logs into Ham for the user would need either their password or
/// an embedded browser. The password is theirs and this project does not handle
/// it; the embedded browser is the component that renders nothing in a Windows
/// release build (see `cas_login_screen.dart` for that whole story).
///
/// So this uses the flow Ham publishes for native apps [V], verified against its
/// own discovery document:
///
/// ```
/// authorization_endpoint  https://ham.nowcent.cn/sso-authorize
/// token_endpoint          https://open-api.ham.nowcent.cn/oauth/token
/// registration_endpoint   https://open-api.ham.nowcent.cn/oauth/register
/// code_challenge_methods  ["S256"]
/// grant_types             ["authorization_code"]     ← no refresh
/// ```
///
/// The **system browser** opens the authorize page — the one the user is already
/// signed into Ham with — and Ham redirects back to a loopback listener this
/// process owns. No embedded browser, no password, and the grant is revocable
/// from Ham's own console.
///
/// ## The 30 days
///
/// Two separate clocks, and confusing them is the bug this comment prevents:
///
///   * the **client registration** expires 30 days after it is issued
///     (`client_secret_expires_at` came back exactly 2 592 000 s after
///     `client_id_issued_at`), so a cached `client_id` has to be re-registered;
///   * the **access token** has its own lifetime, reported as `expires_in`.
///
/// There is **no refresh grant**, so renewal is a fresh authorisation either way.
/// That is what the 「重新授权」 button is for.
///
/// ## What is stored
///
/// `client_id` and its expiry — neither is a credential, and keeping them avoids
/// re-registering a client on every launch. The **access token is never written
/// to disk**: it is a bearer credential for the user's Ham account, and this
/// project does not persist those. The cost is one authorisation per process
/// lifetime, which is about ten seconds when the browser is already signed in.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/result.dart';

/// A token obtained by the interactive flow.
class HamToken {
  const HamToken({
    required this.accessToken,
    required this.obtainedAt,
    required this.expiresAt,
  });

  /// The bearer credential. **Never logged, never written to disk.**
  final String accessToken;

  final DateTime obtainedAt;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Days left, for the UI. Never negative.
  int get daysLeft {
    final left = expiresAt.difference(DateTime.now()).inDays;
    return left < 0 ? 0 : left;
  }

  @override
  String toString() => 'HamToken(expires in ${daysLeft}d)';
}

/// A registered OAuth client, cached across launches.
class HamClientRegistration {
  const HamClientRegistration({
    required this.clientId,
    required this.redirectUri,
    required this.expiresAt,
  });

  final String clientId;
  final String redirectUri;
  final DateTime expiresAt;

  bool get isUsable => DateTime.now().isBefore(expiresAt);

  Map<String, Object?> toJson() => {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'expires_at': expiresAt.toIso8601String(),
      };

  static HamClientRegistration? tryParse(Object? node) {
    if (node is! Map) return null;
    final id = node['client_id'];
    final redirect = node['redirect_uri'];
    final expires = DateTime.tryParse('${node['expires_at'] ?? ''}');
    if (id is! String || id.isEmpty || expires == null || redirect is! String) {
      return null;
    }
    return HamClientRegistration(
      clientId: id,
      redirectUri: redirect,
      expiresAt: expires,
    );
  }
}

/// Runs the interactive authorisation and returns a token.
class HamOAuth {
  HamOAuth({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  static const String authorizationEndpoint =
      'https://ham.nowcent.cn/sso-authorize';
  static const String tokenEndpoint =
      'https://open-api.ham.nowcent.cn/oauth/token';
  static const String registrationEndpoint =
      'https://open-api.ham.nowcent.cn/oauth/register';

  /// [V] The scopes the MCP service advertises and this client needs: read the
  /// grade statistics, and nothing that writes to the account.
  static const String scope = 'openid mcp mcp:read';

  /// [V] Ham's own API-key console — where a key is created, shown once, and
  /// revoked.
  ///
  /// Linked as well as authorised, because it is the authority on keys: an OAuth
  /// grant is convenient but the console is where the user can see and kill it.
  static const String tokenConsoleUrl = 'https://ham.nowcent.cn/console/tokens';

  /// The port the loopback listener asks for.
  ///
  /// Fixed rather than random so the redirect URI is stable and the client can be
  /// registered once. 5173 is used elsewhere in this project for local panels;
  /// 8099 is avoided because it sits in a reserved excluded range.
  static const int preferredPort = 5173;

  static const String callbackPath = '/oauth/callback';

  final http.Client _http;

  /// The client registration this flow used.
  ///
  /// Exposed so the caller can persist it: re-registering on every launch is
  /// wasteful and the registration itself expires after 30 days, which is a
  /// separate clock from the token's.
  HamClientRegistration? lastClient;

  void close() => _http.close();

  /// Registers a client, or reuses a still-valid one.
  Future<Result<HamClientRegistration>> register({
    HamClientRegistration? cached,
    int? port,
  }) async {
    if (cached != null && cached.isUsable) return Success(cached);

    final redirect = 'http://127.0.0.1:${port ?? preferredPort}$callbackPath';
    try {
      final response = await _http
          .post(
            Uri.parse(registrationEndpoint),
            headers: {
              'content-type': 'application/json',
              'accept': 'application/json',
            },
            body: jsonEncode({
              'client_name': 'campus-atlas (open-source desktop)',
              'redirect_uris': [redirect],
              'grant_types': ['authorization_code'],
              'response_types': ['code'],
              // A desktop app cannot keep a secret, so it registers as a public
              // client and relies on PKCE instead.
              'token_endpoint_auth_method': 'none',
              'scope': scope,
            }),
          )
          .timeout(const Duration(seconds: 30));

      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (response.statusCode != 200 && response.statusCode != 201) {
        return Failure<HamClientRegistration>.reason(
          FailureKind.server,
          statusCode: response.statusCode,
          endpoint: registrationEndpoint,
          message: 'Ham 拒绝了客户端注册（HTTP ${response.statusCode}）。',
        );
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return Failure<HamClientRegistration>.reason(
          FailureKind.invalidData,
          message: 'Ham 的注册响应不是 JSON 对象。',
          endpoint: registrationEndpoint,
        );
      }

      final id = decoded['client_id'];
      if (id is! String || id.isEmpty) {
        return Failure<HamClientRegistration>.reason(
          FailureKind.invalidData,
          message: 'Ham 的注册响应没有 client_id。',
          endpoint: registrationEndpoint,
        );
      }

      // Trust the server's own expiry when it gives one, rather than assuming 30
      // days: the value is the authority and a changed policy should not silently
      // produce an expired cached client.
      final expiresAt = _expiryFrom(decoded, defaultDays: 30);
      return Success(HamClientRegistration(
        clientId: id,
        redirectUri: redirect,
        expiresAt: expiresAt,
      ));
    } on TimeoutException {
      return Failure<HamClientRegistration>.reason(
        FailureKind.timeout,
        message: 'Ham 的注册服务没有响应。',
        endpoint: registrationEndpoint,
      );
    } on http.ClientException catch (e) {
      return Failure<HamClientRegistration>.reason(
        FailureKind.network,
        message: '无法连接 Ham 的注册服务：${e.message}',
        endpoint: registrationEndpoint,
      );
    } on FormatException {
      return Failure<HamClientRegistration>.reason(
        FailureKind.invalidData,
        message: 'Ham 的注册响应无法解析。',
        endpoint: registrationEndpoint,
      );
    }
  }

  /// Runs the whole flow: listen, open the browser, take the code, exchange it.
  ///
  /// [openBrowser] is injectable so a test can assert the URL without launching
  /// anything, and so a platform without a browser reports that rather than
  /// hanging for the timeout.
  Future<Result<HamToken>> authorize({
    HamClientRegistration? cached,
    Future<bool> Function(Uri url)? openBrowser,
    Duration timeout = const Duration(minutes: 5),

    /// Called with the authorise URL once it is built, before the browser opens.
    ///
    /// Exists because a closed browser window used to be a dead end: the URL was
    /// generated inside this call, shown once, and unrecoverable — leaving the
    /// person staring at 「等待浏览器授权」 with no way back and the listener
    /// holding the port until the timeout.
    void Function(Uri url)? onAuthorizeUrl,
  }) async {
    // Bind first: the port has to be known before the client is registered,
    // because the redirect URI must match exactly.
    HttpServer? server;
    var port = preferredPort;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException {
      // Port taken: ask for any free one and register a client for it.
      try {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        port = server.port;
      } on SocketException catch (e) {
        return Failure<HamToken>.reason(
          FailureKind.network,
          message: '无法在本机启动回调监听：${e.message}',
        );
      }
    }

    final registered = await register(
      // A cached registration is only reusable when it points at the port that is
      // actually listening. Reusing one that points elsewhere sends the browser
      // to a closed port, and the only symptom is "it never comes back" — or, if
      // the registration itself is stale, a page that refuses the request.
      cached: (cached != null &&
              cached.isUsable &&
              cached.redirectUri == 'http://127.0.0.1:$port$callbackPath')
          ? cached
          : null,
      port: port,
    );
    if (registered.isFailure) {
      await server.close(force: true);
      return Failure<HamToken>(registered.errorOrNull!);
    }
    final client = registered.requireValue;
    lastClient = client;

    // Refuse to open a page that can only end in "missing authorisation
    // parameters". The console's own page rejects the request when either of
    // these is empty, and opening it anyway produces an error the person cannot
    // act on.
    if (client.clientId.trim().isEmpty || client.redirectUri.trim().isEmpty) {
      await server.close(force: true);
      return Failure<HamToken>.reason(
        FailureKind.validation,
        message: '授权参数不完整（client_id 或 redirect_uri 为空），已中止。'
            '请点「清除授权」后重试。',
      );
    }

    final pkce = PkceChallenge.generate();
    final state = _randomString(24);
    final redirectUri = Uri.parse(client.redirectUri);

    final authorizeUri =
        Uri.parse(authorizationEndpoint).replace(queryParameters: {
      'response_type': 'code',
      'client_id': client.clientId,
      'redirect_uri': client.redirectUri,
      'scope': scope,
      'state': state,
      'code_challenge': pkce.challenge,
      'code_challenge_method': 'S256',
    });

    final completer = Completer<Result<String>>();
    late final StreamSubscription<HttpRequest> subscription;
    var closed = false;

    Future<void> finish(Result<String> outcome) async {
      if (completer.isCompleted) return;
      completer.complete(outcome);
      if (!closed) {
        closed = true;
        await subscription.cancel();
        await server!.close(force: true);
      }
    }

    subscription = server.listen((request) async {
      if (request.uri.path != callbackPath) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      final params = request.uri.queryParameters;
      final error = params['error'];
      final code = params['code'];
      final returnedState = params['state'];

      // The state check is not ceremony: without it any page could send this
      // process a code and attach its own Ham grant to the user's session.
      if (returnedState != state) {
        await _respond(request, '授权失败', '回调的 state 与请求不一致，已忽略。');
        await finish(Failure<String>.reason(
          FailureKind.protocol,
          message: '授权回调的 state 不匹配，已拒绝。',
        ));
        return;
      }

      if (error != null && error.isNotEmpty) {
        await _respond(request, '授权未完成', 'Ham 返回：$error');
        await finish(Failure<String>.reason(
          FailureKind.unauthorized,
          message: 'Ham 拒绝了授权：$error',
        ));
        return;
      }

      if (code == null || code.isEmpty) {
        await _respond(request, '授权未完成', '回调里没有 code。');
        await finish(Failure<String>.reason(
          FailureKind.protocol,
          message: '授权回调没有携带 code。',
        ));
        return;
      }

      await _respond(request, '授权完成', '可以关闭这个页面，回到应用继续。');
      await finish(Success(code));
    });

    final opener = openBrowser ?? _openInSystemBrowser;
    onAuthorizeUrl?.call(authorizeUri);
    final opened = await opener(authorizeUri);
    if (!opened) {
      await finish(Failure<String>.reason(
        FailureKind.unsupported,
        message: '无法打开系统浏览器完成授权。',
      ));
    }

    final codeResult = await completer.future.timeout(
      timeout,
      onTimeout: () => Failure<String>.reason(
        FailureKind.timeout,
        message: '等待授权超时（${timeout.inMinutes} 分钟）。',
      ),
    );
    if (codeResult.isFailure) {
      await server.close(force: true);
      return Failure<HamToken>(codeResult.errorOrNull!);
    }

    return exchange(
      code: codeResult.requireValue,
      client: client,
      verifier: pkce.verifier,
      redirectUri: redirectUri,
    );
  }

  /// Trades the code for an access token.
  Future<Result<HamToken>> exchange({
    required String code,
    required HamClientRegistration client,
    required String verifier,
    required Uri redirectUri,
  }) async {
    try {
      final response = await _http
          .post(
            Uri.parse(tokenEndpoint),
            headers: {
              'content-type': 'application/x-www-form-urlencoded',
              'accept': 'application/json',
            },
            body: Uri(queryParameters: {
              'grant_type': 'authorization_code',
              'code': code,
              'redirect_uri': redirectUri.toString(),
              'client_id': client.clientId,
              'code_verifier': verifier,
            }).query,
          )
          .timeout(const Duration(seconds: 30));

      final text = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (response.statusCode != 200) {
        return Failure<HamToken>.reason(
          FailureKind.unauthorized,
          statusCode: response.statusCode,
          endpoint: tokenEndpoint,
          // The body of a token error is a short machine code, not a secret.
          message: 'Ham 没有签发令牌（HTTP ${response.statusCode}）：'
              '${text.length > 160 ? text.substring(0, 160) : text}',
        );
      }

      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        return Failure<HamToken>.reason(
          FailureKind.invalidData,
          message: 'Ham 的令牌响应不是 JSON 对象。',
          endpoint: tokenEndpoint,
        );
      }

      final token = decoded['access_token'];
      if (token is! String || token.isEmpty) {
        return Failure<HamToken>.reason(
          FailureKind.invalidData,
          message: 'Ham 的令牌响应没有 access_token。',
          endpoint: tokenEndpoint,
        );
      }

      final now = DateTime.now();
      final seconds = decoded['expires_in'];
      final lifetime = seconds is int
          ? Duration(seconds: seconds)
          : (seconds is String
              ? Duration(seconds: int.tryParse(seconds) ?? 2592000)
              : const Duration(days: 30));

      return Success(HamToken(
        accessToken: token,
        obtainedAt: now,
        expiresAt: now.add(lifetime),
      ));
    } on TimeoutException {
      return Failure<HamToken>.reason(
        FailureKind.timeout,
        message: 'Ham 的令牌服务没有响应。',
        endpoint: tokenEndpoint,
      );
    } on http.ClientException catch (e) {
      return Failure<HamToken>.reason(
        FailureKind.network,
        message: '无法连接 Ham 的令牌服务：${e.message}',
        endpoint: tokenEndpoint,
      );
    } on FormatException {
      return Failure<HamToken>.reason(
        FailureKind.invalidData,
        message: 'Ham 的令牌响应无法解析。',
        endpoint: tokenEndpoint,
      );
    }
  }

  /// Opens [url] in the user's default browser.
  ///
  /// Not an embedded view: the platform-view compositing path is exactly what
  /// fails in a Windows release build, and the browser already holds the Ham
  /// session the user signed in with.
  static Future<bool> _openInSystemBrowser(Uri url) async {
    try {
      return await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  static Future<void> _respond(
    HttpRequest request,
    String title,
    String detail,
  ) async {
    request.response.headers.contentType = ContentType.html;
    request.response.write('''
<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">
<title>$title</title>
<style>body{font-family:system-ui,sans-serif;margin:60px auto;max-width:520px;
line-height:1.6;color:#222}h1{font-size:20px}</style></head>
<body><h1>$title</h1><p>$detail</p></body></html>
''');
    await request.response.close();
  }

  static DateTime _expiryFrom(Map<dynamic, dynamic> node,
      {required int defaultDays}) {
    final issued = node['client_id_issued_at'];
    final secretExpires = node['client_secret_expires_at'];
    if (issued is int && secretExpires is int) {
      // The server states both ends; use the pair rather than a guess.
      final seconds = secretExpires - issued;
      if (seconds > 0) {
        return DateTime.now().add(Duration(seconds: seconds));
      }
    }
    if (secretExpires is int) {
      return DateTime.fromMillisecondsSinceEpoch(secretExpires * 1000);
    }
    return DateTime.now().add(Duration(days: defaultDays));
  }

  static String _randomString(int length) {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rnd = Random.secure();
    return List.generate(length, (_) => alphabet[rnd.nextInt(alphabet.length)])
        .join();
  }
}

/// PKCE (RFC 7636) verifier and its S256 challenge.
class PkceChallenge {
  const PkceChallenge({required this.verifier, required this.challenge});

  /// 43–128 characters from the unreserved set, per the RFC.
  final String verifier;

  /// BASE64URL(SHA-256(verifier)), unpadded.
  final String challenge;

  static PkceChallenge generate() {
    final verifier = HamOAuth._randomString(64);
    return PkceChallenge(verifier: verifier, challenge: challengeFor(verifier));
  }

  /// The S256 challenge for [verifier].
  ///
  /// Exposed separately because it is the only part with a published test vector,
  /// and a wrong challenge fails at the token exchange with `invalid_grant` —
  /// which reads like an expired code rather than a crypto mistake.
  static String challengeFor(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }
}
