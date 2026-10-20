import 'package:flutter/material.dart';

import '../../core/i18n/app_localizations.dart';
import '../../core/result.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../main.dart';
import '../settings/location_picker.dart';
import 'weather_models.dart';

/// Dedicated weather view: current conditions plus a 7-day list.
class WeatherScreen extends StatefulWidget {
  const WeatherScreen({super.key});

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  Result<WeatherSnapshot>? _snapshot;
  bool _loading = true;
  DateTime? _lastUpdated;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final services = AppScope.of(context, dependOn: false);
    if (!_loading) setState(() => _loading = true);

    final result = await services.weather.load();
    if (!mounted) return;
    setState(() {
      _snapshot = result;
      _loading = false;
      if (result is Success) _lastUpdated = DateTime.now();
    });
  }

  Future<void> _pickLocation() async {
    final services = AppScope.of(context, dependOn: false);
    final picked = await showLocationPicker(context);
    if (picked == null || !mounted) return;
    await services.settings.setLocation(picked);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.weatherTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.place_outlined),
            tooltip: l10n.settingsLocation,
            onPressed: _pickLocation,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.retry,
            onPressed: _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading && _snapshot == null
            ? const SizedBox(
                height: 240,
                child: CenterLoader(),
              )
            : _snapshot == null
                ? ListView(
                    children: [
                      SizedBox(
                        height: 320,
                        child: ErrorState(
                          failure: const AppFailure(FailureKind.unknown),
                          onRetry: _load,
                        ),
                      ),
                    ],
                  )
                : _snapshot!.fold(
                    (data) => _Body(
                      data: data,
                      lastUpdated: _lastUpdated,
                      onRefresh: _load,
                    ),
                    (failure) => ListView(
                      children: [
                        SizedBox(
                          height: 360,
                          child: ErrorState(
                            failure: failure,
                            onRetry: _load,
                          ),
                        ),
                      ],
                    ),
                  ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body(
      {required this.data, required this.lastUpdated, required this.onRefresh});

  final WeatherSnapshot data;
  final DateTime? lastUpdated;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final current = data.current;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spaceMd,
        AppTheme.spaceSm,
        AppTheme.spaceMd,
        AppTheme.spaceXl,
      ),
      children: [
        Panel(
          padding: const EdgeInsets.all(AppTheme.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${current.temperature.round()}°',
                      style: text.displaySmall,
                    ),
                  ),
                  Icon(
                    _iconFor(current.kind),
                    size: 64,
                    color: scheme.primary,
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.spaceSm),
              Text(
                [
                  data.locationLabel,
                  if (lastUpdated != null)
                    '${l10n.weatherUpdated} ${_hhmm(lastUpdated!)}',
                ].join(' · '),
                style: text.bodyMedium,
              ),
              const SizedBox(height: AppTheme.spaceMd),
              Wrap(
                spacing: AppTheme.spaceLg,
                runSpacing: AppTheme.spaceSm,
                children: [
                  StatTile(
                    icon: Icons.thermostat_outlined,
                    label: l10n.weatherFeelsLike,
                    value: '${current.feelsLike.round()}°',
                  ),
                  StatTile(
                    icon: Icons.water_drop_outlined,
                    label: l10n.weatherHumidity,
                    value: '${current.humidity}%',
                  ),
                  StatTile(
                    icon: Icons.air_outlined,
                    label: l10n.weatherWind,
                    value: '${current.windSpeed.round()}',
                  ),
                  StatTile(
                    icon: Icons.umbrella_outlined,
                    label: l10n.weatherPrecipitation,
                    value: '${current.precipitation}',
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
        SectionHeader(l10n.weatherForecast7),
        Panel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < data.daily.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
                _DailyRow(day: data.daily[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static IconData _iconFor(WeatherKind kind) => switch (kind) {
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

class _DailyRow extends StatelessWidget {
  const _DailyRow({required this.day});

  final DailyForecast day;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spaceMd,
        vertical: AppTheme.spaceSm + 2,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(
              weekdays[day.date.weekday - 1],
              style: text.bodyMedium,
            ),
          ),
          Icon(_iconFor(day.kind), size: 22, color: text.bodySmall?.color),
          const SizedBox(width: AppTheme.spaceMd),
          Expanded(
            child: Text(
              day.precipitationProbability == null
                  ? ''
                  : '${day.precipitationProbability}%',
              style: text.bodySmall,
            ),
          ),
          Text('${day.low.round()}°', style: text.bodyMedium),
          const SizedBox(width: AppTheme.spaceSm),
          Text('${day.high.round()}°', style: text.labelLarge),
        ],
      ),
    );
  }

  static IconData _iconFor(WeatherKind kind) => switch (kind) {
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
