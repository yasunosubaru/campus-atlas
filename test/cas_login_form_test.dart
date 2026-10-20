import 'package:campus_atlas/features/whu_auth/cas_login_form.dart';
import 'package:flutter_test/flutter_test.dart';

/// The fixture is deliberately **adversarial, not realistic**.
///
/// On the real page all three forms happen to carry `execution="e1s1"`, so a
/// parser that searches the document instead of the password form looks correct
/// on it and breaks the day they disagree. The fixture below gives the QR form a
/// *different* execution, so that mistake fails here instead of in production.
///
/// The rest of the shape — overlapping forms, `pwdEncryptSalt` carrying an `id`
/// but no `name`, `captchaSwitch` living in a script block — is transcribed from
/// the live page.
const String _page = '''
<!DOCTYPE html>
<html><head><title>统一身份认证平台</title></head><body>
<div class="login-main">
  <form class="loginFromClass" method="post" id="qrLoginForm" action="/authserver/login">
    <input type="hidden" name="lt" id="lt" value="" />
    <input type="hidden" name="cllt" value="qrLogin" />
    <input type="hidden" name="execution" value="e9s9" />
    <input type="hidden" name="_eventId" value="submit" />
  </form>
  <form class="loginFromClass" method="post" id="pwdFromId" action="/authserver/login">
    <input id="username" name="username" type="text" value="">
    <input id="password" name="passwordText" type="password" readonly maxlength="32">
    <input id="saltPassword" name="password" type="hidden">
    <input id="captcha" name="captcha" type="text" maxlength="10">
    <input type="hidden" id="_eventId" name="_eventId" value="submit" />
    <input type="hidden" id="cllt" name="cllt" value="userNameLogin" />
    <input type="hidden" id="dllt" name="dllt" value="generalLogin" />
    <input type="hidden" id="lt" name="lt" value="" />
    <input type="hidden" id="pwdEncryptSalt" value="dYuZ3fFS2uIolipS" />
    <input type="hidden" id="execution" name="execution" value="e1s1" />
  </form>
  <form class="loginFromClass" method="post" id="phoneFromId" action="/authserver/login">
    <input type="hidden" id="cllt" name="cllt" value="dynamicLogin" />
    <input type="hidden" name="execution" value="e7s7" />
  </form>
</div>
<script type="text/javascript">
  var captchaSwitch = "2";
  var needCaptcha = "";
</script>
</body></html>
''';

void main() {
  group('reading the password form', () {
    final form = CasLoginForm.parse(_page).requireValue;

    test('execution comes from #pwdFromId, not from the first form on the page',
        () {
      // The trap this file exists for: qrLoginForm carries `e9s9` and appears
      // first, so a document-wide search returns the wrong conversation token.
      expect(form.execution, 'e1s1');
      expect(form.execution, isNot('e9s9'));
      expect(form.execution, isNot('e7s7'));
    });

    test('the salt is read by id, even though it has no name', () {
      // It is never submitted — but treating "no name attribute" as "absent"
      // would leave the salt empty and silently send the password in the clear.
      expect(form.salt, 'dYuZ3fFS2uIolipS');
      expect(form.passwordIsEncrypted, isTrue);
    });

    test('the mode flags are read from the password form', () {
      expect(form.cllt, 'userNameLogin');
      expect(form.dllt, 'generalLogin');
      expect(form.lt, '');
      expect(form.eventId, 'submit');
    });

    test('the salt is not among the fields that are submitted', () {
      expect(form.fixedFields.containsKey('pwdEncryptSalt'), isFalse);
      expect(
          form.fixedFields.keys,
          containsAll(<String>[
            '_eventId',
            'cllt',
            'dllt',
            'lt',
            'execution',
          ]));
    });

    test('the page-level captchaSwitch is read from the script', () {
      expect(form.captchaSwitch, '2');
      // "2" is the slider. Reading it as "no challenge" would be wrong: it means
      // "a challenge may be raised, and it will be a drag-the-piece one".
      expect(form.captchaMode, CasCaptchaMode.slider);
    });

    test('toString reports sizes, never the salt itself', () {
      expect(form.toString(), contains('16 chars'));
      expect(form.toString(), isNot(contains('dYuZ3fFS2uIolipS')));
    });
  });

  group('captchaSwitch values', () {
    CasCaptchaMode modeFor(String switchValue) => CasLoginForm.parse(
          '<form id="pwdFromId"><input name="execution" value="e1s1" />'
          '<input id="pwdEncryptSalt" value="0123456789abcdef" /></form>'
          '<script>var captchaSwitch = "$switchValue";</script>',
        ).requireValue.captchaMode;

    test('"1" is the text CAPTCHA',
        () => expect(modeFor('1'), CasCaptchaMode.text));
    test(
        '"2" is the slider', () => expect(modeFor('2'), CasCaptchaMode.slider));
    test('anything else, including absent, is unknown rather than "none"', () {
      expect(modeFor('3'), CasCaptchaMode.unknown);
      expect(modeFor(''), CasCaptchaMode.unknown);
    });
  });

  group('refusing a page that is not the sign-in form', () {
    test('no #pwdFromId form is a parse failure, not a half-filled form', () {
      final result = CasLoginForm.parse('<html><body>503 Service Unavailable'
          '</body></html>');

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull!.kind.name, 'invalidData');
      expect(result.errorOrNull!.message, contains('pwdFromId'));
    });

    test('a form with no execution value is refused', () {
      // Without it the server will not accept the submission, so sending one
      // would produce an unrelated error message much harder to diagnose.
      final result = CasLoginForm.parse(
        '<form id="pwdFromId"><input name="execution" value="" />'
        '<input id="pwdEncryptSalt" value="0123456789abcdef" /></form>',
      );

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull!.message, contains('execution'));
    });

    test('a form with no inputs at all is refused', () {
      final result = CasLoginForm.parse('<form id="pwdFromId"></form>');
      expect(result.isFailure, isTrue);
    });

    test('an unterminated form is refused rather than swallowing the page', () {
      final result = CasLoginForm.parse(
        '<form id="pwdFromId"><input name="execution" value="e1s1">',
      );
      expect(result.isFailure, isTrue);
    });
  });

  group('attribute spellings', () {
    test('single quotes, double quotes and no quotes are all read', () {
      for (final quote in const ['"', "'", '']) {
        final html = '<form id="pwdFromId">'
            "<input name='execution' value=${quote}e1s1$quote />"
            "<input id='pwdEncryptSalt' value=${quote}0123456789abcdef$quote />"
            '</form>';
        final form = CasLoginForm.parse(html);

        expect(form.isFailure, isFalse, reason: 'quote style $quote');
        expect(form.requireValue.execution, 'e1s1',
            reason: 'quote style $quote');
        expect(form.requireValue.salt, '0123456789abcdef',
            reason: 'quote style $quote');
      }
    });

    test('attribute order does not matter', () {
      final form = CasLoginForm.parse(
        '<form id="pwdFromId">'
        '<input value="e1s1" name="execution" type="hidden" id="execution">'
        '<input value="0123456789abcdef" id="pwdEncryptSalt">'
        '</form>',
      ).requireValue;

      expect(form.execution, 'e1s1');
      expect(form.salt, '0123456789abcdef');
    });

    test('a missing salt is reported, not assumed away', () {
      // Tolerated, because a deployment that stopped encrypting would look like
      // this — but `passwordIsEncrypted` is what the client checks before it
      // sends anything, so the difference is visible.
      final form = CasLoginForm.parse(
        '<form id="pwdFromId"><input name="execution" value="e1s1"></form>',
      ).requireValue;

      expect(form.salt, '');
      expect(form.passwordIsEncrypted, isFalse);
    });
  });
}
