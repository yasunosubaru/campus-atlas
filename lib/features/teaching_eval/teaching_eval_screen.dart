import 'package:flutter/material.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../main.dart';
import '../grades_query/jwgl/jwgl_browser_screen.dart';
import '../whu_auth/account_login_screen.dart';
import '../whu_auth/whu_endpoints.dart';
import '../whu_auth/whu_session.dart';
import 'adaptive_document.dart';
import 'plan.dart';
import 'review_drafts_screen.dart';
import 'ugsqs_repository.dart';

/// Teacher-evaluation discovery view.
///
/// This is explicitly a **discovery tool, not a finished feature**, and the UI
/// says so. `ugsqs.whu.edu.cn` publishes no credential-free contract — its JS
/// is inlined into protected pages and its static paths all 404 — so there is
/// no response shape to build typed models against. Rather than fabricate one
/// and have the interface confidently render a structure that does not exist,
/// this shows the session-reuse path it would take and whatever the endpoint
/// actually returns.
class TeachingEvalScreen extends StatefulWidget {
  const TeachingEvalScreen({super.key});

  @override
  State<TeachingEvalScreen> createState() => _TeachingEvalScreenState();
}

class _TeachingEvalScreenState extends State<TeachingEvalScreen> {
  AdaptiveDocument? _doc;
  bool _busy = false;
  String _error = '';

  /// The student id the landing page's own script posts. Kept in memory only:
  /// the hand-off needs it once, and it is identifying data.
  final _userId = TextEditingController();
  bool _resolving = false;
  String? _resolved;
  String _resolveError = '';

  @override
  void dispose() {
    _userId.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    await AccountLoginScreen.push(context);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _fetch() async {
    final services = AppScope.of(context, dependOn: false);
    final session = services.whuSession;
    if (session == null) return;

    final plan = TeachingEvalPlan.forSession(session);
    if (!plan.canProceed) {
      final message = _refusalText(AppLocalizations.of(context), plan.refusal);
      setState(() => _error = message);
      return;
    }

    setState(() {
      _busy = true;
      _error = '';
    });

    // Anything unexpected must still release the screen. Without this, a single
    // thrown exception left `_busy` true forever: the button disabled itself
    // and no click, not even an accessibility Invoke, could get back in — the
    // whole screen became read-only with no explanation.
    try {
      final target = Uri.parse(TeachingEvalOrigin.casService);

      // Manual, per-hop redirect following: the evaluation entry bounces to
      // CAS, and only a per-hop cookie can present the CAS grant to the CAS
      // host that asks for it (`package:http`'s automatic following would
      // resend this host's cookies to CAS, where the grant is not among them).
      final got = await services.client.getFollowing(
        target,
        cookieFor: session.cookieHeaderFor,
        headers: {
          'referer': '${CasOrigin.login}'
              '${Uri.encodeComponent(TeachingEvalOrigin.casService)}',
        },
      );
      final failure = got.errorOrNull;
      if (failure != null) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = failure.message;
        });
        return;
      }

      final chain = got.requireValue;
      if (!mounted) return;
      setState(() {
        _doc = AdaptiveDocument.parse(chain.response.body);
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  String _refusalText(AppLocalizations l10n, PlanRefusal? refusal) =>
      switch (refusal) {
        PlanRefusal.noSession => l10n.evalSignInFirst,
        PlanRefusal.noGrant => l10n.signInNoGrant,
        PlanRefusal.stale => l10n.signInStatusFailed,
        PlanRefusal.noServiceTarget => l10n.signInServiceMissing,
        null => '',
      };

  /// Performs the hand-off the landing page's own JavaScript performs.
  Future<void> _resolveEntry() async {
    final l10n = AppLocalizations.of(context);
    if (_userId.text.trim().isEmpty) {
      setState(() => _resolveError = l10n.evalNeedUserId);
      return;
    }

    final services = AppScope.of(context, dependOn: false);
    setState(() {
      _resolving = true;
      _resolveError = '';
      _resolved = null;
    });

    final result = await UgsqsRepository(
      client: services.client,
      session: services.whuSession,
    ).resolveEntry(userId: _userId.text);

    if (!mounted) return;
    setState(() {
      _resolving = false;
      _resolved = result.dataOrNull;
      _resolveError = result.errorOrNull?.message ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = AppScope.of(context, dependOn: false).whuSession;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.evalTitle)),
      body: session == null ? _wall(l10n) : _live(l10n, session),
    );
  }

  Widget _wall(AppLocalizations l10n) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceXl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.forum_outlined, size: 44),
              const SizedBox(height: AppTheme.spaceMd),
              Text(l10n.evalSignInFirst, textAlign: TextAlign.center),
              const SizedBox(height: AppTheme.spaceLg),
              FilledButton.icon(
                onPressed: _signIn,
                icon: const Icon(Icons.login_rounded),
                label: Text(l10n.signInTitle),
              ),
            ],
          ),
        ),
      );

  Widget _live(AppLocalizations l10n, WhuSession session) {
    final plan = TeachingEvalPlan.forSession(session);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spaceMd,
        AppTheme.spaceMd,
        AppTheme.spaceMd,
        AppTheme.spaceXl,
      ),
      children: [
        Text(l10n.evalEvidenceNote,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: AppTheme.spaceSm),
        if (plan.canProceed)
          _planView(l10n, plan)
        else
          _refusedView(l10n, plan),
        const SizedBox(height: AppTheme.spaceMd),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy || !plan.canProceed ? null : _fetch,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined),
                label: Text(l10n.evalFetch),
              ),
            ),
          ],
        ),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: AppTheme.spaceSm),
          Text(_error,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: AppTheme.spaceMd),
        _entryPanel(l10n),
        const SizedBox(height: AppTheme.spaceXs),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ReviewDraftsScreen(),
              ),
            ),
            icon: const Icon(Icons.rate_review_outlined),
            label: Text(l10n.evalDrafts),
          ),
        ),
        Text(
          l10n.evalHamNote,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
        const SizedBox(height: AppTheme.spaceMd),
        if (_doc != null) _docView(l10n),
      ],
    );
  }

  /// The evidence-backed hand-off: `/loginSSO` with the student id.
  Widget _entryPanel(AppLocalizations l10n) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    Uri? resolved;
    if (_resolved != null) resolved = Uri.tryParse(_resolved!);

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.evalEntryTitle, style: text.titleSmall),
          const SizedBox(height: AppTheme.spaceXs),
          Text(l10n.evalEntryNote, style: text.bodySmall),
          const SizedBox(height: AppTheme.spaceSm),
          TextField(
            controller: _userId,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: l10n.evalUserId),
          ),
          const SizedBox(height: AppTheme.spaceSm),
          FilledButton.icon(
            onPressed: _resolving ? null : _resolveEntry,
            icon: _resolving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link),
            label: Text(l10n.evalResolve),
          ),
          if (_resolveError.isNotEmpty) ...[
            const SizedBox(height: AppTheme.spaceXs),
            Text(
              _resolveError,
              style: text.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
          if (resolved != null) ...[
            const SizedBox(height: AppTheme.spaceSm),
            Text(
              '${l10n.evalResolved} · ${resolved.host}${resolved.path}',
              style: text.bodySmall,
            ),
            const SizedBox(height: AppTheme.spaceXs),
            FilledButton.tonalIcon(
              onPressed: () => JwglBrowserScreen.push(
                context,
                url: _resolved!,
                title: l10n.evalTitle,
                showGradeTools: false,
              ),
              icon: const Icon(Icons.open_in_browser),
              label: Text(l10n.evalOpenBrowser),
            ),
            const SizedBox(height: AppTheme.spaceXs),
            Text(
              l10n.evalNoSubmit,
              style: text.bodySmall?.copyWith(color: scheme.outline),
            ),
          ],
        ],
      ),
    );
  }

  Widget _refusedView(AppLocalizations l10n, TeachingEvalPlan plan) => Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.evalSignInFirst,
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppTheme.spaceSm),
            Text(_refusalText(l10n, plan.refusal)),
            const SizedBox(height: AppTheme.spaceSm),
            TextButton(onPressed: _signIn, child: Text(l10n.signInTitle)),
          ],
        ),
      );

  Widget _planView(AppLocalizations l10n, TeachingEvalPlan plan) {
    final minutes = plan.remaining.inMinutes;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.evalPlanTitle,
              style: Theme.of(context).textTheme.titleSmall),
          Text(
            l10n.evalRemaining.replaceAll('%s', '$minutes'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppTheme.spaceSm),
          for (var i = 0; i < plan.hops.length; i++)
            _hop(l10n, plan.hops[i], i + 1),
        ],
      ),
    );
  }

  Widget _hop(AppLocalizations l10n, Hop hop, int n) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final colour = hop.evidence ? scheme.primary : scheme.outline;
    final label = hop.evidence ? l10n.evalVerified : l10n.evalAssumed;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                  radius: 9,
                  backgroundColor: colour.withValues(alpha: 0.18),
                  child: Text('$n', style: text.labelSmall)),
              const SizedBox(width: AppTheme.spaceSm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colour.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: Text(label,
                    style: text.labelSmall?.copyWith(color: colour)),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 26, top: 4),
            child: Text(hop.url,
                style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    overflow: TextOverflow.ellipsis)),
          ),
          Text(hop.why, style: text.bodySmall),
        ],
      ),
    );
  }

  Widget _docView(AppLocalizations l10n) {
    final doc = _doc!;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final tables = doc.candidateTables();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.evalResponseTitle, style: text.titleSmall),
        const SizedBox(height: AppTheme.spaceXs),
        Text(l10n.evalLoaded.replaceAll('%s', doc.describe()),
            style: text.bodySmall),
        if (doc.isSignInPage) ...[
          const SizedBox(height: AppTheme.spaceSm),
          Panel(
            child: Row(
              children: [
                Icon(Icons.lock_outline, size: 18, color: scheme.error),
                const SizedBox(width: AppTheme.spaceSm),
                Expanded(
                  child: Text(l10n.evalSignInPage,
                      style: text.bodySmall?.copyWith(color: scheme.error)),
                ),
              ],
            ),
          ),
        ],
        if (!doc.hasData)
          EmptyState(
            title: l10n.evalNoTable,
            body: doc.preview,
            icon: Icons.data_object,
          )
        else ...[
          const SizedBox(height: AppTheme.spaceSm),
          if (tables.isEmpty) Text(l10n.evalNoTable, style: text.bodySmall),
          for (final t in tables) _table(t),
        ],
      ],
    );
  }

  Widget _table(TableCandidate t) {
    final text = Theme.of(context).textTheme;
    final rows = t.render();

    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${t.label} · ${rows.length}×${t.columns.length}',
              style: text.labelMedium),
          const SizedBox(height: AppTheme.spaceXs),
          Container(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: [
                    for (final c in t.columns)
                      DataColumn(label: Text(c, style: text.labelSmall)),
                  ],
                  rows: [
                    for (final r in rows)
                      DataRow(
                        cells: [
                          for (var i = 0; i < t.columns.length; i++)
                            DataCell(Text(r[i], style: text.bodySmall)),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
