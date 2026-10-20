import 'package:flutter/material.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/result.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../main.dart';
import '../agenda/agenda_repository.dart';
import 'calendar.dart';
import 'import/import_sheet.dart';
import 'import/semester_calendar.dart';
import 'reminders.dart';
import 'timetable_models.dart';
import 'timetable_repository.dart';

/// The timetable, with several named timetables and two views.
///
/// * **Week** — the grid people actually read a timetable in: seven day columns
///   against period rows, a block per class.
/// * **Month** — the same classes laid on a calendar, plus agenda entries, so
///   "what does this month look like" is answerable in one screen.
///
/// Both views ask [coursesOnDate] whether a class meets, so they cannot disagree
/// about a week set or a term start.
class TimetableScreen extends StatefulWidget {
  const TimetableScreen({super.key});

  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends State<TimetableScreen> {
  List<TimetableProfile> _profiles = const [];
  String _activeId = '';
  List<Course> _courses = const [];
  List<AgendaItem> _agenda = const [];
  DateTime _firstWeekStart = DateTime(2026, 2, 23);
  int _week = 1;
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  bool _monthView = false;
  bool _loading = true;
  String _failure = '';

  late final ValueNotifier<int> _timetableChanges;

  @override
  void initState() {
    super.initState();
    _timetableChanges = AppScope.of(context, dependOn: false).timetableChanges;
    _timetableChanges.addListener(_reloadTimetable);
    _load();
  }

  @override
  void dispose() {
    _timetableChanges.removeListener(_reloadTimetable);
    super.dispose();
  }

  void _reloadTimetable() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    final services = AppScope.of(context, dependOn: false);
    final firstWeek = await services.settings.firstWeekStart();
    final profiles = await services.timetable.profiles();
    final active = await services.timetable.activeProfileId();
    final courses = await services.timetable.load();
    final agenda = await services.agenda.list();
    if (!mounted) return;

    final now = DateTime.now();
    setState(() {
      _firstWeekStart = firstWeek;
      _profiles = profiles.dataOrNull ?? const [];
      _activeId = active.dataOrNull ?? '';
      _courses = courses.dataOrNull ?? const [];
      _agenda = agenda.dataOrNull ?? const [];
      _week = weekNumberFor(now, firstWeek).clamp(1, 40);
      _month = DateTime(now.year, now.month);
      _failure = profiles.errorOrNull?.message ??
          active.errorOrNull?.message ??
          courses.errorOrNull?.message ??
          '';
      _loading = false;
    });
  }

  // ---------------------------------------------------------------- profiles

  String _nameOf(TimetableProfile profile, AppLocalizations l10n) =>
      profile.name.isEmpty ? l10n.ttDefaultProfile : profile.name;

  TimetableProfile? get _activeProfile {
    for (final profile in _profiles) {
      if (profile.id == _activeId) return profile;
    }
    return _profiles.isEmpty ? null : _profiles.first;
  }

  Future<void> _switchProfile(String id) async {
    final services = AppScope.of(context, dependOn: false);
    final result = await services.timetable.setActiveProfile(id);
    if (!mounted) return;
    if (result is Failure) {
      _showMessage(result.errorOrNull?.message ?? '');
      return;
    }
    await _load();
    services.notifyTimetableChanged();
  }

  Future<void> _manageProfiles(AppLocalizations l10n) async {
    final services = AppScope.of(context, dependOn: false);
    await showDialog<void>(
      context: context,
      builder: (_) => _ProfileManager(
        l10n: l10n,
        repository: services.timetable,
      ),
    );
    if (mounted) {
      await _load();
      services.notifyTimetableChanged();
    }
  }

  /// Reads a timetable from 教务 and, after confirmation, replaces this one.
  ///
  /// The confirmation names the timetable: an import is a whole-term answer, and
  /// silently overwriting a hand-built timetable with it would be the kind of
  /// data loss that is only noticed a week later.
  Future<void> _importTimetable(AppLocalizations l10n) async {
    final services = AppScope.of(context, dependOn: false);

    final outcome = await showModalBottomSheet<TimetableImportOutcome>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => TimetableImportSheet(
        client: services.client,
        initialSession: services.whuSession,
      ),
    );
    if (outcome == null || outcome.courses.isEmpty || !mounted) return;
    final courses = outcome.courses;

    final profile = _activeProfile;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.ttImportApply),
        content: Text(
          l10n.ttImportApplyBody
              .replaceAll('%d', '${courses.length}')
              .replaceAll('%s', profile == null ? '' : _nameOf(profile, l10n)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.ttImportApply),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final result = await services.timetable.replaceAll(courses);
    if (!mounted) return;
    if (result is Failure) {
      _showMessage(result.errorOrNull?.message ?? '');
      return;
    }

    // Move the week anchor with the data. The calendar is a published campus
    // date, not something the N2151 response carries, so it is derived from
    // the semester the person just picked. Without this a fall import is drawn
    // against the spring anchor and the grid looks empty.
    final anchor = semesterFirstWeekStart(outcome.year, outcome.term);
    if (anchor != null) {
      await services.settings.setFirstWeekStart(anchor);
    }
    if (!mounted) return;
    setState(() {
      _courses = result.requireValue;
      if (anchor != null) {
        _firstWeekStart = anchor;
        _week = weekNumberFor(DateTime.now(), anchor).clamp(1, 40);
      }
    });
    services.notifyTimetableChanged();
    _showMessage(l10n.ttImportDone.replaceAll('%d', '${courses.length}'));
  }

  // ----------------------------------------------------------------- courses

  Future<void> _openCourseEditor({Course? initial}) async {
    final l10n = AppLocalizations.of(context);
    final services = AppScope.of(context, dependOn: false);

    final course = await showModalBottomSheet<Course>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CourseSheet(initial: initial),
    );
    if (course == null || !mounted) return;

    final result = initial == null
        ? await services.timetable.add(course)
        : await services.timetable.update(course);
    if (!mounted) return;

    if (result is Failure) {
      _showMessage(l10n.errorFor(result.errorOrNull?.kind.name ?? 'unknown'));
      return;
    }
    setState(() => _courses = result.requireValue);
    services.notifyTimetableChanged();
  }

  Future<void> _openCourseDetail(Course course) async {
    final l10n = AppLocalizations.of(context);
    final services = AppScope.of(context, dependOn: false);

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceMd,
            0,
            AppTheme.spaceMd,
            AppTheme.spaceMd,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(course.name, style: Theme.of(sheet).textTheme.titleLarge),
              const SizedBox(height: AppTheme.spaceSm),
              _detailRow(
                sheet,
                Icons.schedule_outlined,
                [
                  '${l10n.ttPeriods} ${course.startPeriod}-${course.endPeriod}',
                  if (course.startTime.isNotEmpty)
                    '${course.startTime}${course.endTime.isEmpty ? '' : '-${course.endTime}'}',
                ].join(' · '),
              ),
              if (course.location.isNotEmpty)
                _detailRow(sheet, Icons.place_outlined, course.location),
              if (course.teacher.isNotEmpty)
                _detailRow(sheet, Icons.person_outline, course.teacher),
              _detailRow(
                sheet,
                Icons.date_range_outlined,
                '${l10n.ttWeeksLabel} ${formatWeeks(course.weeks)}',
              ),
              const SizedBox(height: AppTheme.spaceMd),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(sheet).pop('edit'),
                      icon: const Icon(Icons.edit_outlined),
                      label: Text(l10n.ttEdit),
                    ),
                  ),
                  const SizedBox(width: AppTheme.spaceSm),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () => Navigator.of(sheet).pop('delete'),
                      icon: const Icon(Icons.delete_outline),
                      label: Text(l10n.delete),
                      style: FilledButton.styleFrom(
                        foregroundColor: Theme.of(sheet).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;

    if (action == 'edit') {
      await _openCourseEditor(initial: course);
      return;
    }
    if (action == 'delete') {
      final result = await services.timetable.remove(course.id);
      if (!mounted) return;
      if (result is Failure) {
        _showMessage(result.errorOrNull?.message ?? '');
        return;
      }
      setState(() => _courses = result.requireValue);
      services.notifyTimetableChanged();
    }
  }

  Widget _detailRow(BuildContext context, IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.outline),
          const SizedBox(width: AppTheme.spaceSm),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }

  void _showMessage(String message) {
    if (message.isEmpty) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final active = _activeProfile;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.ttTitle),
        actions: [
          IconButton(
            tooltip: l10n.ttImport,
            icon: const Icon(Icons.download_outlined),
            onPressed: () => _importTimetable(l10n),
          ),
          PopupMenuButton<String>(
            tooltip: l10n.ttProfiles,
            icon: const Icon(Icons.layers_outlined),
            onSelected: (value) {
              if (value == '__new') {
                _createProfile(l10n);
              } else if (value == '__manage') {
                _manageProfiles(l10n);
              } else {
                _switchProfile(value);
              }
            },
            itemBuilder: (_) => [
              for (final profile in _profiles)
                PopupMenuItem(
                  value: profile.id,
                  child: Row(
                    children: [
                      Icon(
                        profile.id == _activeId
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        size: 18,
                      ),
                      const SizedBox(width: AppTheme.spaceSm),
                      Text(_nameOf(profile, l10n)),
                    ],
                  ),
                ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: '__new',
                child: Text(l10n.ttNewProfile),
              ),
              PopupMenuItem(
                value: '__manage',
                child: Text(l10n.ttManageProfiles),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.retry,
            onPressed: _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openCourseEditor(),
        icon: const Icon(Icons.add),
        label: Text(l10n.ttAdd),
      ),
      body: _loading
          ? const CenterLoader()
          : Column(
              children: [
                _viewHeader(l10n, active),
                if (_failure.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppTheme.spaceMd),
                    child: Text(
                      _failure,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                Expanded(
                  child: _monthView ? _monthBody(l10n) : _weekBody(l10n),
                ),
              ],
            ),
    );
  }

  Widget _viewHeader(AppLocalizations l10n, TimetableProfile? active) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spaceMd,
        AppTheme.spaceXs,
        AppTheme.spaceMd,
        AppTheme.spaceSm,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: false, label: Text(l10n.ttWeekView)),
                    ButtonSegment(value: true, label: Text(l10n.ttMonthView)),
                  ],
                  selected: {_monthView},
                  onSelectionChanged: (value) =>
                      setState(() => _monthView = value.first),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spaceSm),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _step(-1),
                tooltip: l10n.ttPrevious,
              ),
              Expanded(
                child: Center(
                  child: Column(
                    children: [
                      Text(
                        _monthView
                            ? '${_month.year}-${_month.month.toString().padLeft(2, '0')}'
                            : l10n.ttWeekN.replaceAll('%d', '$_week'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (!_monthView)
                        Text(
                          active == null ? '' : _nameOf(active, l10n),
                          style: Theme.of(context).textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _step(1),
                tooltip: l10n.ttNext,
              ),
              TextButton(
                onPressed: _today,
                child: Text(l10n.ttToday),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _step(int delta) {
    setState(() {
      if (_monthView) {
        _month = DateTime(_month.year, _month.month + delta);
      } else {
        _week = (_week + delta).clamp(1, 40);
      }
    });
  }

  void _today() {
    final now = DateTime.now();
    setState(() {
      _week = weekNumberFor(now, _firstWeekStart).clamp(1, 40);
      _month = DateTime(now.year, now.month);
    });
  }

  Widget _weekBody(AppLocalizations l10n) {
    if (_courses.isEmpty) {
      return EmptyState(
        title: l10n.ttEmpty,
        body: l10n.emptyBody,
        icon: Icons.calendar_month_outlined,
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 96),
      child: _WeekGrid(
        key: const ValueKey('timetable.week'),
        courses: _courses,
        week: _week,
        firstWeekStart: _firstWeekStart,
        onTap: _openCourseDetail,
      ),
    );
  }

  Widget _monthBody(AppLocalizations l10n) {
    final days = monthGrid(_month);
    final today = DateTime.now();

    return GridView.builder(
      key: const ValueKey('timetable.month'),
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spaceSm,
        0,
        AppTheme.spaceSm,
        96,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        childAspectRatio: 0.78,
      ),
      itemCount: days.length,
      itemBuilder: (context, index) {
        final day = days[index];
        final classes = coursesOnDate(_courses, day.date, _firstWeekStart);
        final agenda = agendaOnDate(_agenda, day.date);
        final isToday = day.date.year == today.year &&
            day.date.month == today.month &&
            day.date.day == today.day;

        return _MonthCell(
          day: day,
          classes: classes.length,
          hasAgenda: agenda.isNotEmpty,
          isToday: isToday,
          onTap: () => _showDay(l10n, day.date, classes, agenda),
        );
      },
    );
  }

  Future<void> _showDay(
    AppLocalizations l10n,
    DateTime date,
    List<Course> classes,
    List<AgendaItem> agenda,
  ) {
    final text = Theme.of(context).textTheme;

    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceMd,
            0,
            AppTheme.spaceMd,
            AppTheme.spaceMd,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${date.month}-${date.day} · '
                '${l10n.ttWeekdays.split(',')[date.weekday - 1]}',
                style: Theme.of(sheet).textTheme.titleMedium,
              ),
              const SizedBox(height: AppTheme.spaceSm),
              if (classes.isEmpty && agenda.isEmpty)
                Text(l10n.ttNothingOnDay,
                    style: Theme.of(sheet).textTheme.bodyMedium),
              for (final course in classes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.menu_book_outlined,
                          size: 18, color: Theme.of(sheet).colorScheme.primary),
                      const SizedBox(width: AppTheme.spaceSm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(course.name, style: text.bodyLarge),
                            Text(
                              [
                                '${l10n.ttPeriods} '
                                    '${course.startPeriod}-${course.endPeriod}',
                                if (course.startTime.isNotEmpty)
                                  course.startTime,
                                if (course.location.isNotEmpty) course.location,
                              ].join(' · '),
                              style: text.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              for (final item in agenda)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.check_circle_outline,
                          size: 18,
                          color: Theme.of(sheet).colorScheme.tertiary),
                      const SizedBox(width: AppTheme.spaceSm),
                      Expanded(
                        child: Text(
                          item.title,
                          style: text.bodyLarge?.copyWith(
                            decoration:
                                item.done ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _createProfile(AppLocalizations l10n) async {
    final name = await _askName(context, l10n, title: l10n.ttNewProfile);
    if (name == null || !mounted) return;
    final services = AppScope.of(context, dependOn: false);
    final result = await services.timetable.createProfile(name);
    if (!mounted) return;
    if (result is Failure) {
      _showMessage(result.errorOrNull?.message ?? '');
      return;
    }
    await _load();
  }
}

/// Asks for a timetable name; shared by "new" and "rename".
Future<String?> _askName(
  BuildContext context,
  AppLocalizations l10n, {
  required String title,
  String initial = '',
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(
        l10n: l10n,
        title: title,
        initial: initial,
      ),
    );

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.l10n,
    required this.title,
    required this.initial,
  });

  final AppLocalizations l10n;
  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    Navigator.of(context).pop(value.isEmpty ? null : value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.l10n.ttProfileName),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.l10n.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.l10n.save),
        ),
      ],
    );
  }
}

/// The weekly grid: period rows × day columns, with a block per class.
class _WeekGrid extends StatelessWidget {
  const _WeekGrid({
    super.key,
    required this.courses,
    required this.week,
    required this.firstWeekStart,
    required this.onTap,
  });

  final List<Course> courses;
  final int week;
  final DateTime firstWeekStart;
  final ValueChanged<Course> onTap;

  static const double _rowHeight = 54;
  static const double _dayWidth = 116;
  static const double _headerHeight = 42;
  static const int _rows = 12;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final labels = l10n.ttWeekdays.split(',');

    final weekStart = firstWeekStart.add(Duration(days: (week - 1) * 7));
    final grid = coursesForWeek(courses, week);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 30,
          child: Column(
            children: [
              const SizedBox(height: _headerHeight),
              for (var period = 1; period <= _rows; period++)
                SizedBox(
                  height: _rowHeight,
                  child: Center(
                    child: Text('$period', style: text.bodySmall),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: _dayWidth * 7,
              child: Column(
                children: [
                  Row(
                    children: [
                      for (var day = 1; day <= 7; day++)
                        SizedBox(
                          width: _dayWidth,
                          height: _headerHeight,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                labels[day - 1],
                                style: text.labelLarge?.copyWith(
                                  color: day == DateTime.now().weekday
                                      ? scheme.primary
                                      : null,
                                ),
                              ),
                              Text(
                                _shortDate(weekStart, day),
                                style: text.labelSmall?.copyWith(
                                  color: scheme.outline,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  SizedBox(
                    height: _rowHeight * _rows,
                    child: Stack(
                      children: [
                        for (var row = 0; row <= _rows; row++)
                          Positioned(
                            left: 0,
                            right: 0,
                            top: row * _rowHeight,
                            child: Divider(
                              height: 1,
                              color:
                                  scheme.outlineVariant.withValues(alpha: 0.5),
                            ),
                          ),
                        for (var day = 0; day < 7; day++)
                          Positioned(
                            left: day * _dayWidth,
                            top: 0,
                            bottom: 0,
                            child: VerticalDivider(
                              width: 1,
                              color:
                                  scheme.outlineVariant.withValues(alpha: 0.5),
                            ),
                          ),
                        for (var day = 1; day <= 7; day++)
                          for (final course in grid[day] ?? const <Course>[])
                            Positioned(
                              left: (day - 1) * _dayWidth + 3,
                              top: (course.startPeriod - 1) * _rowHeight + 2,
                              width: _dayWidth - 6,
                              height: course.periodCount * _rowHeight - 4,
                              child: _CourseBlock(
                                course: course,
                                onTap: () => onTap(course),
                              ),
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _shortDate(DateTime weekStart, int day) {
    final date = weekStart.add(Duration(days: day - 1));
    return '${date.month}/${date.day}';
  }
}

class _CourseBlock extends StatelessWidget {
  const _CourseBlock({required this.course, required this.onTap});

  final Course course;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final accent = _accentFor(course.name);

    return Material(
      color: accent.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: accent, width: 3)),
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          ),
          padding: const EdgeInsets.fromLTRB(6, 4, 4, 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                course.name,
                style: text.labelLarge?.copyWith(height: 1.15),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (course.location.isNotEmpty)
                Text(
                  course.location,
                  style:
                      text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// A stable colour per course name, so the same course is the same colour in
  /// every week and every view. Hue only — lightness comes from the theme.
  static Color _accentFor(String name) {
    const palette = [
      Color(0xFF1565C0),
      Color(0xFF2E7D32),
      Color(0xFFEF6C00),
      Color(0xFF6A1B9A),
      Color(0xFF00838F),
      Color(0xFFAD1457),
      Color(0xFF4527A0),
      Color(0xFF5D4037),
    ];
    return palette[name.hashCode.abs() % palette.length];
  }
}

class _MonthCell extends StatelessWidget {
  const _MonthCell({
    required this.day,
    required this.classes,
    required this.hasAgenda,
    required this.isToday,
    required this.onTap,
  });

  final CalendarDay day;
  final int classes;
  final bool hasAgenda;
  final bool isToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      child: Container(
        margin: const EdgeInsets.all(2),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          border:
              isToday ? Border.all(color: scheme.primary, width: 1.4) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${day.date.day}',
              style: text.labelMedium?.copyWith(
                color: day.inMonth ? null : scheme.outline,
                fontWeight: isToday ? FontWeight.w700 : null,
              ),
            ),
            const Spacer(),
            Wrap(
              spacing: 2,
              runSpacing: 2,
              children: [
                for (var i = 0; i < classes.clamp(0, 3); i++)
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                if (classes > 3)
                  Text('+', style: text.labelSmall?.copyWith(height: 0.6)),
                if (hasAgenda)
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: scheme.tertiary,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Create or edit a course.
class _CourseSheet extends StatefulWidget {
  const _CourseSheet({this.initial});

  final Course? initial;

  @override
  State<_CourseSheet> createState() => _CourseSheetState();
}

class _CourseSheetState extends State<_CourseSheet> {
  late final TextEditingController _name;
  late final TextEditingController _teacher;
  late final TextEditingController _location;
  late final TextEditingController _weeks;
  late final TextEditingController _time;

  late int _weekday;
  late int _start;
  late int _count;
  String? _error;

  bool get _editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final c = widget.initial;
    _name = TextEditingController(text: c?.name ?? '');
    _teacher = TextEditingController(text: c?.teacher ?? '');
    _location = TextEditingController(text: c?.location ?? '');
    _weeks = TextEditingController(
        text: formatWeeks(c?.weeks ??
            {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}));
    _time = TextEditingController(
      text: c != null && c.startTime.isNotEmpty
          ? '${c.startTime}${c.endTime.isEmpty ? '' : '-${c.endTime}'}'
          : '',
    );
    _weekday = c?.weekday ?? 1;
    _start = c?.startPeriod ?? 1;
    _count = c?.periodCount ?? 2;
  }

  @override
  void dispose() {
    _name.dispose();
    _teacher.dispose();
    _location.dispose();
    _weeks.dispose();
    _time.dispose();
    super.dispose();
  }

  void _save() {
    final l10n = AppLocalizations.of(context);
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.ttValidationName);
      return;
    }
    final parsed = parseWeeks(_weeks.text);
    if (parsed is Failure) {
      setState(() => _error = l10n.ttValidationWeeks);
      return;
    }
    final timeText = _time.text.trim();
    String startTime = '';
    String endTime = '';
    if (timeText.isNotEmpty) {
      final range = parseClassTimeRange(timeText);
      if (range == null) {
        setState(() => _error = l10n.ttTimeInvalid);
        return;
      }
      startTime = range.start;
      endTime = range.end;
    }

    final initial = widget.initial;
    final course = Course(
      id: initial?.id ??
          'c${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      name: name,
      weekday: _weekday,
      startPeriod: _start,
      periodCount: _count,
      weeks: parsed.requireValue,
      teacher: _teacher.text.trim(),
      location: _location.text.trim(),
      startTime: startTime,
      endTime: endTime,
    );
    Navigator.of(context).pop(course);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;

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
            Text(_editing ? l10n.ttEdit : l10n.ttAdd, style: text.titleLarge),
            const SizedBox(height: AppTheme.spaceMd),
            TextField(
              controller: _name,
              decoration: InputDecoration(hintText: l10n.ttName),
            ),
            const SizedBox(height: AppTheme.spaceSm),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _teacher,
                    decoration: InputDecoration(hintText: l10n.ttTeacher),
                  ),
                ),
                const SizedBox(width: AppTheme.spaceSm),
                Expanded(
                  child: TextField(
                    controller: _location,
                    decoration: InputDecoration(hintText: l10n.ttLocation),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.spaceSm),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _weekday,
                    decoration: InputDecoration(labelText: l10n.ttWeekday),
                    items: [
                      for (var d = 1; d <= 7; d++)
                        DropdownMenuItem(value: d, child: Text('$d')),
                    ],
                    onChanged: (v) => setState(() => _weekday = v ?? 1),
                  ),
                ),
                const SizedBox(width: AppTheme.spaceSm),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _start,
                    decoration: InputDecoration(labelText: l10n.ttStartPeriod),
                    items: [
                      for (var p = 1; p <= 12; p++)
                        DropdownMenuItem(value: p, child: Text('$p')),
                    ],
                    onChanged: (v) => setState(() => _start = v ?? 1),
                  ),
                ),
                const SizedBox(width: AppTheme.spaceSm),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _count,
                    decoration: InputDecoration(labelText: l10n.ttPeriodCount),
                    items: [
                      for (var c = 1; c <= 6; c++)
                        DropdownMenuItem(value: c, child: Text('$c')),
                    ],
                    onChanged: (v) => setState(() => _count = v ?? 1),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.spaceSm),
            TextField(
              controller: _weeks,
              decoration: InputDecoration(hintText: l10n.ttWeeks),
            ),
            const SizedBox(height: AppTheme.spaceSm),
            TextField(
              controller: _time,
              decoration: InputDecoration(
                hintText: l10n.ttStartTime,
                helperText: l10n.ttStartTimeHint,
                errorText: _error,
              ),
            ),
            const SizedBox(height: AppTheme.spaceMd),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.cancel),
                ),
                const SizedBox(width: AppTheme.spaceSm),
                FilledButton(onPressed: _save, child: Text(l10n.save)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Lists, renames and deletes the named timetables.
class _ProfileManager extends StatefulWidget {
  const _ProfileManager({required this.l10n, required this.repository});

  final AppLocalizations l10n;
  final TimetableRepository repository;

  @override
  State<_ProfileManager> createState() => _ProfileManagerState();
}

class _ProfileManagerState extends State<_ProfileManager> {
  List<TimetableProfile> _profiles = const [];
  String _activeId = '';
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profiles = await widget.repository.profiles();
    final active = await widget.repository.activeProfileId();
    if (!mounted) return;
    setState(() {
      _profiles = profiles.dataOrNull ?? const [];
      _activeId = active.dataOrNull ?? '';
      _error = profiles.errorOrNull?.message ?? '';
    });
  }

  Future<void> _create() async {
    final name =
        await _askName(context, widget.l10n, title: widget.l10n.ttNewProfile);
    if (name == null) return;
    final result = await widget.repository.createProfile(name);
    if (!mounted) return;
    if (result is Failure) {
      setState(() => _error = result.errorOrNull?.message ?? '');
      return;
    }
    await _load();
  }

  Future<void> _rename(TimetableProfile profile) async {
    final name = await _askName(
      context,
      widget.l10n,
      title: widget.l10n.ttManageProfiles,
      initial: profile.name,
    );
    if (name == null) return;
    final result = await widget.repository.renameProfile(profile.id, name);
    if (!mounted) return;
    if (result is Failure) {
      setState(() => _error = result.errorOrNull?.message ?? '');
      return;
    }
    await _load();
  }

  Future<void> _delete(TimetableProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(widget.l10n.ttDeleteProfile),
        content: Text(widget.l10n.ttDeleteProfileBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(widget.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(widget.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final result = await widget.repository.deleteProfile(profile.id);
    if (!mounted) return;
    if (result is Failure) {
      setState(() => _error = result.errorOrNull?.message ?? '');
      return;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;

    return AlertDialog(
      title: Text(l10n.ttManageProfiles),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: AppTheme.spaceSm),
                child: Text(
                  _error,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                ),
              ),
            for (final profile in _profiles)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  profile.id == _activeId
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                  size: 20,
                ),
                title: Text(
                  profile.name.isEmpty ? l10n.ttDefaultProfile : profile.name,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: l10n.ttEdit,
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      onPressed: () => _rename(profile),
                    ),
                    IconButton(
                      tooltip: l10n.delete,
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed:
                          _profiles.length <= 1 ? null : () => _delete(profile),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.close),
        ),
        FilledButton.icon(
          onPressed: _create,
          icon: const Icon(Icons.add, size: 18),
          label: Text(l10n.ttNewProfile),
        ),
      ],
    );
  }
}
