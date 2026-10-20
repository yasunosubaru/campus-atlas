import 'package:flutter/material.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/result.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../main.dart';
import 'agenda_repository.dart';

/// Local task list with due dates and repetition.
class AgendaScreen extends StatefulWidget {
  const AgendaScreen({super.key});

  @override
  State<AgendaScreen> createState() => _AgendaScreenState();
}

class _AgendaScreenState extends State<AgendaScreen> {
  final _controller = TextEditingController();
  Result<List<AgendaItem>> _items = const Success([]);
  bool _loading = true;

  DateTime? _dueDate;
  RepeatRule _repeat = RepeatRule.none;
  DateTime? _repeatUntil;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final services = AppScope.of(context, dependOn: false);
    final result = await services.agenda.list();
    if (!mounted) return;
    setState(() {
      _items = result;
      _loading = false;
    });
  }

  Future<void> _add() async {
    final l10n = AppLocalizations.of(context);
    final title = _controller.text;
    if (title.trim().isEmpty) return;
    if (_repeat != RepeatRule.none && _dueDate == null) {
      _showText(l10n.agendaNeedDate);
      return;
    }

    final services = AppScope.of(context, dependOn: false);
    final result = await services.agenda.create(
      title,
      dueDate: _dueDate,
      repeat: _repeat,
      repeatUntil: _repeatUntil,
    );
    if (!mounted) return;
    if (result is Success) {
      _controller.clear();
      setState(() {
        _items = result;
        _dueDate = null;
        _repeat = RepeatRule.none;
        _repeatUntil = null;
      });
    } else {
      _showError(result);
    }
  }

  Future<void> _toggle(AgendaItem item) async {
    final services = AppScope.of(context, dependOn: false);
    final result = await services.agenda.toggle(item.id);
    if (mounted && result is Success) setState(() => _items = result);
  }

  Future<void> _remove(AgendaItem item) async {
    final services = AppScope.of(context, dependOn: false);
    final result = await services.agenda.remove(item.id);
    if (mounted && result is Success) setState(() => _items = result);
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _dueDate = DateTime(picked.year, picked.month, picked.day);
      // A repeat end before the start makes no sense; drop it.
      if (_repeatUntil != null && _repeatUntil!.isBefore(_dueDate!)) {
        _repeatUntil = null;
      }
    });
  }

  Future<void> _pickRepeatUntil() async {
    final start = _dueDate ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _repeatUntil ?? start,
      firstDate: start,
      lastDate: DateTime(start.year + 5),
    );
    if (picked == null || !mounted) return;
    setState(() => _repeatUntil = DateTime(picked.year, picked.month, picked.day));
  }

  void _showText(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showError(Result<List<AgendaItem>> result) {
    final l10n = AppLocalizations.of(context);
    _showText(l10n.errorFor(result.errorOrNull?.kind.name ?? 'unknown'));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    final items =
        _items is Success ? _items.requireValue : const <AgendaItem>[];
    final doneCount = items.where((e) => e.done).length;
    final sorted = [...items]..sort(_compare);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.agendaTitle)),
      body: Column(
        children: [
          Padding(
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
                      child: TextField(
                        controller: _controller,
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          hintText: l10n.agendaPlaceholder,
                          prefixIcon: const Icon(Icons.edit_outlined),
                        ),
                        onSubmitted: (_) => _add(),
                      ),
                    ),
                    const SizedBox(width: AppTheme.spaceSm),
                    FilledButton(
                      onPressed: _add,
                      child: Text(l10n.agendaAdd),
                    ),
                  ],
                ),
                const SizedBox(height: AppTheme.spaceSm),
                Wrap(
                  spacing: AppTheme.spaceSm,
                  runSpacing: AppTheme.spaceXs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    InputChip(
                      avatar: const Icon(Icons.event_outlined, size: 18),
                      label: Text(
                        _dueDate == null
                            ? l10n.agendaNoDue
                            : '${l10n.agendaDue} ${_shortDate(_dueDate!)}',
                      ),
                      onPressed: _pickDue,
                      onDeleted: _dueDate == null
                          ? null
                          : () => setState(() => _dueDate = null),
                      deleteIcon: const Icon(Icons.close, size: 16),
                    ),
                    DropdownButton<RepeatRule>(
                      value: _repeat,
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final rule in RepeatRule.values)
                          DropdownMenuItem(
                            value: rule,
                            child: Text(_repeatLabel(rule, l10n)),
                          ),
                      ],
                      onChanged: (rule) => setState(() {
                        _repeat = rule ?? RepeatRule.none;
                        if (_repeat == RepeatRule.none) _repeatUntil = null;
                      }),
                    ),
                    if (_repeat != RepeatRule.none)
                      ActionChip(
                        avatar: const Icon(Icons.event_repeat, size: 18),
                        label: Text(
                          _repeatUntil == null
                              ? l10n.agendaRepeatUntil
                              : '${l10n.agendaRepeatUntil} '
                                  '${_shortDate(_repeatUntil!)}',
                        ),
                        onPressed: _pickRepeatUntil,
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppTheme.spaceMd),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.agendaCompletedCount.replaceAll('%d', '$doneCount'),
                  style: text.bodySmall,
                ),
              ),
            ),
          Expanded(
            child: _loading
                ? const CenterLoader()
                : _items is Failure
                    ? ErrorState(failure: _items, onRetry: _load)
                    : items.isEmpty
                        ? EmptyState(
                            title: l10n.emptyTitle,
                            body: l10n.agendaHint,
                            icon: Icons.checklist_outlined,
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(
                              AppTheme.spaceMd,
                              AppTheme.spaceSm,
                              AppTheme.spaceMd,
                              AppTheme.spaceXl,
                            ),
                            itemCount: sorted.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: AppTheme.spaceSm),
                            itemBuilder: (context, i) {
                              final item = sorted[i];
                              final subtitle = _subtitle(item, l10n);
                              return Card(
                                child: CheckboxListTile(
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  value: item.done,
                                  activeColor: scheme.primary,
                                  title: Text(
                                    item.title,
                                    style: text.bodyLarge?.copyWith(
                                      decoration: item.done
                                          ? TextDecoration.lineThrough
                                          : null,
                                      color: item.done ? scheme.outline : null,
                                    ),
                                  ),
                                  subtitle:
                                      subtitle.isEmpty ? null : Text(subtitle),
                                  onChanged: (_) => _toggle(item),
                                  secondary: IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: l10n.delete,
                                    onPressed: () => _remove(item),
                                  ),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }

  /// Open items first, then by the date they are due; undated items last.
  int _compare(AgendaItem a, AgendaItem b) {
    if (a.done != b.done) return a.done ? 1 : -1;
    final ad = a.dueDate;
    final bd = b.dueDate;
    if (ad == null && bd == null) return a.sortOrder.compareTo(b.sortOrder);
    if (ad == null) return 1;
    if (bd == null) return -1;
    return ad.compareTo(bd);
  }

  String _subtitle(AgendaItem item, AppLocalizations l10n) {
    final parts = <String>[];
    final due = item.dueDate;
    if (due != null) parts.add('${l10n.agendaDue} ${_shortDate(due)}');
    if (item.repeat != RepeatRule.none) {
      parts.add(_repeatLabel(item.repeat, l10n));
    }
    final until = item.repeatUntil;
    if (until != null) {
      parts.add('${l10n.agendaRepeatUntil} ${_shortDate(until)}');
    }
    return parts.join(' · ');
  }

  static String _shortDate(DateTime date) => '${date.month}-${date.day}';

  static String _repeatLabel(RepeatRule rule, AppLocalizations l10n) =>
      switch (rule) {
        RepeatRule.none => l10n.agendaRepeatNone,
        RepeatRule.daily => l10n.agendaRepeatDaily,
        RepeatRule.weekly => l10n.agendaRepeatWeekly,
        RepeatRule.monthly => l10n.agendaRepeatMonthly,
      };
}
