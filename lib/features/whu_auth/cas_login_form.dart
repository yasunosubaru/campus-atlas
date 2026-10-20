/// Reading the sign-in form's own server-issued state out of the page.
///
/// ## Why this exists
///
/// The form carries three values the server will check on the way back —
/// `execution`, `lt` and the per-page `pwdEncryptSalt` — plus two hidden mode
/// flags. None of them is stable, and none of them can be hardcoded: `execution`
/// in particular is a conversation identifier, so a value captured once is a
/// value that stops working. They have to be read from the page that is actually
/// going to be submitted.
///
/// ## What the page actually contains
///
/// Captured from `https://cas.whu.edu.cn/authserver/login?service=...` (44 442 B)
/// and verified field by field. There are **three** forms on the page — QR,
/// FIDO and password — and they overlap: `execution` appears in more than one, so
/// a document-wide search returns an input belonging to some *other* sign-in
/// method. All three happened to carry `e1s1` on the captured page, which is
/// exactly the kind of coincidence that makes a document-wide search look
/// correct until the day one of them differs.
///
/// This therefore scopes every lookup to the password form, `#pwdFromId`, whose
/// tail is:
///
/// ```html
/// <input type="hidden" id="_eventId" name="_eventId" value="submit" />
/// <input type="hidden" id="cllt"    name="cllt"    value="userNameLogin" />
/// <input type="hidden" id="dllt"    name="dllt"    value="generalLogin" />
/// <input type="hidden" id="lt"      name="lt"      value="" />
/// <input type="hidden" id="pwdEncryptSalt"          value="dYuZ3fFS2uIolipS" />
/// <input type="hidden" id="execution" name="execution" value="e1s1" />
/// ```
///
/// Note that `pwdEncryptSalt` has an `id` but no `name`: it is **not** submitted.
/// It exists only to seed the client-side encryption. Sending it would be noise
/// the server ignores; more importantly, treating "no name" as "missing" would
/// mean the salt is never found and every sign-in quietly falls back to sending
/// the password in the clear.
library;

import '../../core/result.dart';

/// The password form's server-issued state.
class CasLoginForm {
  const CasLoginForm({
    required this.execution,
    required this.salt,
    required this.lt,
    required this.cllt,
    required this.dllt,
    required this.eventId,
    required this.captchaSwitch,
  });

  /// The conversation token the server expects back. Short-lived.
  final String execution;

  /// Seeds the client-side password encryption. Blank only if the deployment
  /// stops encrypting — see [passwordIsEncrypted].
  final String salt;

  /// Legacy login-ticket field; empty on every page captured so far, and sent
  /// anyway because the form sends it.
  final String lt;

  /// Which sign-in method this form represents — `userNameLogin` here.
  final String cllt;

  /// `generalLogin` on every page captured.
  final String dllt;

  /// `submit`, as the form's own hidden field says.
  final String eventId;

  /// The page's `captchaSwitch`. `"1"` is the classic text CAPTCHA; `"2"` is the
  /// slider, which this client cannot present — see [CasCaptchaMode].
  final String captchaSwitch;

  /// Whether the password will go out encrypted. False means the server sent no
  /// salt and the form's own fallback would send it in the clear.
  bool get passwordIsEncrypted => salt.trim().isNotEmpty;

  /// How the page expects a challenge to be presented.
  CasCaptchaMode get captchaMode => switch (captchaSwitch) {
        '1' => CasCaptchaMode.text,
        '2' => CasCaptchaMode.slider,
        _ => CasCaptchaMode.unknown,
      };

  /// The fields that go on the wire, minus `username`, `password` and `captcha`,
  /// which the caller supplies.
  ///
  /// `pwdEncryptSalt` is deliberately absent: it has no `name` attribute in the
  /// page and therefore is not part of the form's submission.
  Map<String, String> get fixedFields => {
        '_eventId': eventId,
        'cllt': cllt,
        'dllt': dllt,
        'lt': lt,
        'execution': execution,
      };

  /// Parses the password form out of a sign-in page.
  ///
  /// Returns a [Failure] — never a form with empty fields — when the page does
  /// not look like a sign-in page. A half-populated form would produce a POST
  /// that the server rejects with an unrelated message, which is much harder to
  /// diagnose than "this is not the page I expected".
  static Result<CasLoginForm> parse(String html) {
    final form = _formTagWithId(html, 'pwdFromId');
    if (form == null) {
      return Failure<CasLoginForm>.reason(
        FailureKind.invalidData,
        message:
            'No #pwdFromId form in the response. The password sign-in form '
            'is absent, so this is not the page that was expected — a service '
            'error or a redirect would look like this.',
      );
    }

    final inputs = _inputs(form);
    if (inputs.isEmpty) {
      return Failure<CasLoginForm>.reason(
        FailureKind.invalidData,
        message: 'The #pwdFromId form contains no inputs.',
      );
    }

    final execution = _byName(inputs, 'execution');
    if (execution == null || execution.isEmpty) {
      return Failure<CasLoginForm>.reason(
        FailureKind.invalidData,
        message: 'The #pwdFromId form has no non-empty execution value. '
            'Without it the server will not accept the submission, so there is '
            'no point sending one.',
      );
    }

    // No `name`, only `id` — see the library doc. Absent is tolerated (the
    // deployment may have stopped encrypting) but reported through
    // [CasLoginForm.passwordIsEncrypted] rather than assumed away.
    final salt = _byId(inputs, 'pwdEncryptSalt') ?? '';

    return Success(CasLoginForm(
      execution: execution,
      salt: salt,
      lt: _byName(inputs, 'lt') ?? '',
      cllt: _byName(inputs, 'cllt') ?? 'userNameLogin',
      dllt: _byName(inputs, 'dllt') ?? 'generalLogin',
      eventId: _byName(inputs, '_eventId') ?? 'submit',
      captchaSwitch: _captchaSwitch(html) ?? '',
    ));
  }

  @override
  String toString() =>
      'CasLoginForm(cllt: $cllt, execution: ${execution.length} '
      'chars, salt: ${salt.isEmpty ? "absent" : "${salt.length} chars"}, '
      'captchaSwitch: ${captchaSwitch.isEmpty ? "absent" : captchaSwitch})';
}

/// How the deployment expects a proof-of-human to be presented.
enum CasCaptchaMode {
  /// A distorted-text image at `/getCaptcha.htl`, typed back by the person.
  text,

  /// `captchaSwitch == "2"`: a drag-the-piece slider. Not something this client
  /// can put on screen, and not something it will try to solve.
  slider,

  /// A value this build has not seen. Treated as "cannot present it", never as
  /// "no challenge required".
  unknown,
}

/// The complete `<form ...>...</form>` element whose `id` attribute is [id].
///
/// Deliberately scoped rather than searching the document: the page has three
/// overalapping forms, and `execution` alone appears in two of them.
String? _formTagWithId(String html, String id) {
  final openers =
      RegExp(r'<form\b[^>]*>', caseSensitive: false).allMatches(html);
  for (final opener in openers) {
    if (_attr(opener.group(0)!, 'id') != id) continue;
    final close = html.indexOf('</form>', opener.end);
    if (close < 0) return null;
    return html.substring(opener.start, close);
  }
  return null;
}

/// Every `<input ...>` tag inside [fragment], as raw tag text.
List<String> _inputs(String fragment) =>
    RegExp(r'<input\b[^>]*>', caseSensitive: false)
        .allMatches(fragment)
        .map((m) => m.group(0)!)
        .toList(growable: false);

String? _byName(List<String> inputs, String name) {
  for (final tag in inputs) {
    if (_attr(tag, 'name') == name) return _attr(tag, 'value') ?? '';
  }
  return null;
}

String? _byId(List<String> inputs, String id) {
  for (final tag in inputs) {
    if (_attr(tag, 'id') == id) return _attr(tag, 'value') ?? '';
  }
  return null;
}

/// The value of one attribute in a tag, or null when it is not present.
///
/// Handles single quotes, double quotes and no quotes, because HTML allows all
/// three and a parser that only handles the one shape the developer happened to
/// capture is a parser that breaks on the next page load.
String? _attr(String tag, String name) {
  final quoted = RegExp(
    '$name\\s*=\\s*("([^"]*)"|\'([^\']*)\')',
    caseSensitive: false,
  ).firstMatch(tag);
  if (quoted != null) return quoted.group(2) ?? quoted.group(3) ?? '';

  final bare =
      RegExp('$name\\s*=\\s*([^\\s>]+)', caseSensitive: false).firstMatch(tag);
  return bare?.group(1);
}

/// The page-level `var captchaSwitch = "...";` declaration.
///
/// Read from the script rather than from the form, because that is where the
/// page puts it.
String? _captchaSwitch(String html) => RegExp(
      r'''captchaSwitch\s*=\s*["']([^"']*)["']''',
    ).firstMatch(html)?.group(1);
