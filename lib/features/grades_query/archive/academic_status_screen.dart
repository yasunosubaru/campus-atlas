import 'package:flutter/material.dart';

import '../../../core/i18n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../../main.dart';
import 'academic_status.dart';
import 'gpa.dart';
import 'grade_archive_screen.dart';
import 'grade_models.dart';

/// 学业状态 — the credit and GPA picture, computed natively.
///
/// The school's own 学业情况 page is a browser page behind the same sign-in and
/// puzzle as the grade query. Everything this screen shows is derived from the
/// grades already read into the local archive, so it works offline and does not
/// claim to know a graduation requirement it was not told: the progress bar
/// appears only after the person sets one.
class AcademicStatusScreen extends StatefulWidget {
  const AcademicStatusScreen({super.key});

  @override
  State<AcademicStatusScreen> createState() => _AcademicStatusScreenState();
}

class _AcademicStatusScreenState extends State<AcademicStatusScreen> {
  List<GradeRecord> _rows = const [];
  GpaStandard _standard = GpaStandard.whu;
  double? _target;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final services = AppScope.of(context, dependOn: false);
    final standardId = await services.settings.gpaStandard();
    final target = await services.settings.requiredCredits();
    final loaded = await services.gradeArchive.load();
    if (!mounted) return;
    setState(() {
      _standard = GpaStandard.fromId(standardId);
      _target = target;
      _rows = loaded.dataOrNull ?? const [];
      _busy = false;
    });
  }

  Future<void> _editTarget(AppLocalizations l10n) async {
    final controller = TextEditingController(
      text: _target == null ? '' : _format(_target!),
    );
    final value = await showDialog<double>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.statusSetTarget),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: l10n.statusTargetHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              final parsed = double.tryParse(controller.text.trim());
              Navigator.of(dialog).pop(parsed);
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value <= 0 || !mounted) {
      if (value != null && value <= 0 && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.statusTargetInvalid)));
      }
      return;
    }

    await AppScope.of(context, dependOn: false)
        .settings
        .setRequiredCredits(value);
    if (!mounted) return;
    setState(() => _target = value);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.statusSaved)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.statusTitle)),
      body: _busy
          ? const CenterLoader()
          : _rows.isEmpty
              ? EmptyState(
                  title: l10n.statusEmpty,
                  body: l10n.statusEmptyBody,
                  icon: Icons.workspace_premium_outlined,
                )
              : _content(l10n),
    );
  }

  Widget _content(AppLocalizations l10n) {
    final status = computeAcademicStatus(_rows, _standard, target: _target);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.all(AppTheme.spaceMd),
      children: [
        Text(l10n.statusIntro, style: theme.textTheme.bodySmall),
        const SizedBox(height: AppTheme.spaceMd),
        _headline(l10n, status),
        const SizedBox(height: AppTheme.spaceMd),
        _targetPanel(l10n, status),
        const SizedBox(height: AppTheme.spaceMd),
        SectionHeader(l10n.statusCreditsByKind),
        Panel(
          child: Builder(builder: (context) {
            final groups = [
              status.requiredCredits,
              status.electiveCredits,
              status.otherCredits,
            ];
            final maximum = groups.reduce((a, b) => a > b ? a : b);
            return Column(
              children: [
                _groupRow(l10n.statusKindRequired, status.requiredCredits,
                    maximum, scheme.primary),
                const SizedBox(height: AppTheme.spaceSm),
                _groupRow(l10n.statusKindElective, status.electiveCredits,
                    maximum, scheme.tertiary),
                const SizedBox(height: AppTheme.spaceSm),
                _groupRow(l10n.statusKindOther, status.otherCredits, maximum,
                    scheme.outline),
              ],
            );
          }),
        ),
        const SizedBox(height: AppTheme.spaceMd),
        SectionHeader(l10n.statusTerms),
        Panel(
          child: Column(
            children: [
              for (final term in status.terms)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child:
                            Text(term.label, style: theme.textTheme.bodyMedium),
                      ),
                      Text(
                        l10n.statusTermLine
                            .replaceAll('%s', _format(term.credits))
                            .replaceAll(
                              '%g',
                              term.summary.value == null
                                  ? '—'
                                  : term.summary.value!.toStringAsFixed(2),
                            ),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppTheme.spaceMd),
        SectionHeader(l10n.statusFailedTitle),
        Panel(
          child: status.failed.isEmpty
              ? Text(l10n.statusNoFailed, style: theme.textTheme.bodyMedium)
              : Column(
                  children: [
                    for (final row in status.failed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${row.courseName} · ${row.termLabel}',
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                            Text(
                              row.scoreText,
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(color: scheme.error),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: AppTheme.spaceSm),
        TextButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const GradeArchiveScreen(),
            ),
          ),
          icon: const Icon(Icons.insights_outlined),
          label: Text(l10n.statusArchive),
        ),
      ],
    );
  }

  Widget _headline(AppLocalizations l10n, AcademicStatus status) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final weighted = _standard == GpaStandard.weighted;
    final value = status.summary.value;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            weighted ? l10n.statusWeighted : l10n.statusGpa,
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: AppTheme.spaceXs),
          Text(
            value == null ? '—' : value.toStringAsFixed(2),
            style: theme.textTheme.displaySmall?.copyWith(
              color: scheme.primary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: AppTheme.spaceSm),
          Wrap(
            spacing: AppTheme.spaceSm,
            runSpacing: AppTheme.spaceXs,
            children: [
              _chip(
                  l10n.statusPassed,
                  '${_format(status.passedCredits)} / '
                  '${_format(status.attemptedCredits)}'),
              _chip(l10n.statusFailed, '${status.failed.length}'),
              _chip(l10n.statusTerms, '${status.terms.length}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Text(
        '$label $value',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  Widget _targetPanel(AppLocalizations l10n, AcademicStatus status) {
    final theme = Theme.of(context);
    final progress = status.progress;
    final target = status.target;

    if (progress == null || target == null) {
      return Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.statusNoTarget, style: theme.textTheme.bodySmall),
            const SizedBox(height: AppTheme.spaceXs),
            TextButton(
              onPressed: () => _editTarget(l10n),
              child: Text(l10n.statusSetTarget),
            ),
          ],
        ),
      );
    }

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(l10n.statusProgress,
                    style: theme.textTheme.labelLarge),
              ),
              TextButton(
                onPressed: () => _editTarget(l10n),
                child: Text(l10n.statusSetTarget),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spaceXs),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: AppTheme.spaceXs),
          Text(
            l10n.statusProgressLine
                .replaceAll('%s', '${(progress * 100).round()}')
                .replaceAll('%p', _format(status.passedCredits))
                .replaceAll('%t', _format(target)),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _groupRow(
    String label,
    double credits,
    double maximum,
    Color colour,
  ) {
    final theme = Theme.of(context);
    // Bars are relative to the largest group, not to the total: a group's share
    // of the total is unreadable when most credits sit in one bucket.
    final ratio = maximum > 0 ? (credits / maximum).clamp(0.0, 1.0) : 0.0;

    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(label, style: theme.textTheme.bodyMedium),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              color: colour,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
        const SizedBox(width: AppTheme.spaceSm),
        SizedBox(
          width: 48,
          child: Text(
            _format(credits),
            textAlign: TextAlign.right,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

String _format(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);
