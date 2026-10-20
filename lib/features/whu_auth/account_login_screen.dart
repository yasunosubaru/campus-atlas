import 'package:flutter/material.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../main.dart';
import '../grades_query/jwgl/jwgl_browser_screen.dart';
import 'cas_login_screen.dart';
import 'whu_endpoints.dart' show JwglOrigin;
import 'whu_session.dart';

/// 账户登录 — the single place a campus session is established.
///
/// ## Why the browser, and not the password form
///
/// The password form (`CasLoginScreen`) sends the credentials over HTTP. On this
/// deployment the central service accepts the password and then answers with
/// `reAuthCheck/reAuthLoginView.do?isMultifactor=true`: a **second factor**
/// (SMS code, OTP, QR, …) because the browser is not trusted. There is no ticket
/// until that page is satisfied, and an HTTP client cannot satisfy it.
///
/// The in-app browser (a native WebView2 window, not a Flutter platform view)
/// can present whatever the page asks for — slider, SMS, OTP, QR — and the app
/// then adopts the resulting cookies with 「设为应用会话」. That single session is
/// what 成绩、课表导入 and 评教 all reuse. The password form remains as a
/// fallback for accounts that are not asked for a second factor.
class AccountLoginScreen extends StatelessWidget {
  const AccountLoginScreen({super.key});

  static Future<void> push(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const AccountLoginScreen()),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final services = AppScope.of(context, dependOn: false);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.accountTitle)),
      body: ValueListenableBuilder<WhuSession?>(
        valueListenable: services.sessionChanges,
        builder: (context, session, _) => ListView(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceMd,
            AppTheme.spaceMd,
            AppTheme.spaceMd,
            AppTheme.spaceXl,
          ),
          children: [
            Text(l10n.accountIntro,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AppTheme.spaceMd),
            _status(context, l10n, session),
            const SizedBox(height: AppTheme.spaceMd),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.accountChallengeNote,
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: AppTheme.spaceSm),
                  Text(l10n.accountBrowserHint,
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: AppTheme.spaceSm),
                  Text(
                    l10n.accountHamNote,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppTheme.spaceSm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => _passwordFallback(context, l10n),
                child: Text(l10n.accountPasswordFallback),
              ),
            ),
            if (session == null)
              Padding(
                padding: const EdgeInsets.only(top: AppTheme.spaceXs),
                child: Text(
                  l10n.accountPasswordFallbackNote,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _status(
    BuildContext context,
    AppLocalizations l10n,
    WhuSession? session,
  ) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    if (session == null) {
      return Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.account_circle_outlined, color: scheme.outline),
                const SizedBox(width: AppTheme.spaceSm),
                Text(l10n.accountSignedOut, style: text.titleMedium),
              ],
            ),
            const SizedBox(height: AppTheme.spaceMd),
            FilledButton.icon(
              onPressed: () => _browserLogin(context, l10n),
              icon: const Icon(Icons.open_in_browser),
              label: Text(l10n.accountBrowserSignIn),
            ),
          ],
        ),
      );
    }

    final remaining = _remainingMinutes(session);
    final expired = remaining <= 0;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline, color: scheme.primary),
              const SizedBox(width: AppTheme.spaceSm),
              Text(l10n.accountSignedIn, style: text.titleMedium),
            ],
          ),
          const SizedBox(height: AppTheme.spaceXs),
          Text(
            l10n.accountAcquiredAt
                .replaceAll('%s', _formatTime(session.acquiredAt)),
            style: text.bodySmall,
          ),
          Text(
            expired
                ? l10n.accountExpired
                : l10n.accountRemaining.replaceAll('%d', '$remaining'),
            style: text.bodySmall?.copyWith(
              color: expired ? scheme.error : scheme.outline,
            ),
          ),
          const SizedBox(height: AppTheme.spaceXs),
          Text(l10n.accountCapabilities, style: text.bodySmall),
          const SizedBox(height: AppTheme.spaceMd),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _browserLogin(context, l10n),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(l10n.accountBrowserSignIn),
                ),
              ),
              const SizedBox(width: AppTheme.spaceSm),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => _signOut(context, l10n),
                  icon: const Icon(Icons.logout, size: 18),
                  label: Text(l10n.accountSignOut),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _browserLogin(
      BuildContext context, AppLocalizations l10n) async {
    await JwglBrowserScreen.push(
      context,
      url: JwglOrigin.root,
      title: l10n.accountBrowserTitle,
      showGradeTools: false,
    );
    // The session is adopted inside the browser screen (「设为应用会话」); the
    // ValueListenableBuilder above picks it up without any extra plumbing.
  }

  Future<void> _passwordFallback(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final session = await CasLoginScreen.push(context, WhuProperty.jwgl);
    if (session == null || !context.mounted) return;
    AppScope.of(context, dependOn: false).whuSession = session;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.accountLoginSuccess)),
    );
  }

  Future<void> _signOut(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.accountSignOut),
        content: Text(l10n.accountSignOutBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.accountSignOut),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    AppScope.of(context, dependOn: false).whuSession = null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.accountSignedOutDone)),
    );
  }

  static int _remainingMinutes(WhuSession session) {
    const ttl = Duration(hours: 2);
    final left = ttl - DateTime.now().difference(session.acquiredAt);
    return left.isNegative ? 0 : left.inMinutes;
  }

  static String _formatTime(DateTime at) => '${at.month}-${at.day} '
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';
}
