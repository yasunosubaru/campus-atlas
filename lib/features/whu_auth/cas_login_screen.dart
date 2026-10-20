import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/result.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import 'cas_http_client.dart';
import 'cas_login_form.dart';
import 'whu_session.dart';

/// Signing in against the university's central authentication service.
///
/// ## What this screen is, and is not
///
/// The person types **their own** student number and password into their own
/// copy of the app, which sends them once to the service they already trust and
/// keeps only the cookies that come back. Nothing here is solved on their
/// behalf: if the account is asked for a challenge this client cannot present,
/// it says so instead of working around it.
///
/// ## Why there is no embedded browser any more
///
/// There was one, and it is worth recording why it went, because "put it back"
/// is the obvious suggestion.
///
/// The plugin was `flutter_inappwebview` — `webview_windows` no longer compiles
/// under current MSVC, and `webview_flutter` has no Windows implementation at
/// all — and it worked in debug and in profile. In a **release** build the
/// window went uniformly dark and the accessibility tree collapsed to window
/// chrome. It was not a Dart exception: `FlutterError.onError` and
/// `PlatformDispatcher.onError` wrote nothing to the crash log, and the WebView2
/// process showed evidence it had never navigated at all. Forcing Impeller off
/// made the page load (its cache filled up) and the screen stayed dark anyway, so
/// the fault is in the engine's platform-view compositing, in code this project
/// cannot edit.
///
/// Doing the sign-in over HTTP instead removes the class of problem rather than
/// working around it, behaves identically on every platform, and is testable
/// without a display. `lib/features/whu_auth/cas_http_client.dart` carries the
/// evidence for the wire format; `cas_crypto.dart` for the password encryption.
///
/// ## Handling of the password
///
/// It is read from a controller, sent once, and dropped. It is never written to
/// disk, never logged, and never placed in a diagnostic buffer — the notes
/// behind the 诊断 button carry URLs, status codes and cookie **names** only.
/// The screen says this to the person's face rather than hiding it in a comment.
class CasLoginScreen extends StatefulWidget {
  const CasLoginScreen({super.key, required this.target});

  final WhuProperty target;

  /// Pushes the sign-in and resolves with the session it produced, or null if
  /// the person backed out.
  static Future<WhuSession?> push(BuildContext context, WhuProperty target) =>
      Navigator.of(context).push<WhuSession>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => CasLoginScreen(target: target),
        ),
      );

  @override
  State<CasLoginScreen> createState() => _CasLoginScreenState();
}

class _CasLoginScreenState extends State<CasLoginScreen> {
  final TextEditingController _identifier = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _captcha = TextEditingController();

  /// Non-secret progress notes, for the diagnostics sheet.
  final List<String> _notes = [];

  bool _busy = false;
  String _error = '';

  /// Set when the server demands a challenge, so the screen can either offer a
  /// code field or explain that it cannot present one.
  CasCaptchaMode? _challenge;

  /// A URL-level problem decided before anything was sent — a property with no
  /// sign-in entry, for instance. Shown as a wall rather than as a form error.
  String _blocked = '';

  /// The page that stopped the sign-in, when a page is what stopped it.
  ///
  /// Worth keeping verbatim: when the central service accepts the password and
  /// then asks for a further step, that page is the only place the step is
  /// described. Summarising it into "the sign-in failed" throws away the one piece
  /// of information that says what to do next.
  String? _blockerBody;
  String? _blockerUrl;

  @override
  void initState() {
    super.initState();

    // Resolved up front so an impossible target is reported before the person
    // types anything into a form that could never work.
    if (widget.target.entryUrl == null) {
      _blocked = 'No entry point is established for ${widget.target.name}; '
          'refusing to guess one.';
    }
  }

  @override
  void dispose() {
    // The password lives in this controller for as long as the screen does and
    // no longer.
    _password.dispose();
    _identifier.dispose();
    _captcha.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);

    if (_identifier.text.trim().isEmpty) {
      setState(() => _error = l10n.signInNeedIdentifier);
      return;
    }
    if (_password.text.isEmpty) {
      setState(() => _error = l10n.signInNeedPassword);
      return;
    }

    setState(() {
      _busy = true;
      _error = '';
    });

    final client = CasHttpClient(onDiagnostic: _note);
    try {
      final result = await client.signIn(
        property: widget.target,
        username: _identifier.text.trim(),
        password: _password.text,
        captcha: _captcha.text.trim().isEmpty ? null : _captcha.text.trim(),
      );

      if (!mounted) return;

      if (result.isSuccess) {
        // The password's work is done.
        _password.clear();
        _captcha.clear();
        Navigator.of(context).pop(result.requireValue);
        return;
      }

      final failure = result.errorOrNull!;
      // Set before describing it: `_describe` picks its advice from the mode.
      if (failure.kind == FailureKind.challengeRequired) {
        _challenge = client.captchaMode;
      }
      // Whatever page stopped it, kept for the diagnostics. Read before `close()`
      // in the `finally`, because it is the client's field.
      _blockerBody = client.failurePageBody;
      _blockerUrl = client.failurePageUrl;
      setState(() {
        _busy = false;
        _error = _describe(failure, l10n);
      });
    } finally {
      client.close();
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  /// A message a person can act on.
  ///
  /// The service's own words are quoted verbatim when it gives any, which is far
  /// more specific than anything this file could invent. It has been seen saying
  /// two different things on the same deployment — `该账号非常用账号或用户名密码有误`
  /// and `该账号不存在或用户名密码有误` — and both decline to say whether the number
  /// or the password was wrong. That is the server's decision, not a gap here, so
  /// no attempt is made to read meaning into the sentence.
  ///
  /// The client supplies the sentence; what this method adds is the part that
  /// depends on the reader's language, which the client cannot know.
  String _describe(AppFailure failure, AppLocalizations l10n) {
    switch (failure.kind) {
      case FailureKind.network:
      case FailureKind.timeout:
        return l10n.signInNetwork;
      case FailureKind.challengeRequired:
        final advice = switch (_challenge) {
          CasCaptchaMode.slider => l10n.signInSlider,
          CasCaptchaMode.text => l10n.signInCaptchaNeeded,
          CasCaptchaMode.unknown => '',
          // The mode is read from the page while the form loads, so this is only
          // reachable if the refusal arrived without a form — in which case the
          // server's own sentence is all there is to say.
          null => '',
        };
        return [
          if (failure.message.isNotEmpty) failure.message,
          if (advice.isNotEmpty) advice,
        ].join('\n');
      default:
        return failure.message.isEmpty
            ? l10n.signInStatusFailed
            : failure.message;
    }
  }

  void _note(String note) {
    _notes.add(note);
    // A long conversation would otherwise grow without bound for the lifetime of
    // the screen; the tail is what matters.
    if (_notes.length > 120) _notes.removeRange(0, _notes.length - 120);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('${l10n.signInTitle} · ${widget.target.host}'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: l10n.signInCancel,
          onPressed: () {
            if (Navigator.of(context).canPop()) Navigator.of(context).pop(null);
          },
        ),
        actions: [
          IconButton(
            tooltip: l10n.signInDiagnostics,
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () => _diagnostics(l10n),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppTheme.spaceMd),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: _blocked.isNotEmpty ? _wall(l10n) : _form(l10n),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wall(AppLocalizations l10n) => Padding(
        padding: const EdgeInsets.all(AppTheme.spaceXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link_off_rounded,
                size: 40, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: AppTheme.spaceMd),
            Text(_blocked.isEmpty ? l10n.signInServiceMissing : _blocked,
                textAlign: TextAlign.center),
            const SizedBox(height: AppTheme.spaceMd),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(l10n.signInCancel),
            ),
          ],
        ),
      );

  Widget _form(AppLocalizations l10n) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppTheme.spaceMd),
        Text(l10n.signInPrivacy, style: text.bodySmall),
        const SizedBox(height: AppTheme.spaceLg),

        TextField(
          controller: _identifier,
          autofocus: true,
          enabled: !_busy,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: l10n.signInIdentifier,
            prefixIcon: const Icon(Icons.badge_outlined),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppTheme.spaceMd),

        TextField(
          controller: _password,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: _challenge == CasCaptchaMode.text
              ? TextInputAction.next
              : TextInputAction.done,
          onSubmitted: (_) => _busy ? null : _submit(),
          decoration: InputDecoration(
            labelText: l10n.signInPassword,
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            border: const OutlineInputBorder(),
          ),
        ),

        // Only when the deployment actually uses the text challenge. This one
        // uses the slider (`captchaSwitch == "2"`), so the field normally stays
        // hidden and a slider demand is explained instead.
        if (_challenge == CasCaptchaMode.text) ...[
          const SizedBox(height: AppTheme.spaceMd),
          TextField(
            controller: _captcha,
            enabled: !_busy,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _busy ? null : _submit(),
            decoration: InputDecoration(
              labelText: l10n.signInCaptcha,
              prefixIcon: const Icon(Icons.verified_outlined),
              border: const OutlineInputBorder(),
            ),
          ),
        ],

        if (_error.isNotEmpty) ...[
          const SizedBox(height: AppTheme.spaceMd),
          Panel(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 18, color: scheme.error),
                const SizedBox(width: AppTheme.spaceSm),
                Expanded(child: Text(_error, style: text.bodySmall)),
              ],
            ),
          ),
        ],

        const SizedBox(height: AppTheme.spaceLg),
        FilledButton.icon(
          onPressed: _busy ? null : _submit,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.login_rounded),
          label: Text(_busy ? l10n.signInSubmitting : l10n.signInSubmit),
        ),
        const SizedBox(height: AppTheme.spaceLg),
      ],
    );
  }

  void _diagnostics(AppLocalizations l10n) {
    final text = Theme.of(context).textTheme;

    // One payload, in reading order: what the client did, then the page that
    // stopped it. The page is the part that decides what happens next, and it is
    // easy to leave out — which is how a diagnostics panel ends up full of
    // *where* it stopped and empty of *why*.
    final report = [
      if (_notes.isEmpty) '（还没有记录）' else ..._notes,
      if (_blockerBody != null && _blockerBody!.isNotEmpty) ...[
        '',
        '--- the page that stopped it: ${_blockerUrl ?? "?"} '
            '(${_blockerBody!.length} B) ---',
        _blockerBody!,
      ],
    ].join('\n');
    // Rendering a 40 kB document into a sheet is pointless; the copy button still
    // carries all of it.
    final shown = report.length > 20000 ? report.substring(0, 20000) : report;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceMd),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.signInDiagnostics, style: text.titleMedium),
              const SizedBox(height: AppTheme.spaceXs),
              // Said here because this is where a person would look for a
              // password if it were ever recorded anywhere.
              Text(l10n.signInPrivacy, style: text.bodySmall),
              const SizedBox(height: AppTheme.spaceSm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: SingleChildScrollView(
                  child: SelectableText(
                    shown,
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ),
              const SizedBox(height: AppTheme.spaceSm),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: report));
                      if (!sheetContext.mounted) return;
                      ScaffoldMessenger.of(sheetContext).showSnackBar(
                        SnackBar(content: Text(l10n.gqCopied)),
                      );
                    },
                    icon: const Icon(Icons.copy_all_outlined),
                    label: Text(l10n.gqCopy),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      _notes.clear();
                      setState(() {
                        _blockerBody = null;
                        _blockerUrl = null;
                      });
                      Navigator.of(sheetContext).pop();
                    },
                    child: Text(l10n.gqClear),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
