import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/result.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../main.dart';
import 'review_drafts.dart';

/// 评价草稿 — write a course evaluation before the timed page opens.
class ReviewDraftsScreen extends StatefulWidget {
  const ReviewDraftsScreen({super.key});

  @override
  State<ReviewDraftsScreen> createState() => _ReviewDraftsScreenState();
}

class _ReviewDraftsScreenState extends State<ReviewDraftsScreen> {
  List<ReviewDraft> _drafts = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result =
        await AppScope.of(context, dependOn: false).reviewDrafts.list();
    if (!mounted) return;
    setState(() {
      _drafts = result.dataOrNull ?? const [];
      _loading = false;
    });
  }

  Future<void> _edit(AppLocalizations l10n, {ReviewDraft? draft}) async {
    final edited = await showDialog<ReviewDraft>(
      context: context,
      builder: (_) => _DraftEditor(
        l10n: l10n,
        initial: draft,
        id: draft?.id ??
            'r${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      ),
    );
    if (edited == null || !mounted) return;

    final result = await AppScope.of(context, dependOn: false)
        .reviewDrafts
        .upsert(edited);
    if (!mounted) return;
    if (result is Failure) {
      _message(result.errorOrNull?.message ?? '');
      return;
    }
    setState(() => _drafts = result.requireValue);
  }

  Future<void> _remove(ReviewDraft draft) async {
    final result = await AppScope.of(context, dependOn: false)
        .reviewDrafts
        .remove(draft.id);
    if (!mounted) return;
    if (result is Success) setState(() => _drafts = result.requireValue);
  }

  Future<void> _copy(AppLocalizations l10n, ReviewDraft draft) async {
    await Clipboard.setData(ClipboardData(text: draft.asText));
    if (!mounted) return;
    _message(l10n.draftsCopied);
  }

  void _message(String text) {
    if (text.isEmpty) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.draftsTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(l10n),
        icon: const Icon(Icons.add),
        label: Text(l10n.draftsNew),
      ),
      body: _loading
          ? const CenterLoader()
          : _drafts.isEmpty
              ? EmptyState(
                  title: l10n.draftsEmpty,
                  body: l10n.draftsEmptyBody,
                  icon: Icons.rate_review_outlined,
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppTheme.spaceMd,
                    AppTheme.spaceSm,
                    AppTheme.spaceMd,
                    96,
                  ),
                  children: [
                    Text(l10n.draftsIntro,
                        style: text.bodySmall
                            ?.copyWith(color: scheme.outline)),
                    const SizedBox(height: AppTheme.spaceSm),
                    for (final draft in _drafts)
                      Card(
                        child: InkWell(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusSm),
                          onTap: () => _edit(l10n, draft: draft),
                          child: Padding(
                            padding: const EdgeInsets.all(AppTheme.spaceMd),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        draft.courseName,
                                        style: text.titleMedium,
                                      ),
                                    ),
                                    if (draft.rating > 0)
                                      Text(
                                        '★' * draft.rating,
                                        style: text.bodyMedium?.copyWith(
                                          color: scheme.tertiary,
                                        ),
                                      ),
                                  ],
                                ),
                                if (draft.teacher.isNotEmpty)
                                  Text(draft.teacher,
                                      style: text.bodySmall
                                          ?.copyWith(color: scheme.outline)),
                                if (draft.text.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    draft.text,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.bodyMedium,
                                  ),
                                ],
                                const SizedBox(height: AppTheme.spaceXs),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    TextButton.icon(
                                      onPressed: () => _copy(l10n, draft),
                                      icon: const Icon(Icons.copy_all_outlined,
                                          size: 18),
                                      label: Text(l10n.draftsCopy),
                                    ),
                                    IconButton(
                                      tooltip: l10n.delete,
                                      icon: const Icon(
                                          Icons.delete_outline,
                                          size: 20),
                                      onPressed: () => _remove(draft),
                                    ),
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

class _DraftEditor extends StatefulWidget {
  const _DraftEditor({
    required this.l10n,
    required this.id,
    this.initial,
  });

  final AppLocalizations l10n;
  final String id;
  final ReviewDraft? initial;

  @override
  State<_DraftEditor> createState() => _DraftEditorState();
}

class _DraftEditorState extends State<_DraftEditor> {
  late final TextEditingController _course =
      TextEditingController(text: widget.initial?.courseName ?? '');
  late final TextEditingController _teacher =
      TextEditingController(text: widget.initial?.teacher ?? '');
  late final TextEditingController _text =
      TextEditingController(text: widget.initial?.text ?? '');
  late int _rating = widget.initial?.rating ?? 0;
  String _error = '';

  @override
  void dispose() {
    _course.dispose();
    _teacher.dispose();
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final course = _course.text.trim();
    if (course.isEmpty) {
      setState(() => _error = widget.l10n.draftsNeedCourse);
      return;
    }
    Navigator.of(context).pop(
      ReviewDraft(
        id: widget.id,
        courseName: course,
        teacher: _teacher.text.trim(),
        rating: _rating,
        text: _text.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Text(widget.initial == null ? l10n.draftsNew : l10n.draftsEdit),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _course,
                decoration:
                    InputDecoration(labelText: l10n.draftsCourse),
              ),
              TextField(
                controller: _teacher,
                decoration:
                    InputDecoration(labelText: l10n.draftsTeacher),
              ),
              const SizedBox(height: AppTheme.spaceSm),
              Row(
                children: [
                  Text(l10n.draftsRating),
                  const SizedBox(width: AppTheme.spaceSm),
                  for (var star = 1; star <= 5; star++)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '$star',
                      icon: Icon(
                        star <= _rating ? Icons.star : Icons.star_border,
                        color: scheme.tertiary,
                      ),
                      onPressed: () => setState(() => _rating = star),
                    ),
                ],
              ),
              TextField(
                controller: _text,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: l10n.draftsText,
                  alignLabelWithHint: true,
                ),
              ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: AppTheme.spaceXs),
                Text(
                  _error,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _save, child: Text(l10n.draftsSave)),
      ],
    );
  }
}
