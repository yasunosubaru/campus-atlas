import 'package:flutter/material.dart';

import '../../../core/i18n/app_localizations.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../../main.dart';
import '../../whu_auth/account_login_screen.dart';
import '../../whu_auth/whu_endpoints.dart' show WhuTerm;
import '../../whu_auth/whu_session.dart';
import '../timetable_models.dart';
import 'jwgl_timetable_browser.dart';
import 'jwgl_timetable_parser.dart';
import 'jwgl_timetable_repository.dart';

/// What the import sheet hands back: the courses plus the semester they came
/// from.
///
/// The year and term travel with the courses because the caller has to move the
/// week anchor with the data. Returning courses alone let a fall import be
/// stored and then drawn against the spring anchor, which looks exactly like a
/// failed import.
class TimetableImportOutcome {
  const TimetableImportOutcome({
    required this.courses,
    required this.year,
    required this.term,
  });

  final List<Course> courses;
  final String year;
  final WhuTerm term;
}

/// The import sheet: pick a channel, read, review, apply.
///
/// Returns the courses to install, or null when dismissed. The caller owns the
/// "replace this timetable" decision, because only it knows which timetable is
/// active.
class TimetableImportSheet extends StatefulWidget {
  const TimetableImportSheet({
    super.key,
    required this.client,
    required this.initialSession,
  });

  final ApiClient client;
  final WhuSession? initialSession;

  @override
  State<TimetableImportSheet> createState() => _TimetableImportSheetState();
}

class _TimetableImportSheetState extends State<TimetableImportSheet> {
  late final TextEditingController _year =
      TextEditingController(text: _defaultYear());
  WhuTerm _term = WhuTerm.first;

  WhuSession? _session;
  bool _busy = false;
  TimetableImport? _result;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _session = widget.initialSession;
  }

  @override
  void dispose() {
    _year.dispose();
    super.dispose();
  }

  /// The academic year that has started most recently: September rolls over.
  static String _defaultYear() {
    final now = DateTime.now();
    return '${now.month >= 9 ? now.year : now.year - 1}';
  }

  Future<void> _signIn() async {
    await AccountLoginScreen.push(context);
    if (!mounted) return;
    setState(
      () => _session = AppScope.of(context, dependOn: false).whuSession,
    );
  }

  Future<void> _run() async {
    final repository = JwglTimetableRepository(
      client: widget.client,
      session: _session,
    );
    setState(() {
      _busy = true;
      _error = '';
      _result = null;
    });

    final result = await repository.fetch(year: _year.text, term: _term.code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result.dataOrNull;
      _error = result.errorOrNull?.message ?? '';
    });
  }

  Future<void> _browserImport() async {
    final page = await JwglTimetableBrowserScreen.push(context);
    if (!mounted || page == null) return;
    setState(() {
      _result = TimetableImport(
        courses: page.courses,
        skipped: page.skipped,
        problems: page.problems,
      );
      _error = '';
      // The page's own year and term win: the person may have chosen a
      // different term in the page, and the week anchor that follows the
      // import has to match the courses that were actually read.
      if (page.year != null && page.year!.isNotEmpty) {
        _year.text = page.year!;
      }
      if (page.term != null) {
        _term = page.term!;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        left: AppTheme.spaceMd,
        right: AppTheme.spaceMd,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppTheme.spaceLg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.ttImportTitle, style: text.titleLarge),
            const SizedBox(height: AppTheme.spaceXs),
            Text(
              l10n.ttImportUnverified,
              style: text.bodySmall?.copyWith(color: scheme.outline),
            ),
            const SizedBox(height: AppTheme.spaceMd),
            _channel(
              context,
              icon: Icons.school_outlined,
              title: l10n.ttImportChannelJwgl,
              note: l10n.ttImportChannelJwglNote,
              enabled: true,
            ),
            const SizedBox(height: AppTheme.spaceSm),
            _channel(
              context,
              icon: Icons.science_outlined,
              title: l10n.ttImportChannelYjs,
              note: l10n.ttImportChannelYjsNote,
              enabled: false,
            ),
            const SizedBox(height: AppTheme.spaceMd),
            if (_session == null)
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.ttImportNeedSession),
                    const SizedBox(height: AppTheme.spaceSm),
                    FilledButton.icon(
                      onPressed: _signIn,
                      icon: const Icon(Icons.login_rounded),
                      label: Text(l10n.signInTitle),
                    ),
                  ],
                ),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _year,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: l10n.ttImportYear),
                    ),
                  ),
                  const SizedBox(width: AppTheme.spaceSm),
                  Expanded(
                    child: DropdownButtonFormField<WhuTerm>(
                      initialValue: _term,
                      decoration: InputDecoration(labelText: l10n.ttImportTerm),
                      items: [
                        for (final term in WhuTerm.values)
                          DropdownMenuItem(
                            value: term,
                            child: Text(term.label),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => _term = value ?? WhuTerm.first),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.spaceSm),
              FilledButton.icon(
                onPressed: _busy ? null : _run,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined),
                label: Text(l10n.ttImportRun),
              ),
              const SizedBox(height: AppTheme.spaceXs),
              OutlinedButton.icon(
                onPressed: _busy ? null : _browserImport,
                icon: const Icon(Icons.travel_explore_rounded),
                label: Text(l10n.ttImportBrowser),
              ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: AppTheme.spaceSm),
                Text(
                  _error,
                  style: text.bodySmall?.copyWith(color: scheme.error),
                ),
              ],
              if (_result != null) ...[
                const SizedBox(height: AppTheme.spaceMd),
                _preview(l10n),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _channel(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String note,
    required bool enabled,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final colour = enabled ? scheme.primary : scheme.outline;

    return Container(
      padding: const EdgeInsets.all(AppTheme.spaceSm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: enabled ? Border.all(color: colour, width: 1) : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: colour),
          const SizedBox(width: AppTheme.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleSmall?.copyWith(color: colour)),
                const SizedBox(height: 2),
                Text(note, style: text.bodySmall),
              ],
            ),
          ),
          if (enabled)
            Icon(Icons.check_circle, size: 18, color: scheme.primary),
        ],
      ),
    );
  }

  Widget _preview(AppLocalizations l10n) {
    final result = _result!;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    if (result.isEmpty) {
      return Panel(
        child: Text(l10n.ttImportEmpty, style: text.bodyMedium),
      );
    }

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.ttImportPreview.replaceAll('%d', '${result.courses.length}'),
            style: text.titleSmall,
          ),
          if (result.skipped > 0)
            Text(
              l10n.ttImportSkipped.replaceAll('%d', '${result.skipped}'),
              style: text.bodySmall?.copyWith(color: scheme.outline),
            ),
          if (result.problems.isNotEmpty) ...[
            const SizedBox(height: AppTheme.spaceXs),
            for (final problem in result.problems)
              Text(problem,
                  style: text.bodySmall?.copyWith(color: scheme.outline)),
          ],
          const SizedBox(height: AppTheme.spaceSm),
          for (final course in result.courses.take(6))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${l10n.ttWeekdays.split(',')[course.weekday - 1]} · '
                '${course.startPeriod}-${course.endPeriod} · '
                '${course.name} · ${formatWeeks(course.weeks)}'
                '${course.location.isEmpty ? '' : ' · ${course.location}'}',
                style: text.bodySmall,
              ),
            ),
          if (result.courses.length > 6)
            Text('…', style: text.bodySmall?.copyWith(color: scheme.outline)),
          const SizedBox(height: AppTheme.spaceSm),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(
              TimetableImportOutcome(
                courses: result.courses,
                year: _year.text.trim(),
                term: _term,
              ),
            ),
            icon: const Icon(Icons.save_alt),
            label: Text(l10n.ttImportApply),
          ),
        ],
      ),
    );
  }
}
