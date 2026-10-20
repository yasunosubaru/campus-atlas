import 'package:flutter/material.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/result.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../main.dart';
import '../whu_auth/cas_login_screen.dart';
import '../whu_auth/whu_endpoints.dart';
import '../whu_auth/whu_session.dart';
import 'grade_models.dart';
import 'grade_repository.dart';

/// Student grade view.
///
/// Requires a CAS session the person signs in for interactively. This screen
/// never collects a password, never stores a session, and never attempts a
/// CAPTCHA — it asks for a session, and offers a path to obtain one.
///
/// The session itself lives on [Services], read through the scope like every
/// other dependency here, so a sign-in made from anywhere in the app is
/// visible to every feature that needs it for the rest of this run.
class GradeScreen extends StatefulWidget {
  const GradeScreen({super.key});

  @override
  State<GradeScreen> createState() => _GradeScreenState();
}

class _GradeScreenState extends State<GradeScreen> {
  late String _year;
  late final TextEditingController _xqm;

  Result<GradeSheet>? _result;
  bool _busy = false;
  String _failure = '';

  /// The academic year that started in this calendar year if we are past the
  /// autumn cut-over, otherwise the one that started last year. WHU's year
  /// label spans two calendar years and the cut-over sits in the autumn
  /// semester, so using the calendar year directly would give a year that does
  /// not exist for half of it.
  static String currentAcademicYear(DateTime now) {
    final start = now.month >= 8 ? now.year : now.year - 1;
    return '$start-${start + 1}';
  }

  @override
  void initState() {
    super.initState();
    _year = currentAcademicYear(DateTime.now());
    // The second term, whose code is now read off the grade page's own term
    // selector rather than guessed — `12` is what that selector carries for 第2学期.
    _xqm = TextEditingController(text: WhuTerm.second.code);
  }

  @override
  void dispose() {
    _xqm.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final session = await CasLoginScreen.push(context, WhuProperty.jwgl);
    if (session == null || !mounted) return;

    // context is only used after the mounted guard: reading a scope from an
    // unmounted element would throw.
    AppScope.of(context, dependOn: false).whuSession = session;
    setState(() {});
    await _fetch();
  }

  AppLocalizations l10n(BuildContext c) => AppLocalizations.of(c);

  Future<void> _fetch() async {
    final services = AppScope.of(context, dependOn: false);
    final session = services.whuSession;
    if (session == null) return;

    setState(() {
      _busy = true;
      _failure = '';
    });

    final repo = GradeRepository(client: services.client, session: session);
    final result = await repo.fetch(GradeQuery(
      year: _year,
      xqm: _xqm.text.trim(),
    ));

    if (!mounted) return;
    setState(() {
      _result = result;
      _busy = false;
      _failure = result.errorOrNull?.message ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = AppScope.of(context, dependOn: false).whuSession;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.gradesTitle)),
      body: session == null ? _signInWall(l10n) : _authenticated(l10n, session),
    );
  }

  /// Deliberately an invitation, not an empty list: an empty state here would
  /// read as "this term has no grades" rather than "not signed in yet".
  Widget _signInWall(AppLocalizations l10n) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceXl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.badge_outlined, size: 44),
              const SizedBox(height: AppTheme.spaceMd),
              Text(
                l10n.gradesSignInNeeded,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppTheme.spaceSm),
              Text(
                l10n.signInChallengeHint,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppTheme.spaceLg),
              FilledButton.icon(
                onPressed: _signIn,
                icon: const Icon(Icons.login_rounded),
                label: Text(l10n.gradesSignInCta),
              ),
            ],
          ),
        ),
      );

  Widget _authenticated(AppLocalizations l10n, WhuSession session) {
    return Column(
      children: [
        _controls(l10n),
        if (_failure.isNotEmpty) _errorBanner(l10n, session),
        Expanded(child: _content(l10n)),
      ],
    );
  }

  Widget _controls(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spaceMd,
        AppTheme.spaceMd,
        AppTheme.spaceMd,
        AppTheme.spaceSm,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _year,
                  decoration: InputDecoration(labelText: l10n.gradesYear),
                  items: [
                    for (final y in _recentYears())
                      DropdownMenuItem(value: y, child: Text(y)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _year = v);
                    _fetch();
                  },
                ),
              ),
              const SizedBox(width: AppTheme.spaceSm),
              SizedBox(
                width: 92,
                child: TextField(
                  controller: _xqm,
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    labelText: l10n.gradesTerm,
                    hintText: '3',
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _fetch(),
                ),
              ),
              const SizedBox(width: AppTheme.spaceSm),
              IconButton.filledTonal(
                onPressed: _busy ? null : _fetch,
                tooltip: l10n.gradesFetch,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(AppLocalizations l10n, WhuSession session) {
    final unauthorized = session.hasTgc == false || _isSessionError();
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spaceSm),
        child: Row(
          children: [
            const Icon(Icons.error_outline, size: 18),
            const SizedBox(width: AppTheme.spaceSm),
            Expanded(
              child: Text(
                unauthorized ? l10n.signInNoGrant : _failure,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (unauthorized)
              TextButton(
                onPressed: _signIn,
                child: Text(l10n.signInRefresh),
              ),
          ],
        ),
      ),
    );
  }

  bool _isSessionError() =>
      _failure.toLowerCase().contains('session') ||
      _failure.toLowerCase().contains('sign-in') ||
      _failure.toLowerCase().contains('ticket');

  Widget _content(AppLocalizations l10n) {
    if (_busy && _result == null) return const CenterLoader();

    final r = _result;
    if (r == null) {
      return EmptyState(
        title: l10n.gradesTitle,
        body: l10n.gradesFetch,
        icon: Icons.assignment_outlined,
      );
    }

    return r.fold(
      (sheet) => sheet.isEmpty
          ? EmptyState(
              title: l10n.gradesEmpty,
              body: sheet.envelope.isEmpty
                  ? l10n.gradesYear
                  : '${l10n.gradesYear} ${sheet.year}',
              icon: Icons.assignment_outlined,
            )
          : _sheetView(l10n, sheet),
      (failure) => ErrorState(failure: failure, onRetry: _fetch),
    );
  }

  Widget _sheetView(AppLocalizations l10n, GradeSheet sheet) {
    final text = Theme.of(context).textTheme;
    final mean = sheet.weightedMean();

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spaceMd,
        0,
        AppTheme.spaceMd,
        AppTheme.spaceXl,
      ),
      children: [
        if (sheet.truncated) ...[
          const SizedBox(height: AppTheme.spaceSm),
          // Distinct tokens on purpose: two `%d` would both be replaced by the
          // first replaceAll, silently showing the total twice.
          Text(
            l10n.gradesTruncated
                .replaceAll('%d', '${sheet.returnedCount}')
                .replaceAll('%s', '${sheet.total}'),
            style: text.bodySmall,
          ),
        ],
        const SizedBox(height: AppTheme.spaceSm),
        Panel(
          child: Wrap(
            spacing: AppTheme.spaceLg,
            runSpacing: AppTheme.spaceSm,
            children: [
              _stat(l10n.gradesTermCount
                  .replaceAll('%d', '${sheet.returnedCount}')),
              _stat('${l10n.gradesCreditTotal} ${sheet.creditTotal}'),
              if (mean != null)
                _stat('${l10n.gradesWeightedMean} ${mean.toStringAsFixed(1)}'),
            ],
          ),
        ),
        const SizedBox(height: AppTheme.spaceSm),
        for (final r in sheet.records) _record(l10n, r),
      ],
    );
  }

  Widget _stat(String s) =>
      Text(s, style: Theme.of(context).textTheme.titleSmall);

  Widget _record(AppLocalizations l10n, GradeRecord r) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final scoreColour = r.score == null
        ? scheme.onSurfaceVariant
        : (r.score! >= 60 ? scheme.primary : scheme.error);

    return Panel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.name, style: text.titleSmall),
                const SizedBox(height: 4),
                Text(
                  [
                    if (r.teacher.isNotEmpty) r.teacher,
                    if (r.department.isNotEmpty) r.department,
                    if (r.courseNature.isNotEmpty) r.courseNature,
                    if (r.credits != null) '${l10n.gradesCredits} ${r.credits}',
                  ].join(' · '),
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.spaceSm),
          Text(
            r.scoreText.isEmpty ? '—' : r.scoreText,
            style: text.titleMedium?.copyWith(
              color: scoreColour,
              // A non-numeric outcome (免修/缺考/合格) must not be styled as a
              // pass or fail; only numbers carry colour.
              fontWeight: r.hasNumericScore ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  /// Five academic years ending with the current one.
  List<String> _recentYears() {
    final start = DateTime.now().month >= 8
        ? DateTime.now().year
        : DateTime.now().year - 1;
    return [for (var i = 0; i < 5; i++) '${start - i}-${start - i + 1}'];
  }
}
