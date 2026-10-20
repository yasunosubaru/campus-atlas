import 'package:flutter/material.dart';

import '../../../core/i18n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../../main.dart';
import 'gpa.dart';
import 'grade_import.dart' show scoreFromText;
import 'grade_models.dart';

/// 成绩档案与统计 — the local half of the grades feature.
///
/// No sign-in, no network: everything on this screen comes from grades a person
/// already read out of the academic system, kept on this machine by
/// [GradeArchiveRepository]. That is deliberate — the school's page is the only
/// honest source, and it is behind a puzzle, so the app reads it once and then
/// answers GPA and trend questions locally.
class GradeArchiveScreen extends StatefulWidget {
  const GradeArchiveScreen({super.key});

  @override
  State<GradeArchiveScreen> createState() => _GradeArchiveScreenState();
}

class _GradeArchiveScreenState extends State<GradeArchiveScreen> {
  List<GradeRecord> _rows = const [];
  bool _busy = true;
  GpaStandard _standard = GpaStandard.whu;
  GradeScope _scope = GradeScope.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final services = AppScope.of(context, dependOn: false);
    final standardId = await services.settings.gpaStandard();
    final requiredOnly = await services.settings.gpaRequiredOnly();
    final loaded = await services.gradeArchive.load();
    if (!mounted) return;
    setState(() {
      _standard = GpaStandard.fromId(standardId);
      _scope = requiredOnly ? GradeScope.requiredOnly : GradeScope.all;
      _rows = loaded.dataOrNull ?? const <GradeRecord>[];
      _busy = false;
    });
  }

  void _selectStandard(GpaStandard standard) {
    setState(() => _standard = standard);
    AppScope.of(context, dependOn: false).settings.setGpaStandard(standard.id);
  }

  void _setRequiredOnly(bool required) {
    setState(
        () => _scope = required ? GradeScope.requiredOnly : GradeScope.all);
    AppScope.of(context, dependOn: false).settings.setGpaRequiredOnly(required);
  }

  /// Opens the manual-entry dialog and merges what it returns.
  ///
  /// The manual channel exists because not every grade lives in the 教务 table
  /// this app reads — a transfer credit, a course taken elsewhere. Its rows are
  /// marked as manual so they can be told apart from imported ones and removed
  /// again, which imported rows do not need: re-reading the table is their fix.
  Future<void> _addManually(AppLocalizations l10n) async {
    final record = await showDialog<GradeRecord>(
      context: context,
      builder: (dialog) => _ManualGradeDialog(
        l10n: l10n,
        latest:
            _rows.isEmpty ? null : ([..._rows]..sort(GradeRecord.compare)).last,
      ),
    );
    if (record == null || !mounted) return;

    final merged = await AppScope.of(context, dependOn: false)
        .gradeArchive
        .merge([record]);
    if (!mounted) return;

    final failure = merged.errorOrNull;
    if (failure != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.message)),
      );
      return;
    }

    // Reload rather than appending: a manual row that shares a key with an
    // imported one *replaces* it in storage, so appending would draw the course
    // twice until the next load.
    final loaded =
        await AppScope.of(context, dependOn: false).gradeArchive.load();
    if (!mounted) return;
    setState(() => _rows = loaded.dataOrNull ?? _rows);

    final updated = merged.requireValue.added == 0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          (updated ? l10n.archiveUpdated : l10n.archiveAdded)
              .replaceFirst('%s', record.courseName),
        ),
      ),
    );
  }

  Future<void> _removeRow(GradeRecord row, AppLocalizations l10n) async {
    final remaining = await AppScope.of(context, dependOn: false)
        .gradeArchive
        .remove(row.key);
    if (!mounted) return;

    final next = remaining.dataOrNull;
    if (next == null) {
      final failure = remaining.errorOrNull;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure?.message ?? '')),
      );
      return;
    }
    setState(() => _rows = next);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.archiveRemoved.replaceFirst('%s', row.courseName)),
      ),
    );
  }

  Future<void> _clear(AppLocalizations l10n) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.archiveClear),
        content: Text(l10n.archiveClearBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await AppScope.of(context, dependOn: false).gradeArchive.clear();
    if (!mounted) return;
    setState(() => _rows = const []);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.archiveCleared)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.archiveTitle)),
      body: _busy
          ? const CenterLoader()
          : _rows.isEmpty
              ? EmptyState(
                  title: l10n.archiveEmpty,
                  body: l10n.archiveEmptyBody,
                  icon: Icons.insights_outlined,
                )
              : _content(l10n),
    );
  }

  Widget _content(AppLocalizations l10n) {
    final summary = summarizeGrades(_rows, _standard, scope: _scope);
    final terms = termStats(_rows, _standard, scope: _scope);

    return ListView(
      padding: const EdgeInsets.all(AppTheme.spaceMd),
      children: [
        Text(l10n.archiveIntro, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: AppTheme.spaceMd),
        _standardPicker(l10n),
        const SizedBox(height: AppTheme.spaceSm),
        Wrap(
          spacing: AppTheme.spaceSm,
          runSpacing: AppTheme.spaceXs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilterChip(
              label: Text(l10n.archiveRequiredOnly),
              selected: _scope == GradeScope.requiredOnly,
              onSelected: _setRequiredOnly,
            ),
            ActionChip(
              avatar: const Icon(Icons.add_rounded, size: 18),
              label: Text(l10n.archiveAdd),
              onPressed: () => _addManually(l10n),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.spaceMd),
        _summaryPanel(l10n, summary),
        const SizedBox(height: AppTheme.spaceMd),
        if (terms.length >= 2)
          _trendPanel(l10n, terms)
        else
          Panel(
            child: Row(
              children: [
                Icon(Icons.stacked_line_chart_rounded,
                    size: 20, color: Theme.of(context).colorScheme.outline),
                const SizedBox(width: AppTheme.spaceSm),
                Expanded(
                  child: Text(l10n.archiveTrendNeedTwo,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ],
            ),
          ),
        const SizedBox(height: AppTheme.spaceMd),
        _coursesPanel(l10n),
        const SizedBox(height: AppTheme.spaceSm),
        TextButton.icon(
          onPressed: () => _clear(l10n),
          icon: const Icon(Icons.delete_outline_rounded),
          label: Text(l10n.archiveClear),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
        ),
      ],
    );
  }

  Widget _standardPicker(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.archiveStandard,
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppTheme.spaceSm),
        SegmentedButton<GpaStandard>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: GpaStandard.whu,
              label: Text(l10n.archiveStdWhu),
            ),
            ButtonSegment(
              value: GpaStandard.scale5,
              label: Text(l10n.archiveStdScale5),
            ),
            ButtonSegment(
              value: GpaStandard.weighted,
              label: Text(l10n.archiveStdWeighted),
            ),
          ],
          selected: {_standard},
          onSelectionChanged: (selection) => _selectStandard(selection.first),
        ),
      ],
    );
  }

  Widget _summaryPanel(AppLocalizations l10n, GradeSummary summary) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final weighted = _standard == GpaStandard.weighted;
    final headline = summary.value;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            weighted ? l10n.archiveAvg : l10n.archiveGpa,
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: AppTheme.spaceXs),
          Text(
            headline == null ? '—' : headline.toStringAsFixed(2),
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
              if (!weighted)
                _chip(l10n.archiveChipAvg.replaceAll('%s',
                    summary.isEmpty ? '—' : summary.avg.toStringAsFixed(2))),
              _chip(l10n.archiveChipCredits
                  .replaceAll('%s', _credits(summary.countedCredits))),
              _chip(l10n.archiveChipCounted
                  .replaceAll('%d', '${summary.counted}')),
              _chip(l10n.archiveChipPassed
                  .replaceAll('%s', _credits(summary.passedCredits))),
            ],
          ),
          if (summary.excluded > 0) ...[
            const SizedBox(height: AppTheme.spaceSm),
            Text(
              l10n.archiveExcluded.replaceAll('%d', '${summary.excluded}'),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ],
          if (summary.failed > 0) ...[
            const SizedBox(height: AppTheme.spaceXs),
            Text(
              l10n.archiveFailedCount.replaceAll('%d', '${summary.failed}'),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spaceSm,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }

  Widget _trendPanel(AppLocalizations l10n, List<TermStats> terms) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.archiveTrend, style: theme.textTheme.titleSmall),
          const SizedBox(height: AppTheme.spaceMd),
          SizedBox(
            height: 190,
            width: double.infinity,
            child: CustomPaint(
              painter: _TrendPainter(
                terms: terms,
                maxScale: _standard.maxScale,
                barColor: scheme.primary,
                mutedColor: scheme.outline,
                textStyle:
                    theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: AppTheme.spaceSm),
          for (final term in terms)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.spaceXs),
              child: Row(
                children: [
                  Expanded(
                    child: Text(term.label, style: theme.textTheme.bodyMedium),
                  ),
                  Text(
                    [
                      term.summary.value == null
                          ? '—'
                          : term.summary.value!.toStringAsFixed(2),
                      '${_credits(term.summary.countedCredits)} ${l10n.archiveCreditsUnit}',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _coursesPanel(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Newest first: the question people ask of this list is "what did I get
    // last term", not "what did I take as a freshman".
    final sorted = [..._rows]..sort((a, b) => GradeRecord.compare(b, a));

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.archiveCourses, style: theme.textTheme.titleSmall),
          for (final row in sorted)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.spaceSm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(row.courseName, style: theme.textTheme.bodyMedium),
                        const SizedBox(height: 2),
                        Text(
                          [
                            row.termLabel,
                            if (row.courseKind.isNotEmpty) row.courseKind,
                            '${_credits(row.credits)} ${l10n.archiveCreditsUnit}',
                            if (row.source == 'manual') l10n.archiveManualTag,
                          ].join(' · '),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.outline),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppTheme.spaceSm),
                  Text(
                    row.scoreText.isEmpty ? '—' : row.scoreText,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: passesCourse(row) ? scheme.primary : scheme.error,
                    ),
                  ),
                  if (row.source == 'manual')
                    IconButton(
                      tooltip: l10n.delete,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.remove_circle_outline, size: 18),
                      onPressed: () => _removeRow(row, l10n),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A small bar per term, drawn against the standard's own ceiling.
///
/// Hand-drawn rather than pulling in a chart dependency: one series of a few
/// bars does not justify a package, and the project deliberately keeps its
/// dependency list at what it already uses.
class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.terms,
    required this.maxScale,
    required this.barColor,
    required this.mutedColor,
    required this.textStyle,
  });

  final List<TermStats> terms;
  final double maxScale;
  final Color barColor;
  final Color mutedColor;
  final TextStyle textStyle;

  @override
  void paint(Canvas canvas, Size size) {
    const valueStrip = 18.0;
    const labelStrip = 20.0;
    final plotHeight = size.height - valueStrip - labelStrip;
    if (terms.isEmpty || plotHeight <= 0) return;

    final slot = size.width / terms.length;
    final barWidth = (slot * 0.45).clamp(8.0, 44.0);
    final baseline = valueStrip + plotHeight;
    final barPaint = Paint()..color = barColor;

    canvas.drawRect(
      Rect.fromLTWH(0, baseline, size.width, 1),
      Paint()..color = mutedColor.withValues(alpha: 0.35),
    );

    for (var i = 0; i < terms.length; i++) {
      final value = terms[i].summary.value;
      final centerX = slot * i + slot / 2;

      if (value == null) {
        _text(canvas, '—', centerX, baseline - valueStrip + 2, mutedColor);
      } else {
        final ratio = (value / maxScale).clamp(0.0, 1.0);
        final height = (plotHeight * ratio).clamp(2.0, plotHeight);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
                centerX - barWidth / 2, baseline - height, barWidth, height),
            const Radius.circular(4),
          ),
          barPaint,
        );
        _text(canvas, value.toStringAsFixed(2), centerX,
            baseline - height - valueStrip + 1, barColor);
      }

      _text(canvas, terms[i].shortLabel, centerX, baseline + 3, mutedColor);
    }
  }

  void _text(
    Canvas canvas,
    String text,
    double centerX,
    double top,
    Color color,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: textStyle.copyWith(color: color)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    painter.paint(canvas, Offset(centerX - painter.width / 2, top));
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.terms != terms ||
      old.maxScale != maxScale ||
      old.barColor != barColor ||
      old.mutedColor != mutedColor;
}

String _credits(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);

/// The manual channel's form.
///
/// The fields mirror the academic grid's own columns, so a row typed here and a
/// row read from the page describe a course the same way — and merge by the same
/// key, which means typing over an imported course corrects it rather than
/// duplicating it.
class _ManualGradeDialog extends StatefulWidget {
  const _ManualGradeDialog({required this.l10n, this.latest});

  final AppLocalizations l10n;

  /// The newest archived row, whose term pre-fills the form: people usually add
  /// a grade for the term they are in.
  final GradeRecord? latest;

  @override
  State<_ManualGradeDialog> createState() => _ManualGradeDialogState();
}

class _ManualGradeDialogState extends State<_ManualGradeDialog> {
  late final TextEditingController _year =
      TextEditingController(text: widget.latest?.year ?? '');
  late final TextEditingController _semester =
      TextEditingController(text: widget.latest?.semester ?? '1');
  final TextEditingController _name = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final TextEditingController _teacher = TextEditingController();
  late final TextEditingController _kind =
      TextEditingController(text: widget.latest?.courseKind ?? '必修');
  final TextEditingController _credits = TextEditingController(text: '2');
  final TextEditingController _score = TextEditingController();
  String _error = '';

  @override
  void dispose() {
    for (final controller in [
      _year,
      _semester,
      _name,
      _code,
      _teacher,
      _kind,
      _credits,
      _score,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = widget.l10n.archiveNameRequired);
      return;
    }

    final scoreText = _score.text.trim();
    Navigator.of(context).pop(
      GradeRecord(
        year: _year.text.trim(),
        semester: _semester.text.trim(),
        courseName: name,
        courseCode: _code.text.trim(),
        teacher: _teacher.text.trim(),
        courseKind: _kind.text.trim(),
        credits: double.tryParse(_credits.text.trim()) ?? 0,
        scoreText: scoreText,
        // The same strict parse the import uses: `优秀` stays a level grade and
        // is excluded from the GPA rather than guessed at.
        score: scoreFromText(scoreText),
        source: 'manual',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(l10n.archiveAddTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.archiveEditNote, style: theme.textTheme.bodySmall),
            Row(
              children: [
                Expanded(child: _field(l10n.archiveFieldYear, _year)),
                const SizedBox(width: AppTheme.spaceSm),
                Expanded(child: _field(l10n.archiveFieldSemester, _semester)),
              ],
            ),
            _field(l10n.archiveFieldName, _name),
            Row(
              children: [
                Expanded(child: _field(l10n.archiveFieldCode, _code)),
                const SizedBox(width: AppTheme.spaceSm),
                Expanded(child: _field(l10n.archiveFieldTeacher, _teacher)),
              ],
            ),
            Row(
              children: [
                Expanded(child: _field(l10n.archiveFieldKind, _kind)),
                const SizedBox(width: AppTheme.spaceSm),
                Expanded(
                  child: _field(
                    l10n.archiveFieldCredits,
                    _credits,
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            _field(
              l10n.archiveFieldScore,
              _score,
              keyboardType: TextInputType.text,
              hint: l10n.archiveScoreHint,
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: AppTheme.spaceSm),
              Text(
                _error,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _save, child: Text(l10n.save)),
      ],
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    TextInputType? keyboardType,
    String? hint,
  }) =>
      Padding(
        padding: const EdgeInsets.only(top: AppTheme.spaceSm),
        child: TextField(
          controller: controller,
          keyboardType: keyboardType,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            isDense: true,
          ),
        ),
      );
}
