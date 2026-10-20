import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/i18n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../../main.dart';
import '../../whu_auth/account_login_screen.dart';
import '../../whu_auth/cas_navigation.dart';
import '../../whu_auth/whu_endpoints.dart' show JwglOrigin;
import '../../whu_auth/whu_session.dart';
import '../archive/grade_archive_screen.dart';
import 'jwgl_browser_screen.dart';
import 'jwgl_menu.dart';
import 'jwgl_repository.dart';

/// The 正方教务 view: read the student menu, then open what it names.
///
/// Why this screen exists at all: the grade and evaluation data the feature is
/// for lives in the university's own academic system, not in the third-party
/// app backend — whose `courses` / `reviews` / `offerings` datasets are all
/// verified empty. 正方 is the real source.
///
/// Why it fetches a **menu** rather than calling a known page: every route
/// under jwgl returns the same SPA shell (verified — nine paths, nine identical
/// 20602-byte documents), so an endpoint cannot be probed into existence and a
/// 404 proves nothing. The set of student functions is delivered at runtime and
/// depends on the account. The teaching-evaluation entry appears nowhere in
/// this project's binary, so it has to be read from the menu.
class JwglScreen extends StatefulWidget {
  const JwglScreen({super.key});

  @override
  State<JwglScreen> createState() => _JwglScreenState();
}

class _JwglScreenState extends State<JwglScreen> {
  JwglRepository? _repo;
  JwglMenu? _menu;
  bool _busy = false;
  String _error = '';

  String? _openedName;
  String? _openedBody;

  ValueNotifier<WhuSession?>? _sessionChanges;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppScope.of(context, dependOn: false).sessionChanges;
    if (identical(next, _sessionChanges)) return;
    _sessionChanges?.removeListener(_onSessionChanged);
    _sessionChanges = next..addListener(_onSessionChanged);
  }

  /// A sign-in that happened elsewhere — in the in-app browser, most often — has
  /// to reach this screen. Popping back from that route does not rebuild this one,
  /// so without this the 教务 screen keeps showing its "sign in" wall on top of a
  /// session that exists, and every feature it gates looks locked.
  void _onSessionChanged() {
    if (!mounted) return;
    setState(_ensureRepo);
  }

  @override
  void dispose() {
    _sessionChanges?.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _ensureRepo() {
    final services = AppScope.of(context, dependOn: false);
    final session = services.whuSession;
    if (session == null) {
      _repo = null;
      return;
    }
    // Kept unless the session actually changed. Building a fresh repository on
    // every build threw its diagnostics away: setting `_busy = false` after a
    // request rebuilt the screen, `_ensureRepo` made a new (empty) repository,
    // and the log of the request that had just run was gone before it could be
    // looked at.
    if (identical(_repo?.session, session)) return;
    _repo = JwglRepository(client: services.client, session: session);
  }

  Future<void> _signIn() async {
    // The browser path, because the HTTP password form cannot answer the
    // second-factor page this deployment asks for. The session is adopted inside
    // the browser (「设为应用会话」) and lands on AppScope.whuSession.
    await AccountLoginScreen.push(context);
    if (!mounted) return;
    setState(_ensureRepo);
    if (_repo != null) await _loadMenu();
  }

  Future<void> _loadMenu() async {
    final repo = _repo;
    if (repo == null) return;

    setState(() {
      _busy = true;
      _error = '';
    });

    // Defensive: an exception escaping the repository mid-flight used to leave
    // `_busy` true forever — a loader with no error and no way back. Whatever
    // happens, this screen ends up saying something.
    try {
      final result = await repo.fetchMenu();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _menu = result.dataOrNull;
        _error = result.errorOrNull?.message ?? '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _open(JwglMenuEntry entry) async {
    final repo = _repo;
    if (repo == null) return;

    setState(() {
      _busy = true;
      _error = '';
      _openedName = entry.name;
      _openedBody = null;
    });

    try {
      final result = await repo.openMenuPage(entry);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _openedBody = result.dataOrNull;
        _error = result.errorOrNull?.message ?? '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    _ensureRepo();

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.jwTitle),
        actions: [
          // Always available, sign-in or not: the archive holds grades read on
          // an earlier day and answers GPA questions without a session.
          IconButton(
            tooltip: l10n.archiveOpen,
            icon: const Icon(Icons.insights_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const GradeArchiveScreen(),
              ),
            ),
          ),
          IconButton(
            tooltip: l10n.gqDiagnostics,
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () => _diagnostics(l10n),
          ),
          if (_repo != null)
            IconButton(
              tooltip: l10n.gqSignOut,
              icon: const Icon(Icons.logout_rounded),
              onPressed: () {
                AppScope.of(context, dependOn: false).whuSession = null;
                setState(() {
                  _repo = null;
                  _menu = null;
                  _openedName = null;
                  _openedBody = null;
                });
              },
            ),
        ],
      ),
      body: _repo == null ? _wall(l10n) : _body(l10n),
    );
  }

  Widget _wall(AppLocalizations l10n) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceXl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.school_outlined, size: 44),
              const SizedBox(height: AppTheme.spaceMd),
              Text(l10n.jwSignInNeeded, textAlign: TextAlign.center),
              const SizedBox(height: AppTheme.spaceSm),
              Text(l10n.signInChallengeHint,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: AppTheme.spaceLg),
              FilledButton.icon(
                onPressed: _signIn,
                icon: const Icon(Icons.login_rounded),
                label: Text(l10n.jwSignInCta),
              ),
              const SizedBox(height: AppTheme.spaceMd),
              // Offered before signing in on purpose: the in-app browser is a
              // separate browser with its own session, so it never needs the app's
              // `WhuSession`. Making it depend on signing in here would be a lie
              // about what it needs.
              // The front door, not a deep link.
              //
              // Deep-linking into a protected page and signing in *from there*
              // does not survive the SSO handshake: CAS returns, the academic
              // system redeems the ticket, and it lands on its own default page
              // instead of the one that was asked for — which is a 404 with an
              // undeclared charset, so it reads as mojibake. Entering at the root
              // is what a person does and what the handshake expects.
              OutlinedButton.icon(
                onPressed: () => JwglBrowserScreen.push(
                  context,
                  url: '${JwglOrigin.root}/',
                  title: l10n.jwGradesInBrowser,
                ),
                icon: const Icon(Icons.travel_explore_rounded),
                label: Text(l10n.jwGradesInBrowser),
              ),
            ],
          ),
        ),
      );

  Widget _body(AppLocalizations l10n) {
    final menu = _menu;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spaceMd,
        AppTheme.spaceMd,
        AppTheme.spaceMd,
        AppTheme.spaceXl,
      ),
      children: [
        Text(l10n.jwExplain, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: AppTheme.spaceMd),
        FilledButton.icon(
          onPressed: _busy ? null : _loadMenu,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.account_tree_outlined),
          label: Text(l10n.jwFetchMenu),
        ),
        const SizedBox(height: AppTheme.spaceSm),
        // The escape hatch for anything the HTTP client cannot do — chiefly the
        // academic system's anti-bot puzzle on the grade query. Runs the real
        // page in the browser the Windows runner hosts; the person works it.
        OutlinedButton.icon(
          onPressed: () => JwglBrowserScreen.push(
            context,
            // Same front door as the wall's button: the SSO handshake only
            // preserves a landing page when it starts at the root.
            url: '${JwglOrigin.root}/',
            title: l10n.jwGradesInBrowser,
          ),
          icon: const Icon(Icons.travel_explore_rounded),
          label: Text(l10n.jwGradesInBrowser),
        ),
        const SizedBox(height: AppTheme.spaceSm),
        // A deep link is only safe *after* a session exists, and the session lives
        // in the browser profile on disk, so it survives both screen changes and
        // app restarts. That is why this is a second step rather than the first:
        // signing in *from* a deep link is what produced the 404.
        TextButton.icon(
          onPressed: () => JwglBrowserScreen.push(
            context,
            url: '${JwglOrigin.gradeQuery}'
                '?gnmkdm=${JwglOrigin.gradeGnmkdm}&layout=default',
            title: l10n.jwGoToGrades,
          ),
          icon: const Icon(Icons.table_chart_outlined),
          label: Text(l10n.jwGoToGrades),
        ),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: AppTheme.spaceSm),
          Text(_error,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error)),
        ],
        if (menu != null) ...[
          const SizedBox(height: AppTheme.spaceMd),
          _menuView(l10n, menu),
        ],
        if (_openedName != null) ...[
          const SizedBox(height: AppTheme.spaceMd),
          Text('${l10n.jwOpened} $_openedName',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppTheme.spaceXs),
          _openedBody == null
              ? const CenterLoader()
              : _rawBlock(_openedBody!, l10n),
        ],
      ],
    );
  }

  Widget _menuView(AppLocalizations l10n, JwglMenu menu) {
    final text = Theme.of(context).textTheme;
    final hits = menu.evaluationEntries();

    if (menu.isEmpty) {
      return EmptyState(
        title: l10n.jwEmptyMenu,
        body: l10n.jwExplain,
        icon: Icons.account_tree_outlined,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.jwMenuTitle, style: text.titleSmall),
        const SizedBox(height: AppTheme.spaceXs),
        Text(
          hits.isEmpty
              ? l10n.jwNoEvaluation
              : l10n.jwFoundEvaluation.replaceAll('%d', '${hits.length}'),
          style: text.bodySmall?.copyWith(
            color: hits.isEmpty
                ? Theme.of(context).colorScheme.outline
                : Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: AppTheme.spaceSm),
        for (final e in menu.all) _entry(l10n, e, depth: 0),
      ],
    );
  }

  Widget _entry(AppLocalizations l10n, JwglMenuEntry entry,
      {required int depth}) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final isEval = entry.looksLikeEvaluation;
    final canOpen = entry.url.isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(left: depth * 14.0, bottom: 2),
      child: InkWell(
        onTap: canOpen ? () => _open(entry) : null,
        child: Row(
          children: [
            Icon(
              isEval ? Icons.star_rounded : Icons.chevron_right,
              size: 15,
              color: isEval ? scheme.primary : scheme.outline,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                entry.name,
                style: text.bodyMedium?.copyWith(
                  fontWeight: isEval ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (entry.gnmkdm.isNotEmpty)
              Text(entry.gnmkdm,
                  style: text.labelSmall?.copyWith(color: scheme.outline)),
          ],
        ),
      ),
    );
  }

  Widget _rawBlock(String body, AppLocalizations l10n) {
    final shown = body.length > 20000 ? body.substring(0, 20000) : body;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('${body.length} B',
                  style: Theme.of(context).textTheme.labelSmall),
              const Spacer(),
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: body)),
                icon: const Icon(Icons.copy_all_outlined, size: 16),
                label: Text(l10n.gqCopy),
              ),
            ],
          ),
          SelectableText(
            shown,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ],
      ),
    );
  }

  void _diagnostics(AppLocalizations l10n) {
    final repo = _repo;
    final raw = repo?.lastRawResponse ?? '';
    final endpoint = repo?.lastRawEndpoint ?? '';
    final text = Theme.of(context).textTheme;

    // How the session was obtained. When a request is refused, whether the
    // handshake actually produced a session on this host is the first thing worth
    // knowing — and it is not visible from the refusal alone.
    final session = AppScope.of(context, dependOn: false).whuSession;
    final hops = session?.handshake ?? const <String>[];
    final held = session?.scoped ?? const <CookieData>[];
    final handshakeText = [
      ...hops,
      if (held.isNotEmpty) '',
      // Names and hosts only. A value here would be a live session.
      for (final c in held) 'held: ${c.name} @ ${c.domain}${c.path}',
    ].join('\n');

    // One block, because the two halves only mean something together: the hop log
    // says whether a session was established on this host, and the body says what
    // the server did instead. Copying them separately is how one gets left out —
    // which is precisely what happened to the hop log while it was only
    // selectable text behind a button that copied the body alone.
    final report = [
      if (handshakeText.isNotEmpty) ...[
        '--- handshake ---',
        handshakeText,
      ],
      if (endpoint.isNotEmpty) ...[
        '--- request ---',
        endpoint,
      ],
      if (raw.isNotEmpty) ...[
        '--- response (${raw.length} B) ---',
        raw,
      ],
    ].join('\n');

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
              Text(l10n.gqDiagnostics, style: text.titleMedium),
              const SizedBox(height: AppTheme.spaceXs),
              Text(l10n.jwDiagnosticsNote, style: text.bodySmall),
              if (endpoint.isNotEmpty) ...[
                const SizedBox(height: AppTheme.spaceXs),
                Text(endpoint, style: text.labelSmall),
              ],
              if (handshakeText.isNotEmpty) ...[
                const SizedBox(height: AppTheme.spaceSm),
                Text(l10n.jwHandshake, style: text.titleSmall),
                const SizedBox(height: AppTheme.spaceXs),
                SelectableText(
                  handshakeText,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ],
              const SizedBox(height: AppTheme.spaceSm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 340),
                child: raw.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(AppTheme.spaceLg),
                          child: Text(l10n.gqNoRaw),
                        ),
                      )
                    : SingleChildScrollView(
                        child: SelectableText(
                          raw.length > 20000 ? raw.substring(0, 20000) : raw,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 11),
                        ),
                      ),
              ),
              const SizedBox(height: AppTheme.spaceSm),
              Row(
                children: [
                  // Shown whenever there is *anything* to copy. Gating it on the
                  // response body hid it in the case that needs it most: a
                  // sign-in that failed before any request produced a body.
                  if (report.isNotEmpty)
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
                      repo?.clearDiagnostics();
                      Navigator.of(sheetContext).pop();
                      setState(() {});
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
