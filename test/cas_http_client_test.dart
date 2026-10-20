import 'dart:convert';

import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/features/whu_auth/cas_http_client.dart';
import 'package:campus_atlas/features/whu_auth/cas_login_form.dart';
import 'package:campus_atlas/features/whu_auth/whu_endpoints.dart';
import 'package:campus_atlas/features/whu_auth/whu_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The sign-in form, shaped like the live one: `pwdEncryptSalt` carries an `id`
/// and no `name`, and `captchaSwitch` lives in a script block.
const String _loginPage = '''
<!DOCTYPE html>
<html><head><title>统一身份认证平台</title></head><body>
<div class="login-main">
  <form class="loginFromClass" method="post" id="pwdFromId" action="/authserver/login">
    <input id="username" name="username" type="text" value="">
    <input id="password" name="passwordText" type="password" readonly>
    <input id="saltPassword" name="password" type="hidden">
    <input type="hidden" id="_eventId" name="_eventId" value="submit" />
    <input type="hidden" id="cllt" name="cllt" value="userNameLogin" />
    <input type="hidden" id="dllt" name="dllt" value="generalLogin" />
    <input type="hidden" id="lt" name="lt" value="" />
    <input type="hidden" id="pwdEncryptSalt" value="0123456789abcdef" />
    <input type="hidden" id="execution" name="execution" value="e1s1" />
  </form>
</div>
<script type="text/javascript">var captchaSwitch = "2";</script>
</body></html>
''';

/// A rejection page, transcribed from the live one.
///
/// Three properties of the real markup are load-bearing here, so the fixture
/// reproduces all three rather than a tidied version:
///
///   * the sentence is **nested one element inside** `#showErrorTip`, so anything
///     that reads the text immediately after the opening tag finds nothing;
///   * `#showErrorTip` appears **twice** — once bare in the QR form, once inside
///     the password form — so an implementation that assumes a unique id is being
///     tested rather than accommodated;
///   * a literal `&nbsp;` sits between the two spans.
String _rejection(String sentence) => '''
<!DOCTYPE html>
<html><body>
<div class="login-main">
  <form class="loginFromClass" method="post" id="qrLoginForm" action="/authserver/login">
    <span id="showErrorTip"><span>$sentence</span></span>
  </form>
  <form class="loginFromClass" method="post" id="pwdFromId" action="/authserver/login">
    <input id="username" name="username" type="text" value="0000000000">
    <input id="saltPassword" name="password" type="hidden">
    <input type="hidden" id="execution" name="execution" value="e1s2" />
    <span id="showErrorTip" class="form-error"><span>$sentence</span></span>
    <span id="showWarnTip" class="form-warn"></span>&nbsp;
  </form>
</div>
</body></html>
''';

/// What the service says when a password is simply wrong.
const String _credentialRefusal = '该账号非常用账号或用户名密码有误';

/// A stand-in for the authentication service.
///
/// It answers exactly the three requests the client makes, so a test can assert
/// on *what was sent* as well as what came back.
class _FakeCas {
  _FakeCas({
    this.challenge = '{"isNeed":false}',
    this.refusal,
    this.refuseStatus = 401,
  });

  /// The body `checkNeedCaptcha.htl` answers with.
  final String challenge;

  /// The rejection page, or null to accept the sign-in.
  final String? refusal;

  /// This service answers 401; the parameter exists because others answer 200 and
  /// the client must treat the two identically.
  final int refuseStatus;

  final List<http.Request> seen = [];
  int challengeCalls = 0;
  int postCalls = 0;

  http.Client get client => MockClient(_handle);

  http.Request get post => seen.firstWhere((r) => r.method == 'POST');

  Map<String, String> get postedFields =>
      Uri.splitQueryString(post.body, encoding: utf8);

  /// The CAS URL this property hands back.
  ///
  /// Deliberately **not** equal to [JwglOrigin.casService]: it carries a
  /// `ydtype=0` query the constant knows nothing about, which is exactly the kind
  /// of difference a client that posts its own hard-coded URL cannot survive. The
  /// live property does the same thing on its front door — `GET /` answers
  /// `302 → /sso/jznewsixlogin?ydtype=0`.
  static const String casUrlFromProperty = '${JwglOrigin.casService}?ydtype=0';

  Future<http.Response> _handle(http.Request request) async {
    seen.add(request);
    switch (request.url.path) {
      case '/authserver/login':
        if (request.method != 'POST') return _formPage();
        postCalls++;
        if (refusal != null) return _html(refusal!, refuseStatus);
        return http.Response('', 302, headers: {
          // The grant, scoped to the context path the server really uses, and a
          // ticket in the redirect — which is what makes the next hop mean
          // anything.
          'set-cookie': 'CASTGC=ST-1-abc; Path=/authserver',
          'location': '${JwglOrigin.casService}?ticket=ST-1-abc',
        });
      case '/authserver/checkNeedCaptcha.htl':
        challengeCalls++;
        return _html(challenge, 200);
      case '/':
        // The property's front door. Its session cookie is set *here*, before any
        // ticket exists — which is the whole reason the client walks through it.
        return http.Response('', 302, headers: {
          'set-cookie': 'JSESSIONID=jwgl-pre; Path=/',
          'location': '${JwglOrigin.root}/sso/jznewsixlogin?ydtype=0',
        });
      case '/sso/jznewsixlogin':
        if (request.url.queryParameters.containsKey('ticket')) {
          // Redeeming: the property accepts the ticket and establishes its own
          // session.
          return http.Response('<html>jwgl home</html>', 200, headers: {
            'content-type': 'text/html; charset=utf-8',
            'set-cookie': 'JSESSIONID=svc-1; Path=/',
          });
        }
        // No ticket yet: the property asks CAS for one, on its own terms.
        return http.Response('', 302, headers: {
          'location': '${CasOrigin.login}'
              '${Uri.encodeComponent(casUrlFromProperty)}',
        });
      default:
        return http.Response('<html>jwgl</html>', 200, headers: {
          'content-type': 'text/html; charset=utf-8',
          'set-cookie': 'JSESSIONID=svc-1; Path=/',
        });
    }
  }

  /// UTF-8 on purpose. `http.Response` encodes as latin1 when the content type
  /// carries no charset, which would mangle every Chinese sentence — the one
  /// thing these tests are about.
  static http.Response _html(String body, int status) => http.Response(
        body,
        status,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );

  /// The form page, carrying the cookies the real one sets.
  ///
  /// All four properties matter downstream, so the fixture has all four rather
  /// than a convenient subset: a host-wide `route`, a context-scoped
  /// `JSESSIONID`, a **clearing** `CASTGC`, and an `Expires` whose value contains
  /// a comma. That last one is the reason a `Set-Cookie` header is never split on
  /// commas naively — splitting it mangles the date and leaves a stale grant in
  /// the jar.
  static http.Response _formPage() => http.Response(_loginPage, 200, headers: {
        'content-type': 'text/html; charset=utf-8',
        'set-cookie': 'route=node1; Path=/, '
            'JSESSIONID=cas-1; Path=/authserver/, '
            'CASTGC=; Expires=Thu, 01 Jan 1970 00:00:10 GMT; Path=/authserver/',
      });
}

void main() {
  Future<Result<WhuSession>> signIn(
    _FakeCas cas, {
    String captcha = '',
    List<String>? notes,
  }) async {
    final client = CasHttpClient(
      httpClient: cas.client,
      onDiagnostic: notes?.add,
    );
    return client.signIn(
      property: WhuProperty.jwgl,
      username: '0000000000',
      password: 'hunter2-not-real',
      captcha: captcha.isEmpty ? null : captcha,
    );
  }

  group('a demand for a further step at the central service', () {
    /// A transport whose CAS answers the password with a re-authentication
    /// demand.
    ///
    /// This is the measured shape, not an invention: the live service answered
    /// `302 → /authserver/reAuthCheck/reAuthLoginView.do?isMultifactor=true`.
    http.Client demandingMore(_FakeCas cas) => MockClient((request) async {
          if (request.url.path == '/authserver/login' &&
              request.method == 'POST') {
            return http.Response('', 302, headers: {
              'set-cookie': 'CASTGC=ST-1-abc; Path=/authserver',
              'location': '${CasOrigin.authserverRoot}'
                  'reAuthCheck/reAuthLoginView.do?isMultifactor=true',
            });
          }
          if (request.url.path ==
              '/authserver/reAuthCheck/reAuthLoginView.do') {
            return http.Response(
              '<html><body><p>需要进行二次认证</p></body></html>',
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            );
          }
          return cas._handle(request);
        });

    Future<Result<WhuSession>> attempt(
      CasHttpClient client,
    ) =>
        client.signIn(
          property: WhuProperty.jwgl,
          username: '0000000000',
          password: 'not-real',
        );

    test(
        'is reported as the central service asking, not as the property failing',
        () async {
      // The wording matters. The property never receives a ticket, so it answers
      // its own login page — and reporting *that* sends the reader to look at 教务,
      // which is behaving correctly, instead of at the step that is missing.
      final client = CasHttpClient(httpClient: demandingMore(_FakeCas()));

      final r = await attempt(client);

      expect(r.isFailure, isTrue);
      expect(r.errorOrNull?.kind, FailureKind.challengeRequired);
      expect(r.errorOrNull?.message, contains('central service'));
      // The property is named only as the destination that is waiting for a
      // ticket. It must not be described as the thing that *answered* — it behaves
      // correctly throughout, and blaming it is what sent the reader to the wrong
      // system.
      expect(
          r.errorOrNull?.message, isNot(contains('jwgl.whu.edu.cn answered')));
      expect(r.errorOrNull?.message, isNot(contains('sign-in page')));
    });

    test('keeps the page that asked, because the page says what is wanted',
        () async {
      final client = CasHttpClient(httpClient: demandingMore(_FakeCas()));

      await attempt(client);

      expect(client.failurePageUrl, contains('reAuthLoginView.do'));
      expect(client.failurePageBody, contains('二次认证'));
    });

    test('the demand is visible in the hop log', () async {
      final notes = <String>[];
      final client = CasHttpClient(
        httpClient: demandingMore(_FakeCas()),
        onDiagnostic: notes.add,
      );

      await attempt(client);

      final joined = notes.join('\n');
      expect(joined, contains('reAuthLoginView.do'));
      expect(joined, contains('further step'));
    });

    test('a password refusal is still a refusal, not a challenge', () async {
      // The distinction has to survive: a wrong password re-renders the form and
      // says so, and must not be dressed up as a multi-factor demand.
      final cas = _FakeCas(refusal: _rejection(_credentialRefusal));
      final r = await signIn(cas);

      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
    });
  });

  group('the walk to the sign-in form', () {
    // The measured failure this group exists for: the client used to go straight
    // to CAS. CAS accepted the password and issued a ticket — the log reached
    // "accepted; redeeming the ticket" — and 教务 then failed to redeem it,
    // because it had never been visited and so held no session of its own to
    // attach the returning ticket to. A browser always visits the property first;
    // that visit is what puts the cookie there.

    test('visits the property before the central service', () async {
      final cas = _FakeCas();
      final r = await signIn(cas);

      expect(r.isSuccess, isTrue);
      final hosts = cas.seen.map((q) => q.url.host).toList();
      expect(hosts.first, 'jwgl.whu.edu.cn',
          reason: 'the property has to be reached before CAS');
      expect(hosts.indexOf('cas.whu.edu.cn'), greaterThan(0));
    });

    test('still holds the property session when the ticket comes back',
        () async {
      // The point of the walk, asserted rather than assumed: the cookie set at
      // the front door is still held on the redeem hop, so the property
      // recognises the session the ticket is being redeemed into. Without it the
      // property has no session of its own, which is the failure being fixed.
      final cas = _FakeCas();
      await signIn(cas);

      final redeem = cas.seen.lastWhere((q) => q.url.host == 'jwgl.whu.edu.cn');
      expect(redeem.url.queryParameters['ticket'], isNotEmpty);
      expect(redeem.headers['cookie'], contains('JSESSIONID=jwgl-pre'));
    });

    test('the property session is never sent to the central service', () async {
      final cas = _FakeCas();
      await signIn(cas);

      final toCas = cas.seen.firstWhere((q) => q.url.host == 'cas.whu.edu.cn');
      expect(toCas.headers['cookie'] ?? '', isNot(contains('jwgl-pre')));
    });

    test('uses the CAS URL the property asked for, not its own constant',
        () async {
      final cas = _FakeCas();
      await signIn(cas);

      final form = cas.seen.firstWhere(
          (q) => q.url.path == '/authserver/login' && q.method == 'GET');
      // A ticket is bound to the exact service string the property asked for, so
      // posting with a constant recovered from a binary is a mismatch waiting to
      // happen. The fixture's value carries a `ydtype=0` the constant lacks.
      expect(form.url.queryParameters['service'], _FakeCas.casUrlFromProperty);
    });

    test(
        'a property that answers a page instead of asking for a sign-in says so',
        () async {
      // Reachable when the property decides the caller is already satisfied, or
      // when the entry has been pointed at something that is not a sign-in entry
      // at all. Parsing a form out of an arbitrary page would produce a confusing
      // failure much further along.
      final cas = _FakeCas();
      final client = CasHttpClient(
        httpClient: MockClient((request) async {
          if (request.url.host == 'jwgl.whu.edu.cn') {
            return http.Response('<html>welcome</html>', 200, headers: {
              'content-type': 'text/html; charset=utf-8',
            });
          }
          return cas._handle(request);
        }),
      );

      final r = await client.signIn(
        property: WhuProperty.jwgl,
        username: '0000000000',
        password: 'not-real',
      );

      expect(r.isFailure, isTrue);
      expect(
          r.errorOrNull?.message, contains('instead of asking for a sign-in'));
    });
  });

  group('the challenge probe is recorded, never obeyed', () {
    // This is the regression the whole file exists for. An earlier version
    // returned `challengeRequired` without submitting when the probe said yes.
    // The verdict was then measured against the live service and found to flip
    // for the same account within minutes — and a sweep of five numbers found no
    // `true` at all — so the flag does not predict that a submission would be
    // refused. Refusing on it turned working sign-ins into dead ends.
    test('a positive verdict does not stop the submission', () async {
      final cas = _FakeCas(
        challenge: '{"isNeed":true}',
        refusal: _rejection(_credentialRefusal),
      );
      final r = await signIn(cas);

      expect(cas.postCalls, 1,
          reason: 'the submission must happen even though the probe said yes');
      expect(r.errorOrNull?.kind, FailureKind.unauthorized,
          reason: 'the answer is the credentials verdict, not a challenge');
      expect(r.errorOrNull?.message, _credentialRefusal);
    });

    test('the verdict is still asked for, so diagnostics can show it',
        () async {
      final notes = <String>[];
      final cas = _FakeCas(
        challenge: '{"isNeed":true}',
        refusal: _rejection(_credentialRefusal),
      );
      await signIn(cas, notes: notes);

      expect(cas.challengeCalls, 1);
      expect(notes.any((n) => n.contains('{"isNeed":true}')), isTrue);
      expect(
        notes.any((n) => n.contains('not reliable')),
        isTrue,
        reason: 'the note should say why a positive verdict was not acted on',
      );
    });

    test('a negative verdict changes nothing either', () async {
      final cas = _FakeCas(refusal: _rejection(_credentialRefusal));
      final r = await signIn(cas);

      expect(cas.postCalls, 1);
      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
    });

    test('an unreadable verdict does not break the sign-in', () async {
      final cas = _FakeCas(challenge: '<html>gateway error</html>');
      final r = await signIn(cas);

      expect(cas.postCalls, 1);
      expect(r.isSuccess, isTrue);
    });

    test('an unreachable probe does not break the sign-in', () async {
      final cas = _FakeCas();
      final client = CasHttpClient(
        httpClient: MockClient((request) async {
          if (request.url.path == '/authserver/checkNeedCaptcha.htl') {
            throw http.ClientException('connection reset', request.url);
          }
          return cas._handle(request);
        }),
      );

      final r = await client.signIn(
        property: WhuProperty.jwgl,
        username: '0000000000',
        password: 'not-real',
      );

      expect(r.isSuccess, isTrue,
          reason: 'the probe is an optimisation; losing it must not lose the '
              'sign-in');
      expect(cas.postCalls, 1);
    });
  });

  group("the server's own words are quoted", () {
    test('a nested sentence is extracted from the rejection page', () async {
      final cas = _FakeCas(refusal: _rejection(_credentialRefusal));
      final r = await signIn(cas);

      // The failure of a naive reader is the empty string, not a wrong sentence,
      // because the text sits inside a further element.
      expect(r.errorOrNull?.message, _credentialRefusal);
    });

    test('the duplicated id does not produce an empty read', () async {
      // The first `#showErrorTip` on the page is the bare one in the QR form.
      // Both hold the sentence, so either is acceptable — an empty result is not.
      final cas = _FakeCas(refusal: _rejection('验证码错误'));
      final r = await signIn(cas);

      expect(r.errorOrNull?.message, isNotEmpty);
      expect(r.errorOrNull?.message, '验证码错误');
    });

    test('an entity is decoded rather than pasted in front of the sentence',
        () async {
      final cas = _FakeCas(
        refusal: '<div id="formErrorTip"><span id="showErrorTip"></span>'
            '&nbsp;<span id="showWarnTip"><span>只用一句</span></span></div>',
      );
      final r = await signIn(cas);

      // `#showErrorTip` is genuinely empty here, so the reader moves on to
      // `#showWarnTip`. The `&nbsp;` between them must not survive into the text.
      expect(r.errorOrNull?.message, '只用一句');
    });

    test('a rejection page with no message at all still fails cleanly',
        () async {
      final cas = _FakeCas(
        refusal: '<html><body><form id="pwdFromId"></form></body></html>',
      );
      final r = await signIn(cas);

      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
      expect(r.errorOrNull?.message, isNotEmpty);
    });

    test('a 200 refusal is treated exactly like the 401 one', () async {
      const sentence = '该账号非常用账号或用户名密码有误';
      final as401 = await signIn(
        _FakeCas(refusal: _rejection(sentence), refuseStatus: 401),
      );
      final as200 = await signIn(
        _FakeCas(refusal: _rejection(sentence), refuseStatus: 200),
      );

      expect(as401.errorOrNull?.kind, as200.errorOrNull?.kind);
      expect(as401.errorOrNull?.message, as200.errorOrNull?.message);
    });
  });

  group('a refusal that asks for a verification step', () {
    test('is classified as a challenge, keeping the server sentence', () async {
      final cas = _FakeCas(refusal: _rejection('请输入验证码'));
      final r = await signIn(cas);

      expect(r.errorOrNull?.kind, FailureKind.challengeRequired);
      expect(r.errorOrNull?.message, '请输入验证码');
    });

    test('the slider wording is recognised too', () async {
      final cas = _FakeCas(refusal: _rejection('请完成滑块验证码'));
      final r = await signIn(cas);

      expect(r.errorOrNull?.kind, FailureKind.challengeRequired);
    });

    test('a credentials refusal is never mistaken for a challenge', () async {
      final cas = _FakeCas(refusal: _rejection(_credentialRefusal));
      final r = await signIn(cas);

      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
    });

    test('the page tells the caller which mode the deployment uses', () async {
      final cas = _FakeCas(refusal: _rejection('请输入验证码'));
      final client = CasHttpClient(httpClient: cas.client);
      await client.signIn(
        property: WhuProperty.jwgl,
        username: '0000000000',
        password: 'not-real',
      );

      // `captchaSwitch = "2"` in the fixture is the slider, so the caller must
      // not offer a code field it cannot fill.
      expect(client.captchaMode, CasCaptchaMode.slider);
    });

    test('the mode is known even when the page refuses no challenge', () async {
      final cas = _FakeCas();
      final client = CasHttpClient(httpClient: cas.client);
      await client.signIn(
        property: WhuProperty.jwgl,
        username: '0000000000',
        password: 'not-real',
      );

      expect(client.captchaMode, CasCaptchaMode.slider);
    });
  });

  group('what is actually sent', () {
    test('the form fields, and only the form fields', () async {
      final cas = _FakeCas();
      await signIn(cas);
      final fields = cas.postedFields;

      expect(fields['username'], '0000000000');
      expect(fields['_eventId'], 'submit');
      expect(fields['cllt'], 'userNameLogin');
      expect(fields['dllt'], 'generalLogin');
      expect(fields['lt'], '');
      expect(fields['execution'], 'e1s1');
    });

    test('the salt and the readonly field are not submitted', () async {
      final cas = _FakeCas();
      await signIn(cas);
      final fields = cas.postedFields;

      // `pwdEncryptSalt` has an id but no name, so the page never submits it.
      // `passwordText` is the visible field the page disables — submitting it
      // would send the password in the clear alongside the encrypted one.
      expect(fields.containsKey('pwdEncryptSalt'), isFalse);
      expect(fields.containsKey('passwordText'), isFalse);
      expect(fields.keys, contains('password'));
    });

    test('the password field is the encrypted one', () async {
      final cas = _FakeCas();
      await signIn(cas);
      final sent = cas.postedFields['password']!;

      expect(sent, isNot(contains('hunter2')));
      expect(base64.decode(sent), isNotEmpty);
    });

    test('the request goes to the bare action path, with no service query',
        () async {
      final cas = _FakeCas();
      await signIn(cas);
      final post = cas.post;

      expect(post.url.path, '/authserver/login');
      expect(post.url.hasQuery, isFalse,
          reason: 'the form action carries no query string');
    });

    test('a captcha rides along only when one was given', () async {
      final withoutCode = _FakeCas();
      await signIn(withoutCode);
      expect(withoutCode.postedFields.containsKey('captcha'), isFalse);

      final withCode = _FakeCas();
      await signIn(withCode, captcha: 'k7f3');
      expect(withCode.postedFields['captcha'], 'k7f3');
    });

    test('an empty captcha is not submitted as an empty field', () async {
      final cas = _FakeCas();
      await signIn(cas, captcha: '   ');
      expect(cas.postedFields.containsKey('captcha'), isFalse);
    });

    test('the CAS cookies ride on the submission, scoped to the context path',
        () async {
      final cas = _FakeCas();
      await signIn(cas);

      expect(cas.post.headers['cookie'], contains('JSESSIONID=cas-1'));
      expect(cas.post.headers['cookie'], contains('route=node1'));
      // The form page answers with a *clearing* header for the grant, and its
      // `Expires` contains a comma — the attribute that gets mangled when a
      // `Set-Cookie` header is split on commas without care. Nothing of it should
      // survive into the request.
      expect(cas.post.headers['cookie'], isNot(contains('CASTGC')));
    });

    test('the grant is never sent to the property host', () async {
      final cas = _FakeCas();
      await signIn(cas);
      final redeem = cas.seen.last;

      expect(redeem.url.host, 'jwgl.whu.edu.cn');
      // `CASTGC` is scoped to cas.whu.edu.cn/authserver. Handing a central
      // credential to a service host would be a real vulnerability rather than a
      // cosmetic scoping question, so it is asserted rather than assumed.
      expect(redeem.headers['cookie'] ?? '', isNot(contains('CASTGC')));
    });
  });

  group('a sign-in that works', () {
    test('yields a session holding the grant and the service session',
        () async {
      final cas = _FakeCas();
      final r = await signIn(cas);

      expect(r.isSuccess, isTrue);
      final session = r.requireValue;
      expect(session.cookies['CASTGC'], 'ST-1-abc');
      // Asserted through the header, not the flattened map. The map holds one
      // `JSESSIONID` because both hosts use that name, and after the walk the
      // property's is inserted first — so the map now keeps the CAS one. That is
      // the collision this whole change is about, and the header is where the
      // question "which cookie goes to which host" actually has an answer.
      expect(session.cookieHeaderFor(Uri.parse('https://jwgl.whu.edu.cn/x')),
          contains('JSESSIONID=svc-1'));
      // Asked at the path the CAS cookie is actually scoped to: `/authserver/`.
      // A cookie scoped there deliberately does not cover `/x`.
      expect(
        session
            .cookieHeaderFor(Uri.parse('https://cas.whu.edu.cn/authserver/x')),
        contains('JSESSIONID=cas-1'),
      );
    });

    test('the session sends the grant home and the session to 教务', () async {
      // The end-to-end version of the bug this change is for: the session used to
      // emit every cookie it held for every request, so 教务 received the central
      // credential and the two hosts' `JSESSIONID`s overwrote each other.
      final cas = _FakeCas();
      final r = await signIn(cas);
      final session = r.requireValue;

      final toJwgl =
          session.cookieHeaderFor(Uri.parse('https://jwgl.whu.edu.cn/xtgl/x'));
      final toCas = session
          .cookieHeaderFor(Uri.parse('https://cas.whu.edu.cn/authserver/x'));

      expect(toJwgl, contains('JSESSIONID=svc-1'));
      expect(toJwgl, isNot(contains('CASTGC')));
      expect(toCas, contains('CASTGC=ST-1-abc'));
      expect(toCas, isNot(contains('svc-1')));
    });

    test('the hops are recorded, with any ticket redacted', () async {
      final cas = _FakeCas();
      final r = await signIn(cas);
      final hops = r.requireValue.handshake;

      expect(hops, isNotEmpty);
      expect(
        hops.any((h) => h.contains('POST cas.whu.edu.cn/authserver/login')),
        isTrue,
      );
      // A `ticket=ST-...` is exchanged for a session, so it is a credential and
      // must not be readable in a panel people copy out of.
      expect(hops.join('\n'), isNot(contains('ticket=ST-')));
    });

    test('a redirect with no grant anywhere is not reported as signed in',
        () async {
      // The 302 arrives but nothing sets a grant. A session on the property alone
      // cannot be extended to another property, so calling it signed in would be
      // the exact bug `requireGrant` exists to prevent.
      final cas = _FakeCas();
      final client = CasHttpClient(
        httpClient: MockClient((request) async {
          if (request.url.path == '/authserver/login' &&
              request.method == 'POST') {
            // A real acceptance carries a ticket in the redirect. It is left out
            // of the *grant* separately: the point here is a handshake that
            // completes and still yields no ticket-granting cookie.
            return http.Response('', 302, headers: {
              'location': '${JwglOrigin.casService}?ticket=ST-1-abc',
            });
          }
          if (request.url.path == '/sso/jznewsixlogin' &&
              request.url.queryParameters.containsKey('ticket')) {
            return http.Response('ok', 200, headers: {
              'content-type': 'text/html; charset=utf-8',
              'set-cookie': 'JSESSIONID=svc-1; Path=/',
            });
          }
          return cas._handle(request);
        }),
      );

      final r = await client.signIn(
        property: WhuProperty.jwgl,
        username: '0000000000',
        password: 'not-real',
      );

      expect(r.isFailure, isTrue);
      expect(r.errorOrNull?.kind, FailureKind.unauthorized);
      expect(r.errorOrNull?.message, contains('CASTGC'));
    });
  });

  group('secrets stay out of the diagnostics', () {
    test('no password and no cookie value reaches a note', () async {
      final notes = <String>[];
      final cas = _FakeCas();
      await signIn(cas, notes: notes);

      final joined = notes.join('\n');
      expect(joined, isNot(contains('hunter2')));
      expect(joined, isNot(contains('ST-1-abc')));
      expect(joined, isNot(contains('svc-1')));
    });

    test('no password reaches a note on a refusal either', () async {
      final notes = <String>[];
      final cas = _FakeCas(refusal: _rejection(_credentialRefusal));
      await signIn(cas, notes: notes);

      expect(notes.join('\n'), isNot(contains('hunter2')));
    });

    test('the notes describe the form without printing the salt', () async {
      final notes = <String>[];
      final cas = _FakeCas();
      await signIn(cas, notes: notes);

      final formNote = notes.firstWhere((n) => n.startsWith('form:'));
      expect(formNote, contains('16 chars'));
      expect(formNote, isNot(contains('0123456789abcdef')));
    });
  });

  group('input the client refuses before sending', () {
    test('an empty student number never reaches the network', () async {
      final cas = _FakeCas();
      final client = CasHttpClient(httpClient: cas.client);
      final r = await client.signIn(
        property: WhuProperty.jwgl,
        username: '   ',
        password: 'not-real',
      );

      expect(r.errorOrNull?.kind, FailureKind.validation);
      expect(cas.seen, isEmpty);
    });

    test('an empty password never reaches the network', () async {
      final cas = _FakeCas();
      final client = CasHttpClient(httpClient: cas.client);
      final r = await client.signIn(
        property: WhuProperty.jwgl,
        username: '0000000000',
        password: '',
      );

      expect(r.errorOrNull?.kind, FailureKind.validation);
      expect(cas.seen, isEmpty);
    });

    test('a property with no service target is refused, not guessed', () async {
      final cas = _FakeCas();
      final client = CasHttpClient(httpClient: cas.client);
      final r = await client.signIn(
        property: WhuProperty.librarySeat,
        username: '0000000000',
        password: 'not-real',
      );

      expect(r.errorOrNull?.kind, FailureKind.validation);
      expect(cas.seen, isEmpty);
    });
  });
}
