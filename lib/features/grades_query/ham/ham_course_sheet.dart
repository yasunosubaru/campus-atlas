import 'package:flutter/material.dart';

import '../../../core/i18n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import 'ham_center_models.dart';
import 'ham_center_repository.dart';
import 'ham_mcp_client.dart';
import 'ham_score_models.dart';

/// A course's comments and per-term statistics.
///
/// `get_course_detail` needs a web login (`请重新登录` with a token that reads
/// everything else), so this sheet composes the tools that do work: the
/// distribution already on the card, `get_course_comments`, and
/// `get_semester_grade_stats`.
class HamCourseSheet extends StatefulWidget {
  const HamCourseSheet({
    super.key,
    required this.score,
    this.repository,
    this.apiKey = '',
  });

  final HamCourseScore score;

  /// Injected by tests. When null and [apiKey] is set, the sheet builds its own
  /// repository and closes it on dispose.
  final HamCenterRepository? repository;

  final String apiKey;

  @override
  State<HamCourseSheet> createState() => _HamCourseSheetState();
}

class _HamCourseSheetState extends State<HamCourseSheet> {
  HamCenterRepository? _repository;
  bool _ownsRepository = false;

  HamCommentPage? _comments;
  bool _commentsLoading = true;
  String _commentsError = '';

  HamSemesterStat? _stat;
  bool _statLoading = false;
  String _statError = '';

  late int _year = _defaultYear();
  late int _semester = _defaultSemester();

  @override
  void initState() {
    super.initState();
    _repository = widget.repository;
    if (_repository == null && widget.apiKey.trim().isNotEmpty) {
      _repository = HamCenterRepository(
        gateway: HamMcpGateway(
          HamMcpClient(apiKey: widget.apiKey.trim()),
        ),
      );
      _ownsRepository = true;
    }
    _loadComments();
  }

  @override
  void dispose() {
    if (_ownsRepository) _repository?.close();
    super.dispose();
  }

  static int _defaultYear() {
    final now = DateTime.now();
    return now.month >= 9 ? now.year : now.year - 1;
  }

  static int _defaultSemester() {
    final month = DateTime.now().month;
    if (month >= 9 || month == 1) return 1;
    if (month <= 6) return 2;
    return 3;
  }

  Future<void> _loadComments() async {
    final repository = _repository;
    if (repository == null) {
      setState(() => _commentsLoading = false);
      return;
    }
    setState(() {
      _commentsLoading = true;
      _commentsError = '';
    });
    final result = await repository.comments(widget.score.courseTableId);
    if (!mounted) return;
    setState(() {
      _commentsLoading = false;
      _comments = result.dataOrNull;
      _commentsError = result.errorOrNull?.message ?? '';
    });
  }

  Future<void> _loadStat() async {
    final repository = _repository;
    if (repository == null) return;
    setState(() {
      _statLoading = true;
      _statError = '';
      _stat = null;
    });
    final result = await repository.semesterStat(
      courseTableId: widget.score.courseTableId,
      year: _year,
      semester: _semester,
    );
    if (!mounted) return;
    setState(() {
      _statLoading = false;
      _stat = result.dataOrNull;
      _statError = result.errorOrNull?.message ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.spaceMd,
          0,
          AppTheme.spaceMd,
          AppTheme.spaceMd,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.score.name.isEmpty
                    ? l10n.hamUnknownCourse
                    : widget.score.name,
                style: text.titleLarge,
              ),
              if (widget.score.instructor.isNotEmpty)
                Text(widget.score.instructor, style: text.bodySmall),
              const SizedBox(height: AppTheme.spaceXs),
              Row(
                children: [
                  if (widget.score.average != null)
                    Text(
                      '${l10n.hamAverage} '
                      '${widget.score.average!.toStringAsFixed(1)}',
                      style: text.bodySmall,
                    ),
                  const SizedBox(width: AppTheme.spaceMd),
                  Text(
                    l10n.hamSamples.replaceAll('%d', '${widget.score.total}'),
                    style: text.bodySmall?.copyWith(color: scheme.outline),
                  ),
                ],
              ),
              if (widget.score.courseTableId.isEmpty) ...[
                const SizedBox(height: AppTheme.spaceMd),
                Panel(
                  child: Text(l10n.hamMissingCourseId, style: text.bodySmall),
                ),
              ] else ...[
                const SizedBox(height: AppTheme.spaceMd),
                SectionHeader(l10n.hamComments),
                _commentsView(l10n, text, scheme),
                const SizedBox(height: AppTheme.spaceMd),
                SectionHeader(l10n.hamSemesterStats),
                _semesterView(l10n, text, scheme),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _commentsView(
    AppLocalizations l10n,
    TextTheme text,
    ColorScheme scheme,
  ) {
    if (_commentsLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppTheme.spaceMd),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_repository == null) {
      return Text(l10n.hamNeedAuthShort, style: text.bodySmall);
    }
    if (_commentsError.isNotEmpty) {
      return Text(
        l10n.hamSectionFailed.replaceAll('%s', _commentsError),
        style: text.bodySmall?.copyWith(color: scheme.error),
      );
    }
    final page = _comments;
    if (page == null || page.comments.isEmpty) {
      return Text(l10n.hamNoComments, style: text.bodySmall);
    }
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.hamTotalCount.replaceAll('%d', '${page.total}'),
            style: text.bodySmall?.copyWith(color: scheme.outline),
          ),
          for (final comment in page.comments)
            _commentTile(comment, text, scheme),
        ],
      ),
    );
  }

  Widget _commentTile(
    HamComment comment,
    TextTheme text,
    ColorScheme scheme,
  ) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  comment.author.isEmpty ? '—' : comment.author,
                  style: text.labelLarge,
                ),
              ),
              if (comment.rate > 0)
                Text(
                  '★' * comment.rate,
                  style: text.bodySmall?.copyWith(color: scheme.tertiary),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(comment.content, style: text.bodyMedium),
          Row(
            children: [
              if (comment.createTime.isNotEmpty)
                Text(
                  comment.createTime,
                  style: text.labelSmall?.copyWith(color: scheme.outline),
                ),
              const Spacer(),
              if (comment.likeTotal > 0)
                Text(
                  l10n.hamLikes.replaceAll('%d', '${comment.likeTotal}'),
                  style: text.labelSmall?.copyWith(color: scheme.outline),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _semesterView(
    AppLocalizations l10n,
    TextTheme text,
    ColorScheme scheme,
  ) {
    final now = DateTime.now();
    final years = [for (var y = now.year - 4; y <= now.year + 1; y++) y];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _year,
                decoration: InputDecoration(labelText: l10n.hamYear),
                items: [
                  for (final year in years)
                    DropdownMenuItem(value: year, child: Text('$year')),
                ],
                onChanged: (value) => setState(() => _year = value ?? _year),
              ),
            ),
            const SizedBox(width: AppTheme.spaceSm),
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _semester,
                decoration: InputDecoration(labelText: l10n.hamSemester),
                items: [
                  for (var term = 1; term <= 3; term++)
                    DropdownMenuItem(value: term, child: Text('$term')),
                ],
                onChanged: (value) =>
                    setState(() => _semester = value ?? _semester),
              ),
            ),
            const SizedBox(width: AppTheme.spaceSm),
            FilledButton(
              onPressed: _repository == null || _statLoading ? null : _loadStat,
              child: Text(l10n.hamQuery),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.spaceSm),
        if (_repository == null)
          Text(l10n.hamNeedAuthShort, style: text.bodySmall)
        else if (_statLoading)
          const LinearProgressIndicator(minHeight: 3)
        else if (_statError.isNotEmpty)
          Text(
            l10n.hamSectionFailed.replaceAll('%s', _statError),
            style: text.bodySmall?.copyWith(color: scheme.error),
          )
        else if (_stat != null)
          _statView(_stat!, text, scheme, l10n),
      ],
    );
  }

  Widget _statView(
    HamSemesterStat stat,
    TextTheme text,
    ColorScheme scheme,
    AppLocalizations l10n,
  ) {
    final course = stat.course;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${stat.year} · ${l10n.hamSemester} ${stat.semester}',
            style: text.labelLarge,
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              if (course.average != null)
                Text(
                  '${l10n.hamAverage} ${course.average!.toStringAsFixed(1)}',
                  style: text.bodySmall,
                ),
              const SizedBox(width: AppTheme.spaceMd),
              if (course.median != null)
                Text(
                  '${l10n.hamMedian} ${course.median}',
                  style: text.bodySmall,
                ),
              const SizedBox(width: AppTheme.spaceMd),
              Text(
                l10n.hamSamples.replaceAll('%d', '${course.total}'),
                style: text.bodySmall?.copyWith(color: scheme.outline),
              ),
            ],
          ),
          if (course.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.spaceSm),
              child: Text(
                l10n.hamNoData,
                style: text.bodySmall?.copyWith(color: scheme.outline),
              ),
            )
          else
            for (final band in course.buckets)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${band.from}-${band.to}: ${band.total}',
                  style: text.bodySmall,
                ),
              ),
        ],
      ),
    );
  }
}
