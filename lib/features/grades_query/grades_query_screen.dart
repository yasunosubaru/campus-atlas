import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/result.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../main.dart';
import 'grades_query_models.dart';
import 'grades_query_repository.dart';

/// Query a teacher's grading and the evaluations for a course.
///
/// This is a **query** feature, per the recovered contract:
///
///   by-name   → every offering's grade distribution for a course name
///   teachers/ → choose a teacher to view their grade data
///   view/     → one teacher's grade distribution in detail
///   reviews   → review texts
///
/// It is not a review-posting UI. Sending a review is a different feature and
/// the reader does not need it to look up what other people wrote.
class GradesQueryScreen extends StatefulWidget {
  const GradesQueryScreen({super.key});

  @override
  State<GradesQueryScreen> createState() => _GradesQueryScreenState();
}

class _GradesQueryScreenState extends State<GradesQueryScreen> {
  final _search = TextEditingController();
  final _identifier = TextEditingController();
  final _password = TextEditingController();

  GradesQueryRepository? _repo;
  bool _signingIn = false;
  String _signInError = '';

  Result<List<CourseGrades>>? _results;
  bool _searching = false;

  TeacherGrade? _openTeacher;
  Result<TeacherGrade>? _detail;

  @override
  void initState() {
    super.initState();
    _repo = GradesQueryRepository(
      client: AppScope.of(context, dependOn: false).client,
    );
  }

  @override
  void dispose() {
    _search.dispose();
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final repo = _repo;
    if (repo == null) return;

    setState(() {
      _signingIn = true;
      _signInError = '';
    });

    final result = await repo.login(
      identifier: _identifier.text,
      password: _password.text,
    );

    if (!mounted) return;
    setState(() {
      _signingIn = false;
      if (result.isFailure) {
        _signInError = _errorText(result.errorOrNull);
        // Never leave the password sitting in the field after a failure.
        _password.clear();
      } else {
        _signInError = '';
      }
    });
  }

  String _errorText(dynamic failure) {
    if (failure == null) return '';
    final kind = (failure as dynamic).kind;
    final message = (failure as dynamic).message as String? ?? '';
    // A 422 names the missing field, which is the intended self-correction
    // path for an unverified parameter name — surface it rather than hiding it.
    return switch (kind.toString()) {
      'FailureKind.unauthorized' =>
        message.isEmpty ? l10n(context).gqSignInFailed : message,
      'FailureKind.validation' =>
        message.isEmpty ? l10n(context).gqInvalidInput : message,
      'FailureKind.protocol' =>
        message.isEmpty ? l10n(context).gqProtocolError : message,
      _ => message.isEmpty ? l10n(context).gqFailed : message,
    };
  }

  AppLocalizations l10n(BuildContext c) => AppLocalizations.of(c);

  Future<void> _runSearch() async {
    final repo = _repo;
    if (repo == null) return;
    final query = _search.text.trim();
    if (query.isEmpty) return;

    setState(() => _searching = true);
    final result = await repo.byName(query);
    if (!mounted) return;
    setState(() {
      _results = result;
      _searching = false;
      _openTeacher = null;
      _detail = null;
    });
  }

  /// Shows what the server actually returned.
  ///
  /// The four grade endpoints have never had a response body recorded, so the
  /// parsers work from guessed key aliases and five candidate list keys. A
  /// single real payload ends that guesswork: this panel shows the body
  /// verbatim so it can be copied out and the field names pinned down.
  ///
  /// The login response is deliberately **not** in this buffer — it carries the
  /// access token, and text whose whole purpose is to be pasted into a message
  /// is the last place a credential should end up.
  void _showDiagnostics(AppLocalizations l10n) {
    final repo = _repo;
    final raw = repo?.lastRawResponse ?? '';
    final endpoint = repo?.lastRawEndpoint ?? '';

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final text = Theme.of(sheetContext).textTheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.spaceMd),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.gqDiagnostics, style: text.titleMedium),
                const SizedBox(height: AppTheme.spaceXs),
                Text(l10n.gqRawNote, style: text.bodySmall),
                const SizedBox(height: AppTheme.spaceSm),
                if (endpoint.isNotEmpty) Text(endpoint, style: text.labelSmall),
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
                            raw,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: AppTheme.spaceSm),
                Row(
                  children: [
                    if (raw.isNotEmpty)
                      FilledButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: raw));
                          if (!sheetContext.mounted) return;
                          ScaffoldMessenger.of(sheetContext).showSnackBar(
                            SnackBar(content: Text(l10n.gqCopied)),
                          );
                        },
                        icon: const Icon(Icons.copy_all_outlined),
                        label: Text(l10n.gqCopy),
                      ),
                    const Spacer(),
                    if (raw.isNotEmpty)
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
        );
      },
    );
  }

  Future<void> _showTeacher(TeacherGrade teacher) async {
    final repo = _repo;
    if (repo == null) return;

    setState(() => _openTeacher = teacher);
    final result = await repo.view(teacher.id);
    if (!mounted) return;
    setState(() => _detail = result);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final signedIn = _repo?.isSignedIn ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.gqTitle),
        actions: [
          IconButton(
            tooltip: l10n.gqDiagnostics,
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () => _showDiagnostics(l10n),
          ),
          if (signedIn)
            IconButton(
              tooltip: l10n.gqSignOut,
              icon: const Icon(Icons.logout_rounded),
              onPressed: () {
                _repo?.signOut();
                setState(() {
                  _results = null;
                  _openTeacher = null;
                  _detail = null;
                  _password.clear();
                });
              },
            ),
        ],
      ),
      body: !signedIn ? _signInView(l10n) : _queryView(l10n),
    );
  }

  // ----------------------------------------------------------------- sign in

  Widget _signInView(AppLocalizations l10n) {
    return ListView(
      padding: const EdgeInsets.all(AppTheme.spaceMd),
      children: [
        Text(l10n.gqSignInNote, style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: AppTheme.spaceSm),
        Text(l10n.gqSignInPrivacy,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: AppTheme.spaceLg),
        TextField(
          controller: _identifier,
          // Not emailAddress: the service accepts a bare student number, and
          // that keyboard would autocorrect it into punctuation-free nonsense
          // or refuse the digits outright.
          keyboardType: TextInputType.text,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: l10n.gqIdentifier,
            hintText: '202300000000',
          ),
        ),
        const SizedBox(height: AppTheme.spaceSm),
        TextField(
          controller: _password,
          obscureText: true,
          decoration: InputDecoration(labelText: l10n.gqPassword),
        ),
        if (_signInError.isNotEmpty) ...[
          const SizedBox(height: AppTheme.spaceSm),
          Text(_signInError,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: AppTheme.spaceMd),
        FilledButton.icon(
          onPressed: _signingIn ? null : _signIn,
          icon: _signingIn
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.login_rounded),
          label: Text(_signingIn ? l10n.gqSubmitting : l10n.gqSubmit),
        ),
      ],
    );
  }

  // ----------------------------------------------------------------- query

  Widget _queryView(AppLocalizations l10n) {
    final open = _openTeacher;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceMd,
            AppTheme.spaceMd,
            AppTheme.spaceMd,
            0,
          ),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: l10n.gqSearchHint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: _searching ? null : _runSearch,
              ),
            ),
            onSubmitted: (_) => _runSearch(),
          ),
        ),
        Expanded(
          child: _searching
              ? const CenterLoader()
              : open != null
                  ? _teacherDetail(l10n, open)
                  : _resultList(l10n),
        ),
      ],
    );
  }

  Widget _resultList(AppLocalizations l10n) {
    final r = _results;
    if (r == null) {
      return EmptyState(
        title: l10n.gqTitle,
        body: l10n.gqSearchHint,
        icon: Icons.query_stats_outlined,
      );
    }
    return r.fold(
      (courses) => courses.isEmpty
          ? EmptyState(
              title: l10n.gqNoResults,
              body: l10n.gqSearchHint,
              icon: Icons.search_off_outlined,
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.spaceMd,
                AppTheme.spaceSm,
                AppTheme.spaceMd,
                AppTheme.spaceXl,
              ),
              itemCount: courses.length,
              itemBuilder: (context, i) => _courseCard(l10n, courses[i]),
            ),
      (failure) => ErrorState(failure: failure, onRetry: _runSearch),
    );
  }

  Widget _courseCard(AppLocalizations l10n, CourseGrades course) {
    final text = Theme.of(context).textTheme;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(course.name, style: text.titleMedium),
          const SizedBox(height: AppTheme.spaceSm),
          // The live response for a course with no data is
          // `{"course_name":"…","offerings":[]}` — a *successful* answer
          // saying "this course has no grade data". That is a different
          // statement from "no such course", so it gets its own line rather
          // than the shared not-found empty state.
          if (course.isEmpty)
            Text(l10n.gqNoOfferings, style: text.bodySmall)
          else
            Text(l10n.gqPickTeacher, style: text.bodySmall),
          for (final t in course.teachers) ...[
            const SizedBox(height: AppTheme.spaceXs),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_outline),
              title: Text(t.name),
              subtitle: t.department.isEmpty
                  ? null
                  : Text(t.department, style: text.bodySmall),
              trailing: t.reviewCount > 0
                  ? Text(
                      l10n.gqReviewCount.replaceAll('%d', '${t.reviewCount}'),
                      style: text.bodySmall)
                  : null,
              onTap: () => _showTeacher(t),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- detail

  Widget _teacherDetail(AppLocalizations l10n, TeacherGrade teacher) {
    final text = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spaceMd,
        AppTheme.spaceSm,
        AppTheme.spaceMd,
        AppTheme.spaceXl,
      ),
      children: [
        Text(teacher.name, style: text.titleLarge),
        Text(
          [teacher.courseName, teacher.department]
              .where((s) => s.isNotEmpty)
              .join(' · '),
          style: text.bodySmall,
        ),
        const SizedBox(height: AppTheme.spaceMd),

        // The six averages. Rendered so the *direction* of each axis is
        // unmistakable: grading generosity higher-is-better, workload
        // lower-is-better, difficulty neutral.
        Panel(
          child: Column(
            children: [
              _axis(l10n.gqOverall, teacher.rating, 5, _AxisDirection.up),
              _axis(l10n.gqTeachingQuality, teacher.teachingQuality, 5,
                  _AxisDirection.up),
              _axis(l10n.gqGradingScore, teacher.gradingScore, 5,
                  _AxisDirection.neutral),
              _axis(l10n.gqWorkload, teacher.workload, 5, _AxisDirection.down),
              _axis(l10n.gqDifficulty, teacher.difficulty, 5,
                  _AxisDirection.neutral),
            ],
          ),
        ),

        const SizedBox(height: AppTheme.spaceMd),
        Text(l10n.gqDistribution, style: text.titleSmall),
        const SizedBox(height: AppTheme.spaceXs),
        _detail!.fold(
          (d) => !d.hasDistribution
              ? Text(l10n.gqNoDistribution, style: text.bodySmall)
              : Column(
                  children: [
                    for (final b in d.distribution)
                      _bucketBar(l10n, b, d.bucketTotal),
                  ],
                ),
          (failure) => ErrorState(
              failure: failure,
              onRetry: () async {
                await _showTeacher(teacher);
              }),
        ),

        const SizedBox(height: AppTheme.spaceMd),
        Text(l10n.gqReviews, style: text.titleSmall),
        const SizedBox(height: AppTheme.spaceXs),
        FutureBuilder(
          future: _repo!.reviews(courseUid: _openTeacherCourseUid()),
          builder: (context, snapshot) {
            final data = snapshot.data;
            if (data == null) return const CenterLoader();
            return data.fold(
              (list) => list.isEmpty
                  ? Text(l10n.gqNoReviews, style: text.bodySmall)
                  : Column(
                      children: [
                        for (final r in list) _reviewTile(l10n, r),
                      ],
                    ),
              (failure) => ErrorState(
                failure: failure,
                onRetry: () => setState(() {}),
              ),
            );
          },
        ),
        const SizedBox(height: AppTheme.spaceLg),
        TextButton.icon(
          onPressed: () => setState(() {
            _openTeacher = null;
            _detail = null;
          }),
          icon: const Icon(Icons.arrow_back),
          label: Text(l10n.gqBackToList),
        ),
      ],
    );
  }

  /// The teacher payload does not always carry a course uid, so fall back to
  /// the search query itself rather than dropping the reviews call.
  String? _openTeacherCourseUid() {
    final raw = _detail?.dataOrNull?.raw;
    final uid = raw?['course_uid'];
    if (uid is String && uid.isNotEmpty) return uid;
    final q = _search.text.trim();
    return q.isEmpty ? null : q;
  }

  Widget _axis(String label, double value, double max, _AxisDirection dir) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final fraction = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0);

    // Only a "higher is better" axis gets a positive colour; a low workload is
    // good and must not be painted as failing.
    final colour = switch (dir) {
      _AxisDirection.up => scheme.primary,
      _AxisDirection.down => scheme.secondary,
      _AxisDirection.neutral => scheme.outline,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: text.bodySmall, maxLines: 1),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 8,
                color: colour,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(width: AppTheme.spaceSm),
          SizedBox(
            width: 34,
            child: Text(value.toStringAsFixed(1), style: text.bodySmall),
          ),
        ],
      ),
    );
  }

  Widget _bucketBar(AppLocalizations l10n, GradeBucket bucket, int total) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final denom = total > 0 ? total : 0;
    final share = denom > 0
        ? (bucket.count / denom).clamp(0.0, 1.0)
        : (bucket.percentage / 100).clamp(0.0, 1.0);
    final colour = bucket.looksLikeFail ? scheme.error : scheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(width: 58, child: Text(bucket.label, style: text.bodySmall)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              child: LinearProgressIndicator(
                value: share,
                minHeight: 12,
                color: colour,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(width: AppTheme.spaceSm),
          SizedBox(
            width: 44,
            child: Text('${bucket.count}', style: text.bodySmall),
          ),
        ],
      ),
    );
  }

  Widget _reviewTile(AppLocalizations l10n, CourseReview r) {
    final text = Theme.of(context).textTheme;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (r.rating > 0)
                Icon(Icons.star_rounded,
                    size: 15, color: Theme.of(context).colorScheme.primary),
              if (r.rating > 0) const SizedBox(width: 4),
              if (r.rating > 0)
                Text(r.rating.toStringAsFixed(1), style: text.labelMedium),
              const Spacer(),
              if (r.createdAt != null)
                Text('${r.createdAt!.year}-${r.createdAt!.month}',
                    style: text.bodySmall),
            ],
          ),
          const SizedBox(height: 4),
          Text(r.text.isEmpty ? l10n.gqNoReviews : r.text),
        ],
      ),
    );
  }
}

enum _AxisDirection { up, down, neutral }
