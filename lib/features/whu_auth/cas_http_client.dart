/// Signing in to CAS over HTTP, without a browser.
///
/// ## Why there is no WebView any more
///
/// This project first did the sign-in in an embedded browser, and that is the
/// version a user saw as "the sign-in window is blank". The cause was not this
/// code: Flutter's Windows platform-view compositing path failed under a release
/// build — the WebView2 process loaded the page (its own cache directory proves
/// it) and nothing reached the screen, while the same build in debug and profile
/// mode worked. Two structural faults fell out of that:
///
///   * a release build that renders nothing is not shippable, and the fault was
///     in the engine, not in a file this project can edit;
///   * `webview_windows` no longer compiles against current MSVC, and
///     `webview_flutter` has no Windows implementation at all, so the plugin
///     choice was already down to one.
///
/// Signing in over HTTP removes the whole class of problem, behaves identically
/// on every platform, and is testable. The cost is that a slider CAPTCHA cannot
/// be presented — see [CasCaptchaMode], and the honest handling of it below.
///
/// ## What was verified, and how
///
/// Marking the evidence class matters here, because "it returned 401" sounds
/// like proof and is not.
///
///   * **[V] The password encryption is byte-identical to the page's own.**
///     `bin/verify_cas_crypto.dart` re-runs the live `encrypt.js` under Node and
///     compares 9 vectors character for character. This is the real proof that
///     the server will decrypt what is sent.
///   * **[V] A rejected submission answers HTTP 401 and re-renders the form.**
///     Observed once with an account number that cannot exist.
///   * **[V] 401 is *not* specific to a credential verdict.** Omitting the
///     `password` field entirely produces the same status and the same message.
///     So a 401 must never be read as "your encryption was wrong" — it is a
///     generic refusal, and this client reports it as one.
///   * **[V] The refusal wording is not fixed, and that is deliberate on the
///     server's part.** Two variants have been observed on the same deployment:
///     `该账号非常用账号或用户名密码有误` ("not a commonly used account, or the
///     username/password is wrong") and `该账号不存在或用户名密码有误` ("the
///     account does not exist, or the username/password is wrong"). Both decline
///     to say which half is true, which is normal practice — it denies an attacker
///     a way to enumerate real account numbers — so no attempt is made here to
///     tell them apart, and nothing parses the sentence for meaning. It is a
///     refusal, quoted as given.
///   * **[V] The server processes the form as a genuine attempt.** The returned
///     page carries an advanced `execution` (`e1s1` → `e1s2`), which is what a
///     well-formed submission from the page itself produces.
///   * **[V] A successful grant is a redirect carrying `?ticket=ST-...`**, and
///     the redeemed cookie is `CASTGC` scoped to `path=/authserver` — recorded
///     from a real interactive sign-in earlier in this project's history, which
///     is why [CasCookieJar] matches paths rather than hosts.
///   * **[V] `checkNeedCaptcha` is not a usable gate.** Measured, not assumed:
///     the same account number answered `{"isNeed":true}` and then
///     `{"isNeed":false}` within minutes, a number that had never been used
///     answered `true` while one that had failed four times answered `false`, and
///     a five-number sweep found no `true` at all. There is no correlation with
///     the account's attempt history, so a positive verdict does not predict that
///     a submission will be refused.
///
///     An earlier version of this client refused to submit on a positive verdict.
///     That turned a sign-in that would have worked into `challengeRequired`, on
///     the strength of a flag that had already flipped back — which is worse than
///     not asking, because it is a dead end the person cannot get past. This
///     client now submits and lets the server be the authority, exactly as the
///     page does when the text CAPTCHA is the one in play.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/network/body_shape.dart';
import '../../core/result.dart';
import 'cas_cookie_jar.dart';
import 'cas_crypto.dart';
import 'cas_login_form.dart';
import 'cas_navigation.dart';
import 'whu_endpoints.dart';
import 'whu_session.dart';

/// Signs in to the university's central authentication service.
///
/// One instance is one attempt: it owns a cookie jar and throws it away at the
/// end, because the conversation is stateful (the server tracks `execution` and
/// session affinity) and sharing a jar between attempts is how a stale
/// conversation gets reused.
class CasHttpClient {
  CasHttpClient({http.Client? httpClient, this.onDiagnostic})
      : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// Called with short, non-secret progress notes. Used by the diagnostics panel.
  /// Callers must not pass cookie values or passwords through this.
  final void Function(String note)? onDiagnostic;

  final CasCookieJar _jar = CasCookieJar();

  /// The CAS host everything in this conversation talks to.
  ///
  /// Unused for requests — [CasOrigin] holds the URLs — but kept as the single
  /// place the origin is spelled, for the user-agent string and for diagnostics.
  static const String _userAgent = 'campus-atlas/0.1 (+open-source; Windows)';

  /// The central service's host, read off the one constant that states it rather
  /// than re-parsed at each comparison — several places need to ask "did CAS
  /// answer, or the property?" and they must not disagree.
  static final String _casHost = Uri.parse(CasOrigin.authserverRoot).host;

  /// How many redirects to chase before giving up. A correct sign-in needs two
  /// (CAS → service), plus slack for a load balancer hop.
  static const int _maxHops = 8;

  /// The verification mode this deployment uses, read from the page's own
  /// `captchaSwitch` while the form is loaded.
  ///
  /// Populated as soon as the form parses, so it is available on every path. The
  /// caller reads it after a [FailureKind.challengeRequired] result to choose
  /// between offering a code field (`text`) and explaining that this client
  /// cannot present the challenge at all (`slider`) — opposite instructions that
  /// must not be guessed.
  CasCaptchaMode? captchaMode;

  /// Every request made, as `METHOD host/path → status → Location [set: names]`.
  ///
  /// Kept because a boolean cannot express the difference between "the ticket
  /// was redeemed" and "the service answered its own sign-in page", and that
  /// difference decides whether the person signs in again or reports a bug.
  ///
  /// Safe to display: a `ticket=` in a `Location` is redacted, and cookie
  /// **values** never appear — only their names.
  final List<String> chain = [];

  /// The page that stopped the sign-in, and the URL it came from.
  ///
  /// Populated only on a failure, and only when the failure was a **page** rather
  /// than a status code. That page is the whole answer in this situation: when the
  /// central service accepts the password and then declines to issue a ticket, what
  /// it wants instead is written on the page it sends back and nowhere else. So it
  /// is kept verbatim rather than summarised into "the sign-in failed".
  ///
  /// Safe to display: it is a rendered challenge, not a credential store. It is
  /// never captured for the login response itself, which does carry a session.
  String? failurePageBody;
  String? failurePageUrl;

  /// Signs in and returns the cookie jar as a session.
  ///
  /// [captcha] is the text the person typed, needed only when the server asks for
  /// the text CAPTCHA and the caller is retrying with an answer.
  Future<Result<WhuSession>> signIn({
    required WhuProperty property,
    required String username,
    required String password,
    String? captcha,
  }) async {
    final staff = username.trim();
    if (staff.isEmpty) {
      return Failure<WhuSession>.reason(
        FailureKind.validation,
        message: 'Enter your student or staff number.',
      );
    }
    if (password.isEmpty) {
      return Failure<WhuSession>.reason(
        FailureKind.validation,
        message: 'Enter your password.',
      );
    }

    // ---- 1. walk to the sign-in form the way a browser would -------------
    //
    // Starting at the property rather than at CAS is deliberate, and it is the
    // step a hand-built client gets wrong. The property sets its own session
    // cookie on the way past and answers with the CAS URL *it* wants; going
    // straight to CAS leaves the property holding no session of its own when the
    // ticket comes back, and it then refuses a redemption the central service has
    // already blessed.
    final entry = property.entryUrl;
    if (entry == null) {
      return Failure<WhuSession>.reason(
        FailureKind.validation,
        message: 'No entry point is established for ${property.name}; refusing '
            'to guess one.',
      );
    }

    final reached = await _walkToSignIn(Uri.parse(entry), property);
    if (reached.isFailure) return Failure<WhuSession>(reached.errorOrNull!);
    final (loginUrl, page) = reached.requireValue;

    final html = _utf8(page);
    final formResult = CasLoginForm.parse(html);
    if (formResult.isFailure) {
      return Failure<WhuSession>(formResult.errorOrNull!);
    }
    final form = formResult.requireValue;
    captchaMode = form.captchaMode;
    _note('form: $form');

    // ---- 2. record what the challenge probe says --------------------------
    //
    // Recorded, never obeyed. See the class docs: the verdict was measured to
    // flip for the same account within minutes, so trusting it refuses sign-ins
    // that would have worked. It is kept because it is the one line in the
    // diagnostics panel that can explain a challenge refusal after the fact.
    final challenge = await _challengeFor(staff);
    if (challenge == CasChallengeVerdict.required) {
      _note('the probe says a challenge is wanted; submitting anyway, because '
          'that verdict is not reliable enough to refuse on');
    }

    // ---- 3. submit --------------------------------------------------------
    final encrypted = casEncryptPassword(password: password, salt: form.salt);
    if (!encrypted.wasEncrypted) {
      // The page's own fallback sends the password as typed. Sending it is the
      // only thing that can work, and refusing would break the deployment for
      // everybody rather than protecting anyone — but it must not be silent.
      _note('warning: the page sent no encryption salt; the password is being '
          'sent unencrypted, as the form itself would');
    }

    final body = <String, String>{
      'username': staff,
      'password': encrypted.value,
      ...form.fixedFields,
    };
    if (captcha != null && captcha.trim().isNotEmpty) {
      body['captcha'] = captcha.trim();
    }

    _note('POST /authserver/login (${body.length} fields)');
    final http.Response post;
    try {
      post = await _send(
        Uri.parse(CasOrigin.loginPost),
        method: 'POST',
        form: body,
      );
    } on _TransportError catch (e) {
      return _transportFailure<WhuSession>(e);
    }

    // ---- 4. read the verdict ---------------------------------------------
    //
    // 200 and 401 mean the same thing here: **the server re-rendered the form
    // instead of issuing a ticket.** This service answers 401 and others answer
    // 200, and the earlier probe showed that omitting the `password` field
    // altogether produces the identical status *and* the identical sentence — so
    // the status is a generic refusal and must never be read as a verdict about
    // the encryption.
    if (post.statusCode == 200 || post.statusCode == 401) {
      final body = _utf8(post);
      final message = _serverMessage(body) ??
          'The authentication service refused the sign-in.';

      // A refusal that names a verification step is a different instruction from
      // one that names the credentials, and only the server can tell them apart.
      // Detecting it is best-effort; missing it degrades to reporting the
      // server's own sentence, which is what a browser would have shown anyway.
      if (_asksForChallenge(message)) {
        return _challengeFailure<WhuSession>(
          form.captchaMode,
          serverMessage: message,
        );
      }

      return Failure<WhuSession>.reason(
        FailureKind.unauthorized,
        statusCode: post.statusCode,
        message: message,
      );
    }

    if (post.statusCode != 302 && post.statusCode != 303) {
      return Failure<WhuSession>.reason(
        FailureKind.protocol,
        statusCode: post.statusCode,
        message: 'Unexpected answer from the authentication service: HTTP '
            '${post.statusCode}, and not a redirect to the service.',
      );
    }

    // ---- 5. redeem the ticket --------------------------------------------
    final location = post.headers['location'];
    if (location == null || location.isEmpty) {
      return Failure<WhuSession>.reason(
        FailureKind.protocol,
        statusCode: post.statusCode,
        message: 'The authentication service accepted the sign-in but sent no '
            'redirect, so there is no ticket to redeem.',
      );
    }

    _note('accepted; redeeming the ticket');
    final redeemed = await _followForSession(
      loginUrl.resolve(location),
      property: property,
    );
    if (redeemed.isFailure) {
      // Repeated into the notes as well, so the reason lands in the panel on
      // screen instead of only in an error line somebody has to retype to share.
      _note('ticket not redeemed: ${redeemed.errorOrNull!.message}');
      return Failure<WhuSession>(redeemed.errorOrNull!);
    }

    return _sessionFrom(property);
  }

  /// Follows the property's own redirects until CAS serves the sign-in form.
  ///
  /// Returns the URL the form came from — the CAS login URL *the property* asked
  /// for, which is the only authority on what `service` should be — together with
  /// the response, so the document is not fetched twice.
  ///
  /// Every hop absorbs cookies here, and that is the whole reason to walk at all:
  /// the property's session cookie is set on the way past, **before** a ticket
  /// exists, so the property recognises the session the ticket arrives attached
  /// to.
  Future<Result<(Uri, http.Response)>> _walkToSignIn(
    Uri entry,
    WhuProperty property,
  ) async {
    var current = entry;

    for (var hop = 0; hop < _maxHops; hop++) {
      final http.Response res;
      try {
        res = await _send(current);
      } on _TransportError catch (e) {
        return _transportFailure<(Uri, http.Response)>(e);
      }

      if (res.statusCode >= 300 && res.statusCode < 400) {
        final next = res.headers['location'];
        if (next == null || next.isEmpty) {
          return Failure<(Uri, http.Response)>.reason(
            FailureKind.protocol,
            statusCode: res.statusCode,
            message:
                '${current.host} redirected with no destination on the way '
                'to the sign-in form. Requests: ${chain.join(" | ")}',
          );
        }
        current = current.resolve(next);
        continue;
      }

      if (res.statusCode != 200) {
        return Failure<(Uri, http.Response)>.reason(
          FailureKind.server,
          statusCode: res.statusCode,
          endpoint: current.toString(),
          message: '${current.host} answered HTTP ${res.statusCode} on the way '
              'to the sign-in form. Requests: ${chain.join(" | ")}',
        );
      }

      // A 200 ends the walk only when it was CAS that answered. A page from the
      // property would mean it never asked for a sign-in at all, which is a state
      // worth naming rather than trying to parse a form out of.
      if (current.host != Uri.parse(CasOrigin.authserverRoot).host) {
        return Failure<(Uri, http.Response)>.reason(
          FailureKind.protocol,
          statusCode: 200,
          endpoint: current.toString(),
          message: '${property.name} answered a page instead of asking for a '
              'sign-in, so there is no form to fill in. Requests: '
              '${chain.join(" | ")}',
        );
      }

      return Success((current, res));
    }

    return Failure<(Uri, http.Response)>.reason(
      FailureKind.protocol,
      message: 'Gave up after $_maxHops redirects on the way to the sign-in '
          'form. Requests: ${chain.join(" | ")}',
    );
  }

  /// Asks the server whether this account needs a challenge right now.
  ///
  /// A failed probe is not a failure of the sign-in: the answer is an
  /// optimisation, and the form's own variables are the fallback.
  Future<CasChallengeVerdict> _challengeFor(String staff) async {
    final uri = Uri.parse('${CasOrigin.checkNeedCaptcha}?username='
        '${Uri.encodeQueryComponent(staff)}');
    try {
      final res = await _send(uri);
      _note('checkNeedCaptcha -> ${res.statusCode} ${_utf8(res).trim()}');
      if (res.statusCode != 200) return CasChallengeVerdict.unknown;
      return _verdictFrom(_utf8(res));
    } on _TransportError catch (e) {
      _note('checkNeedCaptcha unreachable (${e.reason}); continuing');
      return CasChallengeVerdict.unknown;
    }
  }

  /// The failure for "the central service accepted the password and then asked
  /// for a further step".
  ///
  /// One place, because the same demand arrives two ways — as a redirect back to
  /// CAS, and as a page CAS serves directly — and the two must not drift into
  /// describing the same event differently. It is also the one failure where the
  /// **page** is the substance rather than a detail, so the page is kept.
  Failure<Uri> _furtherStepFailure({
    required Uri at,
    required int status,
    required WhuProperty property,
    required String body,
  }) {
    failurePageUrl = at.toString();
    failurePageBody = body;
    if (body.isEmpty) {
      _note('the central service asked for a further step: ${at.path} '
          '($status, no page read)');
    } else {
      _note('the central service asked for a further step: ${at.path} '
          '($status, ${body.length} B captured)');
    }

    return Failure<Uri>.reason(
      FailureKind.challengeRequired,
      statusCode: status,
      endpoint: at.toString(),
      message: 'The central service accepted the password and then asked for '
          'something further before it will issue a ticket to ${property.host} '
          '(${at.path}). Until that step is satisfied there is no ticket, so no '
          'session can be established.',
    );
  }

  /// Walks the redirect chain until it leaves CAS, absorbing cookies.
  Future<Result<Uri>> _followForSession(
    Uri start, {
    required WhuProperty property,
  }) async {
    var current = start;
    for (var hop = 0; hop < _maxHops; hop++) {
      final http.Response res;
      try {
        res = await _send(current);
      } on _TransportError catch (e) {
        return _transportFailure<Uri>(e);
      }

      if (res.statusCode >= 300 && res.statusCode < 400) {
        final next = res.headers['location'];
        if (next == null || next.isEmpty) {
          return Failure<Uri>.reason(
            FailureKind.protocol,
            statusCode: res.statusCode,
            message: 'Redirect with no destination while redeeming the ticket. '
                'Requests: ${chain.join(" | ")}',
          );
        }

        final target = current.resolve(next);

        // Sent back to the central service after the password was accepted. This
        // is **not** a redemption: CAS has accepted the first factor and is asking
        // for something it has not got. On this deployment that is a
        // re-authentication step — measured: the redirect reads
        // `reAuthCheck/reAuthLoginView.do?isMultifactor=true` — and until it is
        // satisfied no service ticket exists, which is why the property then
        // answers its own login page and looks like the culprit.
        if (target.host == _casHost) {
          // Fetch it anyway. The page is where the demand is written down, and the
          // demand is the only thing that says what to do about it.
          var body = '';
          try {
            body = _utf8(await _send(target));
          } on _TransportError catch (e) {
            _note(
                'the central service asked for a further step at ${target.path} '
                'and the page could not be read (${e.reason})');
          }
          return _furtherStepFailure(
            at: target,
            status: res.statusCode,
            property: property,
            body: body,
          );
        }

        current = target;
        continue;
      }

      if (res.statusCode != 200) {
        return Failure<Uri>.reason(
          FailureKind.server,
          statusCode: res.statusCode,
          endpoint: current.toString(),
          message: '${property.host} answered HTTP ${res.statusCode} while '
              'redeeming the ticket. Requests: ${chain.join(" | ")}',
        );
      }

      // A 200 only counts if the answer is neither a sign-in wall nor the central
      // service itself. Which host answered has to be named, because "the property
      // answered its sign-in page" and "the central service is asking for another
      // step" are different problems with different fixes — and an earlier version
      // blamed the property for a page CAS had served.
      final body = _utf8(res);
      if (current.host == _casHost) {
        return _furtherStepFailure(
          at: current,
          status: res.statusCode,
          property: property,
          body: body,
        );
      }

      if (looksLikeSignInPage(body)) {
        failurePageUrl = current.toString();
        failurePageBody = body;
        return Failure<Uri>.reason(
          FailureKind.unauthorized,
          statusCode: 200,
          endpoint: current.toString(),
          message: '${current.host} answered its sign-in page instead of '
              'accepting the ticket, so no session was established on '
              '${property.host}. Requests: ${chain.join(" | ")}',
        );
      }
      return Success(current);
    }

    return Failure<Uri>.reason(
      FailureKind.protocol,
      message: 'Gave up after $_maxHops redirects while redeeming the ticket.',
    );
  }

  /// Turns the jar into the session the rest of the app expects.
  Result<WhuSession> _sessionFrom(WhuProperty property) {
    // The flattened view is used only to answer "is a grant present at all".
    // The session is built from the scoped records instead, because flattening
    // has already lost which host each cookie belongs to.
    final kept = filterCookies(_jar.all, property);
    final grant = requireGrant(kept, property);
    if (grant.isFailure) {
      return Failure<WhuSession>.reason(
        grant.errorOrNull!.kind,
        message: '${grant.errorOrNull!.message} '
            'Cookies held: ${_jar.names.join(", ")}.',
      );
    }

    final scoped = scopeCookies(_jar.all, property);
    _note('session established: ${scoped.length} cookies for '
        '${scoped.map((c) => c.domain).toSet().join(", ")}');

    return Success(WhuSession(
      cookies: grant.requireValue,
      scoped: scoped,
      acquiredAt: DateTime.now(),
      handshake: List.unmodifiable(chain),
      properties: {property},
    ));
  }

  /// One request, with the jar's cookies attached and the response's absorbed.
  ///
  /// Redirects are **not** followed by the client: the chain is the sign-in, and
  /// the whole reason [CasCookieJar] exists is that each hop sets the cookie the
  /// next one needs.
  Future<http.Response> _send(
    Uri url, {
    String method = 'GET',
    Map<String, String>? form,
  }) async {
    final request = http.Request(method, url)
      ..followRedirects = false
      ..headers['User-Agent'] = _userAgent
      ..headers['Accept'] = 'text/html,application/xhtml+xml';

    final cookie = _jar.headerFor(url);
    if (cookie != null) request.headers['Cookie'] = cookie;

    if (form != null) {
      request.headers['Content-Type'] =
          'application/x-www-form-urlencoded; charset=utf-8';
      request.body = Uri(queryParameters: form).query;
    }

    final http.StreamedResponse streamed;
    try {
      streamed = await _http.send(request).timeout(_timeout);
    } on TimeoutException {
      throw _TransportError('timed out', url: url, timedOut: true);
    } on http.ClientException catch (e) {
      throw _TransportError(e.message, url: url);
    }

    final response = await http.Response.fromStream(streamed);
    _jar.absorb(url, _setCookieHeaders(response));

    // Recorded in two places on purpose. `chain` travels on the session and is
    // read by later screens; the note reaches the panel that is on screen *now*.
    // That second copy is the one that matters when the sign-in itself is what
    // failed: there is no session, so there is nothing to carry the chain.
    final hop = _describeHop(method, url, response);
    chain.add(hop);
    _note(hop);

    return response;
  }

  /// One hop, as a line safe to display.
  static String _describeHop(String method, Uri url, http.Response r) {
    final set = _setCookieNames(r);
    final location = r.headers['location'];
    return [
      '$method ${url.host}${url.path}',
      '→ ${r.statusCode}',
      if (location != null && location.isNotEmpty)
        '→ ${_redactTicket(location)}',
      if (set.isNotEmpty) '[set: $set]',
    ].join(' ');
  }

  /// A URL with any single-sign-on ticket removed.
  ///
  /// The redirect after a successful sign-in carries `?ticket=ST-…`, which **is**
  /// a credential: it is exchanged on the service for a session. It must not be
  /// logged, displayed, or copied out of a diagnostics panel, so only the
  /// parameter name survives.
  static String _redactTicket(String url) =>
      url.replaceAll(RegExp('ticket=[^&]*', caseSensitive: false), 'ticket=…');

  /// The **names** of the cookies a response set.
  ///
  /// Names are safe and are the single most useful thing to see when a handshake
  /// goes wrong; values are sessions and never appear.
  static String _setCookieNames(http.Response r) => _setCookieHeaders(r)
      .map((h) => h.split(';').first.split('=').first.trim())
      .where((n) => n.isNotEmpty)
      .join(',');

  /// `Set-Cookie` as separate headers.
  ///
  /// Not `response.headers['set-cookie']`: that value is joined, and a joined
  /// pair of `Set-Cookie` headers is ambiguous because an `Expires` attribute
  /// itself contains a comma. Splitting it would silently mangle expiry.
  static List<String> _setCookieHeaders(http.BaseResponse response) =>
      response.headersSplitValues['set-cookie'] ?? const <String>[];

  /// Decodes a body as UTF-8 regardless of what the `Content-Type` claims.
  ///
  /// `package:http` falls back to latin1 when a header carries no charset, which
  /// turns every Chinese message on the page into mojibake — and the message is
  /// the one thing worth reading here.
  static String _utf8(http.Response response) =>
      utf8.decode(response.bodyBytes, allowMalformed: true);

  /// The service's own explanation, pulled out of the re-rendered form.
  ///
  /// The live markup, transcribed, is **nested** — the sentence sits one element
  /// inside the slot that is named:
  ///
  /// ```html
  /// <div id="formErrorTip" class="formErrorTip lang_text_ellipsis">
  ///   <span id="showErrorTip" class="form-error">
  ///     <span>该账号非常用账号或用户名密码有误</span>
  ///   </span>
  ///   <span id="showWarnTip" class="form-warn"></span>
  /// </div>
  /// ```
  ///
  /// Three things about that shape are ways to be right by accident and then
  /// break, so they are spelled out:
  ///
  ///   * **Inner tags have to be stripped.** Taking the text immediately after
  ///     the opening tag yields the empty string, not the sentence.
  ///   * **The ids repeat.** The page carries `#showErrorTip` and `#formErrorTip`
  ///     twice each — once for the password form, once in the mobile layout — and
  ///     both copies hold the same sentence, so the first match is as good as any.
  ///     `#showWarnTip` is the slot that is genuinely empty on a refusal.
  ///   * **Entities appear between the spans.** A literal `&nbsp;` sits after the
  ///     closing tag, and leaving it undecoded would prepend noise to the message
  ///     if the sentence were ever empty and the next slot were read instead.
  static String? _serverMessage(String html) {
    for (final id in const ['showErrorTip', 'showWarnTip', 'formErrorTip']) {
      final match = RegExp(
        'id\\s*=\\s*"$id"[^>]*>([\\s\\S]{0,400}?)</',
        caseSensitive: false,
      ).firstMatch(html);
      if (match == null) continue;
      final text = _plainText(match.group(1)!);
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  /// Tag-stripped, entity-decoded, whitespace-collapsed text.
  static String _plainText(String html) => html
      .replaceAll(RegExp('<[^>]*>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      // `&amp;` last, so `&amp;lt;` does not turn into `<`.
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Wording the page itself uses when it wants a verification step.
  ///
  /// Taken from the live document's own language strings rather than invented:
  /// it contains `请输入验证码`, `验证码错误`, `图形验证码` and `滑块验证码`.
  static final RegExp _challengeWording = RegExp(
    r'验证码|滑块|图形验证|verification code|slider',
    caseSensitive: false,
  );

  /// Whether a refusal is asking for a verification step rather than naming the
  /// credentials.
  ///
  /// Deliberately wording-based, and deliberately allowed to miss. Nothing
  /// structural is inferred, because the shape of a challenge demand on this
  /// deployment was never observed — the pre-flight probe that was supposed to
  /// produce one flaps (see the class docs), so the server could not be made to
  /// ask reliably enough to capture the page.
  ///
  /// A miss is harmless: the refusal is then reported under `unauthorized` with
  /// the server's own sentence, which is what a browser would have shown.
  static bool _asksForChallenge(String message) =>
      _challengeWording.hasMatch(message);

  static Failure<T> _transportFailure<T>(_TransportError e) =>
      Failure<T>.reason(
        e.timedOut ? FailureKind.timeout : FailureKind.network,
        endpoint: e.url?.toString(),
        message: e.timedOut
            ? 'The authentication service did not answer in time.'
            : 'Could not reach the authentication service: ${e.reason}',
      );

  static Failure<T> _challengeFailure<T>(
    CasCaptchaMode mode, {
    String? serverMessage,
  }) {
    final explanation = switch (mode) {
      CasCaptchaMode.slider =>
        'The service is asking for a slider verification, which this client '
            'cannot present. Signing in once at cas.whu.edu.cn in a browser '
            'usually clears it; if it keeps coming back, the account is flagged '
            'rather than this device.',
      CasCaptchaMode.text =>
        'The service is asking for an image verification code. Enter it and '
            'try again.',
      CasCaptchaMode.unknown =>
        'The service is asking for a verification step this client does not '
            'recognise.',
    };

    // The server's own sentence is the whole message when it gave one. Phrasing
    // advice belongs to the caller, which is the only layer that knows the
    // reader's language and whether the challenge can be answered in place.
    return Failure<T>.reason(
      FailureKind.challengeRequired,
      message: serverMessage == null || serverMessage.isEmpty
          ? explanation
          : serverMessage,
    );
  }

  /// The server's `{"isNeed": ...}` shorthand, without the ceremony of a type.
  static CasChallengeVerdict _verdictFrom(String body) {
    final parsed = parseChallengeState(body);
    return switch (parsed) {
      CasChallengeState.required => CasChallengeVerdict.required,
      CasChallengeState.notRequired => CasChallengeVerdict.notRequired,
      CasChallengeState.unknown => CasChallengeVerdict.unknown,
    };
  }

  static const Duration _timeout = Duration(seconds: 30);

  void _note(String message) => onDiagnostic?.call(message);

  /// Releases the underlying HTTP client.
  void close() => _http.close();
}

/// What the server said about challenges.
enum CasChallengeVerdict { required, notRequired, unknown }

/// A network-level failure, kept separate from [AppFailure] so the retry
/// decision is made in one place.
class _TransportError implements Exception {
  _TransportError(this.reason, {this.url, this.timedOut = false});

  final String reason;
  final Uri? url;
  final bool timedOut;

  @override
  String toString() => '_TransportError($reason on $url)';
}
