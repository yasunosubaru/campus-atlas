import 'package:flutter/material.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/result.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../main.dart';
import '../timetable/timetable_models.dart';
import 'conflict.dart';
import 'course_models.dart';
import 'course_repository.dart';

/// Course catalogue: rating aggregates and the master timetable.
///
/// Both tabs read only public, unauthenticated endpoints. Nothing on this
/// screen can reach a signed-in student's own records.
class CourseSearchScreen extends StatefulWidget {
  const CourseSearchScreen({super.key});

  @override
  State<CourseSearchScreen> createState() => _CourseSearchScreenState();
}

class _CourseSearchScreenState extends State<CourseSearchScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.coursesTitle),
          bottom: TabBar(
            tabs: [
              Tab(text: l10n.coursesRatings),
              Tab(text: l10n.coursesMaster),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _RatingSearchTab(),
            _MasterTimetableTab(),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- ratings tab

class _RatingSearchTab extends StatefulWidget {
  const _RatingSearchTab();

  @override
  State<_RatingSearchTab> createState() => _RatingSearchTabState();
}

class _RatingSearchTabState extends State<_RatingSearchTab> {
  final _controller = TextEditingController();
  Result<ResultPage<CourseSummary>>? _result;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final services = AppScope.of(context, dependOn: false);
    final query = _controller.text.trim();
    if (query.isEmpty) return;

    setState(() => _busy = true);
    final result = await services.courses.searchCourses(query);
    if (!mounted) return;
    setState(() {
      _result = result;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppTheme.spaceMd),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: l10n.coursesSearchHint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: _busy ? null : _search,
              ),
            ),
            onSubmitted: (_) => _search(),
          ),
        ),
        Expanded(
          child: !_busy && _result == null
              ? EmptyState(
                  title: l10n.coursesTitle,
                  body: l10n.coursesSearchHint,
                  icon: Icons.rate_review_outlined,
                )
              : _busy
                  ? const CenterLoader()
                  : _result!.fold(
                      (page) => page.isEmpty
                          ? EmptyState(
                              title: l10n.coursesNoResults,
                              body: l10n.coursesSearchHint,
                              icon: Icons.search_off_outlined,
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(
                                AppTheme.spaceMd,
                                0,
                                AppTheme.spaceMd,
                                AppTheme.spaceXl,
                              ),
                              itemCount: page.items.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: AppTheme.spaceSm),
                              itemBuilder: (context, i) =>
                                  _CourseCard(course: page.items[i]),
                            ),
                      (failure) => ErrorState(
                        failure: failure,
                        onRetry: _search,
                      ),
                    ),
        ),
      ],
    );
  }
}

class _CourseCard extends StatelessWidget {
  const _CourseCard({required this.course});

  final CourseSummary course;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final rating = course.rating;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(course.name, style: text.titleMedium),
          if (course.department.isNotEmpty || course.code.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              [course.department, course.code]
                  .where((s) => s.isNotEmpty)
                  .join(' · '),
              style: text.bodySmall,
            ),
          ],
          const SizedBox(height: AppTheme.spaceSm),
          if (rating.hasReviews) ...[
            Row(
              children: [
                Icon(Icons.star_rounded,
                    size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 4),
                Text(rating.rating.toStringAsFixed(2), style: text.labelLarge),
                const SizedBox(width: AppTheme.spaceSm),
                Text(
                  l10n.coursesReviewCount
                      .replaceAll('%d', '${rating.reviewCount}'),
                  style: text.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: AppTheme.spaceSm),
            _RatingBar(
                label: l10n.coursesTeachingQuality,
                value: rating.teachingQuality),
            _RatingBar(label: l10n.coursesDifficulty, value: rating.difficulty),
            _RatingBar(label: l10n.coursesWorkload, value: rating.workload),
            _RatingBar(
                label: l10n.coursesInterest, value: rating.courseInterest),
            _RatingBar(
                label: l10n.coursesRatingDifficult,
                value: rating.ratingDifficult),
          ] else
            Row(
              children: [
                Icon(Icons.reviews_outlined,
                    size: 16, color: text.bodySmall?.color),
                const SizedBox(width: 6),
                Text(l10n.coursesNoReviews, style: text.bodySmall),
              ],
            ),
        ],
      ),
    );
  }
}

/// Horizontal 0..5 bar. Kept local so the rating scale stays visible even when
/// the values are all identical.
class _RatingBar extends StatelessWidget {
  const _RatingBar({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final clamped = value.clamp(0.0, 5.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 78,
            child: Text(label, style: text.bodySmall, maxLines: 1),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: clamped / 5.0,
                minHeight: 6,
                backgroundColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(width: AppTheme.spaceSm),
          SizedBox(
            width: 30,
            child: Text(clamped.toStringAsFixed(1), style: text.bodySmall),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------- master timetable

class _MasterTimetableTab extends StatefulWidget {
  const _MasterTimetableTab();

  @override
  State<_MasterTimetableTab> createState() => _MasterTimetableTabState();
}

class _MasterTimetableTabState extends State<_MasterTimetableTab> {
  final _controller = TextEditingController();

  Result<List<MasterTerm>>? _terms;
  MasterTerm? _selected;
  Result<ResultPage<MasterCourse>>? _result;
  bool _busy = false;

  /// The user's own timetable, loaded from local storage so master rows can be
  /// classified as clash-free or clashing.
  List<Course> _mine = const [];

  /// When true the list hides every row that is not proven clash-free.
  bool _freeOnly = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadTerms();
  }

  Future<void> _loadTerms() async {
    final services = AppScope.of(context, dependOn: false);
    setState(() => _busy = true);
    final result = await services.courses.masterTerms();
    final mine = await services.timetable.load();
    if (!mounted) return;
    final list = result.dataOrNull ?? const <MasterTerm>[];
    setState(() {
      _terms = result;
      _selected = list.isNotEmpty ? list.first : null;
      _mine = mine.dataOrNull ?? const <Course>[];
      _busy = false;
    });
    if (list.isNotEmpty) await _search();
  }

  Future<void> _search() async {
    final term = _selected;
    if (term == null) return;
    final services = AppScope.of(context, dependOn: false);
    setState(() => _busy = true);
    final result = await services.courses.searchMasterTimetable(
      year: term.year,
      term: term.term,
      query: _controller.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    final terms = _terms is Success
        ? (_terms as Success<List<MasterTerm>>).dataOrNull!
        : const <MasterTerm>[];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceMd,
            AppTheme.spaceMd,
            AppTheme.spaceMd,
            AppTheme.spaceSm,
          ),
          child: Row(
            children: [
              Expanded(
                child: terms.isEmpty
                    ? Text(
                        l10n.coursesLoadingTerms,
                        style: Theme.of(context).textTheme.bodyMedium,
                      )
                    : DropdownButtonFormField<MasterTerm>(
                        initialValue: _selected,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: l10n.coursesTerm,
                        ),
                        items: [
                          for (final t in terms)
                            DropdownMenuItem(
                              value: t,
                              child: Text(
                                '${t.year} ${t.term.label} · ${t.storedCount}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) {
                          setState(() => _selected = v);
                          _search();
                        },
                      ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceMd,
            0,
            AppTheme.spaceMd,
            AppTheme.spaceSm,
          ),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: l10n.coursesSearchHint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: _busy || _selected == null ? null : _search,
              ),
            ),
            onSubmitted: (_) => _search(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceMd,
            0,
            AppTheme.spaceMd,
            AppTheme.spaceSm,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              label: Text(l10n.coursesFreeOnly),
              selected: _freeOnly,
              onSelected: (v) => setState(() => _freeOnly = v),
            ),
          ),
        ),
        Expanded(
          child: _busy
              ? const CenterLoader()
              : _result == null
                  ? EmptyState(
                      title: l10n.coursesMaster,
                      body: l10n.coursesLoadingTerms,
                      icon: Icons.calendar_month_outlined,
                    )
                  : _result!.fold(
                      (page) {
                        if (page.isEmpty) {
                          return EmptyState(
                            title: l10n.coursesStoreEmpty,
                            body: l10n.coursesSearchHint,
                            icon: Icons.event_busy_outlined,
                          );
                        }
                        final visible = _freeOnly
                            ? page.items
                                .where((c) =>
                                    conflictWithMyTimetable(c, _mine) ==
                                    ConflictStatus.free)
                                .toList()
                            : page.items;
                        if (visible.isEmpty) {
                          return EmptyState(
                            title: l10n.coursesNoConflictFree,
                            body: l10n.coursesSearchHint,
                            icon: Icons.filter_alt_off_outlined,
                          );
                        }
                        return ListView.separated(
                          padding: const EdgeInsets.fromLTRB(
                            AppTheme.spaceMd,
                            0,
                            AppTheme.spaceMd,
                            AppTheme.spaceXl,
                          ),
                          itemCount: visible.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: AppTheme.spaceSm),
                          itemBuilder: (context, i) => _MasterCard(
                            course: visible[i],
                            myStatus: _mine.isEmpty
                                ? null
                                : conflictWithMyTimetable(visible[i], _mine),
                          ),
                        );
                      },
                      (failure) => ErrorState(
                        failure: failure,
                        onRetry: _search,
                      ),
                    ),
        ),
      ],
    );
  }
}

class _MasterCard extends StatelessWidget {
  const _MasterCard({required this.course, this.myStatus});

  final MasterCourse course;

  /// This row's relation to the user's own timetable, or null when there is no
  /// local timetable to compare against.
  final ConflictStatus? myStatus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(course.name, style: text.titleMedium),
          const SizedBox(height: 4),
          Text(
            [
              if (course.teacherName.isNotEmpty) course.teacherName,
              if (course.credits > 0)
                '${l10n.coursesCredits} ${course.credits}',
              if (course.room.isNotEmpty) course.room,
            ].join(' · '),
            style: text.bodySmall,
          ),
          const SizedBox(height: AppTheme.spaceSm),
          Wrap(
            spacing: AppTheme.spaceSm,
            runSpacing: 6,
            children: [
              if (myStatus == ConflictStatus.free)
                _Chip(
                  text: l10n.coursesBadgeFree,
                  background: scheme.secondaryContainer,
                ),
              if (myStatus == ConflictStatus.clash)
                _Chip(
                  text: l10n.coursesBadgeClash,
                  background: scheme.errorContainer,
                ),
              _Chip(
                text:
                    '${l10n.coursesPeriod} ${course.startSection}-${course.endSection}',
              ),
              if (course.weeks.isNotEmpty)
                _Chip(text: '${l10n.coursesWeeks} ${course.weeks}'),
              if (course.department.isNotEmpty) _Chip(text: course.department),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.background});

  final String text;

  /// Overrides the default surface tint, for status chips.
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background ?? scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
