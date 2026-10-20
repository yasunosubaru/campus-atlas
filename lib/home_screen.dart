import 'dart:async';

import 'package:flutter/material.dart';

import 'core/i18n/app_localizations.dart';
import 'core/result.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/common.dart';
import 'features/agenda/agenda_repository.dart';
import 'features/timetable/calendar.dart';
import 'features/timetable/reminders.dart';
import 'features/timetable/timetable_models.dart';
import 'features/timetable/timetable_repository.dart';
import 'features/weather/weather_models.dart';
import 'main.dart';

/// Dashboard: the next class, today's classes, a weather summary, and today's
/// agenda.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Result<WeatherSnapshot>? _weather;
  Result<List<Course>> _courses = const Success([]);
  Result<List<AgendaItem>> _agenda = const Success([]);
  DateTime _firstWeekStart = DateTime(2026, 2, 23);
  int _week = 0;
  bool _metric = true;
  bool _loading = true;

  /// The course whose "starts soon" reminder has already been shown, so the
  /// minute timer does not repeat it every tick.
  String? _announcedCourseId;

  Timer? _timer;

  late final ValueNotifier<int> _timetableChanges;

  @override
  void initState() {
    super.initState();
    _timetableChanges = AppScope.of(context, dependOn: false).timetableChanges;
    _timetableChanges.addListener(_reloadTimetable);
    _load();
    // A minute is enough for a countdown that shows minutes, and cheap enough
    // to leave running while the app is open. This is an **in-app** reminder:
    // nothing fires while the app is closed, because that would need an OS
    // notification channel the project does not ship.
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _timetableChanges.removeListener(_reloadTimetable);
    _timer?.cancel();
    super.dispose();
  }

  void _reloadTimetable() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    final scope = AppScope.of(context, dependOn: false);
    setState(() => _loading = true);

    final now = DateTime.now();
    final firstWeek = await scope.settings.firstWeekStart();
    final metric = await scope.settings.metricWeather();
    final week = weekNumberFor(now, firstWeek);

    final results = await Future.wait([
      scope.weather.load(),
      scope.timetable.load(),
      scope.agenda.list(),
    ]);

    if (!mounted) return;
    setState(() {
      _weather = results[0] as Result<WeatherSnapshot>;
      _courses = results[1] as Result<List<Course>>;
      _agenda = results[2] as Result<List<AgendaItem>>;
      _firstWeekStart = firstWeek;
      _week = week;
      _metric = metric;
      _loading = false;
    });
    _announceIfDue();
  }

  void _tick() {
    if (!mounted) return;
    setState(() {}); // refresh the countdown
    _announceIfDue();
  }

  void _announceIfDue() {
    if (!mounted || _loading) return;
    final now = DateTime.now();
    final reminder = nextClass(
      now: now,
      firstWeekStart: _firstWeekStart,
      courses: _courses.dataOrNull ?? const [],
    );
    if (reminder == null) return;

    final until = reminder.timeUntil(now);
    if (until.isNegative || until.inMinutes > 15) return;
    if (_announcedCourseId == reminder.course.id) return;
    _announcedCourseId = reminder.course.id;

    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            l10n.homeReminderBody
                .replaceAll('%s', reminder.course.name)
                .replaceAll('%d', '${until.inMinutes}'),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;

    final now = DateTime.now();
    final courses =
        _courses is Success ? _courses.requireValue : const <Course>[];
    final todayCourses = coursesOnDate(courses, now, _firstWeekStart);
    final next = nextClass(
      now: now,
      firstWeekStart: _firstWeekStart,
      courses: courses,
    );
    final agenda = _agenda is Success
        ? agendaOnDate(_agenda.requireValue, now)
        : const <AgendaItem>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.retry,
            onPressed: _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceMd,
            AppTheme.spaceSm,
            AppTheme.spaceMd,
            AppTheme.spaceXl,
          ),
          children: [
            _WeatherCard(
              week: _week,
              weather: _weather,
              loading: _loading,
              metric: _metric,
              onRetry: _load,
            ),
            const SizedBox(height: AppTheme.spaceMd),
            _NextClassCard(reminder: next, now: now),
            const SizedBox(height: AppTheme.spaceMd),
            SectionHeader('${l10n.ttToday}${_week > 0 ? ' · $_week' : ''}'),
            if (_loading)
              const _SkeletonLines(count: 3)
            else if (_courses is Failure)
              ErrorState(failure: _courses, onRetry: _load)
            else if (todayCourses.isEmpty)
              EmptyState(
                title: l10n.ttEmpty,
                body: l10n.emptyBody,
                icon: Icons.free_breakfast_outlined,
              )
            else
              for (final c in todayCourses) ...[
                _CourseCard(course: c),
                const SizedBox(height: AppTheme.spaceSm),
              ],
            const SizedBox(height: AppTheme.spaceMd),
            SectionHeader(l10n.agendaTitle),
            if (_loading)
              const _SkeletonLines(count: 2)
            else if (agenda.isEmpty)
              Panel(
                child: Row(
                  children: [
                    Icon(Icons.event_available_outlined,
                        color: Theme.of(context).colorScheme.outline),
                    const SizedBox(width: AppTheme.spaceMd),
                    Expanded(
                      child:
                          Text(l10n.homeNoAgendaToday, style: text.bodyLarge),
                    ),
                  ],
                ),
              )
            else
              Panel(
                child: Column(
                  children: [
                    for (final item in agenda)
                      Row(
                        children: [
                          Icon(
                            item.done
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            size: 18,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: AppTheme.spaceSm),
                          Expanded(
                            child: Text(
                              item.title,
                              style: text.bodyLarge?.copyWith(
                                decoration: item.done
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The next class, with a countdown while it is close.
class _NextClassCard extends StatelessWidget {
  const _NextClassCard({required this.reminder, required this.now});

  final ClassReminder? reminder;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final r = reminder;

    if (r == null) {
      return Panel(
        child: Row(
          children: [
            Icon(Icons.free_breakfast_outlined, color: scheme.outline),
            const SizedBox(width: AppTheme.spaceMd),
            Expanded(child: Text(l10n.homeNoUpcoming, style: text.bodyLarge)),
          ],
        ),
      );
    }

    final until = r.timeUntil(now);
    final running = r.isRunning(now);
    final soon = !running && until.inMinutes <= 15;

    return Panel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 52,
            decoration: BoxDecoration(
              color: soon ? scheme.error : scheme.primary,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: AppTheme.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.homeNextClass, style: text.labelLarge),
                const SizedBox(height: 2),
                Text(r.course.name, style: text.titleMedium),
                const SizedBox(height: 2),
                Text(
                  [
                    if (running)
                      l10n.homeRunning
                    else if (until.inMinutes <= 60)
                      l10n.homeInMinutes.replaceAll('%d', '${until.inMinutes}')
                    else
                      '${formatClock(r.startsAt)} ${l10n.homeStartsAt}',
                    if (r.course.location.isNotEmpty) r.course.location,
                  ].join(' · '),
                  style: text.bodySmall?.copyWith(
                    color: soon ? scheme.error : null,
                  ),
                ),
              ],
            ),
          ),
          Text(
            formatClock(r.startsAt),
            style: text.titleMedium?.copyWith(
              color: soon ? scheme.error : scheme.primary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _WeatherCard extends StatelessWidget {
  const _WeatherCard({
    required this.week,
    required this.weather,
    required this.loading,
    required this.metric,
    required this.onRetry,
  });

  final int week;
  final Result<WeatherSnapshot>? weather;
  final bool loading;
  final bool metric;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    if (loading || weather == null) {
      return const Panel(child: _SkeletonLines(count: 2));
    }

    return weather!.fold(
      (data) => Panel(
        padding: const EdgeInsets.all(AppTheme.spaceLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${data.current.temperature.round()}°'
                        '${metric ? 'C' : 'F'}',
                        style: text.displaySmall,
                      ),
                      Text(
                        data.locationLabel.isEmpty
                            ? l10n.weatherTitle
                            : data.locationLabel,
                        style: text.bodyMedium,
                      ),
                    ],
                  ),
                ),
                Icon(
                  _iconFor(data.current.kind),
                  size: 56,
                  color: scheme.primary,
                ),
              ],
            ),
            const SizedBox(height: AppTheme.spaceMd),
            Wrap(
              spacing: AppTheme.spaceLg,
              runSpacing: AppTheme.spaceSm,
              children: [
                StatTile(
                  icon: Icons.thermostat_outlined,
                  label: l10n.weatherFeelsLike,
                  value: '${data.current.feelsLike.round()}°',
                ),
                StatTile(
                  icon: Icons.water_drop_outlined,
                  label: l10n.weatherHumidity,
                  value: '${data.current.humidity}%',
                ),
                StatTile(
                  icon: Icons.air_outlined,
                  label: l10n.weatherWind,
                  value: '${data.current.windSpeed.round()}',
                ),
                if (data.airQuality != null)
                  StatTile(
                    icon: Icons.eco_outlined,
                    label: l10n.weatherAqi,
                    value: '${data.airQuality!.usAqi}',
                  ),
              ],
            ),
          ],
        ),
      ),
      (failure) => ErrorState(failure: failure, onRetry: onRetry),
    );
  }

  IconData _iconFor(WeatherKind kind) => switch (kind) {
        WeatherKind.clear => Icons.wb_sunny_outlined,
        WeatherKind.partlyCloudy => Icons.wb_cloudy_outlined,
        WeatherKind.overcast => Icons.cloud_outlined,
        WeatherKind.fog => Icons.foggy,
        WeatherKind.rain || WeatherKind.showers => Icons.water_drop_outlined,
        WeatherKind.snow || WeatherKind.snowShowers => Icons.ac_unit,
        WeatherKind.thunderstorm => Icons.thunderstorm_outlined,
        _ => Icons.device_thermostat_outlined,
      };
}

class _CourseCard extends StatelessWidget {
  const _CourseCard({required this.course});

  final Course course;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spaceMd),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 4,
              height: 56,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: AppTheme.spaceMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(course.name, style: text.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    [
                      '第 ${course.startPeriod}-${course.endPeriod} 节',
                      if (course.startTime.isNotEmpty) course.startTime,
                      if (course.location.isNotEmpty) course.location,
                      if (course.teacher.isNotEmpty) course.teacher,
                    ].join(' · '),
                    style: text.bodyMedium,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkeletonLines extends StatelessWidget {
  const _SkeletonLines({this.count = 3});

  final int count;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (var i = 0; i < count; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
              ),
            ),
        ],
      );
}
