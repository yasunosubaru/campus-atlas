import '../../core/result.dart';

/// WMO weather interpretation codes.
/// https://open-meteo.com/en/docs/weather-api > "Weather interpretation code"
enum WeatherKind {
  clear,
  partlyCloudy,
  overcast,
  fog,
  drizzle,
  rain,
  freezingRain,
  snow,
  showers,
  snowShowers,
  thunderstorm,
  unknown,
}

WeatherKind weatherKindFromCode(int code) => switch (code) {
      0 => WeatherKind.clear,
      1 || 2 => WeatherKind.partlyCloudy,
      3 => WeatherKind.overcast,
      45 || 48 => WeatherKind.fog,
      51 ||
      53 ||
      55 ||
      56 ||
      57 ||
      61 ||
      63 ||
      65 ||
      66 ||
      67 ||
      80 ||
      81 ||
      82 =>
        WeatherKind.rain,
      71 || 73 || 75 || 77 => WeatherKind.snow,
      85 || 86 => WeatherKind.snowShowers,
      95 || 96 || 99 => WeatherKind.thunderstorm,
      _ => WeatherKind.unknown,
    };

/// Material icon for a [WeatherKind]. Pure so it is unit-testable.
String weatherLabelKey(WeatherKind kind) => switch (kind) {
      WeatherKind.clear => 'clear',
      WeatherKind.partlyCloudy => 'partly',
      WeatherKind.overcast => 'overcast',
      WeatherKind.fog => 'fog',
      WeatherKind.drizzle => 'drizzle',
      WeatherKind.rain => 'rain',
      WeatherKind.freezingRain => 'sleet',
      WeatherKind.snow => 'snow',
      WeatherKind.showers => 'rain',
      WeatherKind.snowShowers => 'snow',
      WeatherKind.thunderstorm => 'storm',
      WeatherKind.unknown => 'unknown',
    };

/// A single observation from the `current` block.
class CurrentWeather {
  const CurrentWeather({
    required this.time,
    required this.temperature,
    required this.feelsLike,
    required this.humidity,
    required this.windSpeed,
    required this.precipitation,
    required this.weatherCode,
    this.isDay = true,
  });

  final DateTime time;
  final double temperature;
  final double feelsLike;
  final int humidity;
  final double windSpeed;
  final double precipitation;
  final int weatherCode;
  final bool isDay;

  WeatherKind get kind => weatherKindFromCode(weatherCode);

  static Result<CurrentWeather> fromJson(Map<String, Object?> json) {
    final t = _double(json['temperature_2m']);
    if (t == null) {
      return Failure<CurrentWeather>.reason(
        FailureKind.invalidData,
        message: 'current.temperature_2m missing',
      );
    }
    final time = DateTime.tryParse('${json['time'] ?? ''}');
    return Success(
      CurrentWeather(
        time: time ?? DateTime.now(),
        temperature: t,
        feelsLike: _double(json['apparent_temperature']) ?? t,
        humidity: _int(json['relative_humidity_2m']) ?? 0,
        windSpeed: _double(json['wind_speed_10m']) ?? 0,
        precipitation: _double(json['precipitation']) ?? 0,
        weatherCode: _int(json['weather_code']) ?? -1,
        isDay: (_int(json['is_day']) ?? 1) == 1,
      ),
    );
  }
}

/// One row of the daily forecast table.
class DailyForecast {
  const DailyForecast({
    required this.date,
    required this.code,
    required this.high,
    required this.low,
    this.precipitationProbability,
  });

  final DateTime date;
  final int code;
  final double high;
  final double low;
  final int? precipitationProbability;

  WeatherKind get kind => weatherKindFromCode(code);
}

/// Air quality reading (US AQI + PM2.5).
class AirQuality {
  const AirQuality({required this.usAqi, this.pm25});

  final int usAqi;
  final double? pm25;

  /// Coarse human label, using the official US AQI bands:
  /// 0-50 Good, 51-100 Moderate, 101-150 Unhealthy for Sensitive Groups,
  /// 151-200 Unhealthy, 201-300 Very Unhealthy, 301+ Hazardous.
  String get band {
    if (usAqi <= 50) return 'good';
    if (usAqi <= 100) return 'moderate';
    if (usAqi <= 150) return 'unhealthySensitive';
    if (usAqi <= 200) return 'unhealthy';
    if (usAqi <= 300) return 'veryUnhealthy';
    return 'hazardous';
  }

  static Result<AirQuality> fromJson(Map<String, Object?> json) {
    final current = json['current'];
    if (current is! Map<String, Object?>) {
      return Failure<AirQuality>.reason(
        FailureKind.invalidData,
        message: 'air-quality response missing current block',
      );
    }
    final aqi = _int(current['us_aqi']);
    if (aqi == null) {
      return Failure<AirQuality>.reason(
        FailureKind.invalidData,
        message: 'current.us_aqi missing',
      );
    }
    return Success(AirQuality(usAqi: aqi, pm25: _double(current['pm2_5'])));
  }
}

/// Everything the weather screen needs in one payload.
class WeatherSnapshot {
  const WeatherSnapshot({
    required this.current,
    required this.daily,
    this.airQuality,
    this.locationLabel = '',
    this.fetchedAt,
  });

  final CurrentWeather current;
  final List<DailyForecast> daily;
  final AirQuality? airQuality;
  final String locationLabel;
  final DateTime? fetchedAt;

  WeatherSnapshot copyWith({
    CurrentWeather? current,
    List<DailyForecast>? daily,
    AirQuality? airQuality,
    DateTime? fetchedAt,
  }) =>
      WeatherSnapshot(
        current: current ?? this.current,
        daily: daily ?? this.daily,
        airQuality: airQuality ?? this.airQuality,
        locationLabel: locationLabel,
        fetchedAt: fetchedAt ?? this.fetchedAt,
      );
}

double? _double(Object? v) {
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is double) return v.round();
  if (v is String) return int.tryParse(v);
  return null;
}

/// Shared with the daily parser — exported for tests.
double? parseDouble(Object? v) => _double(v);
int? parseInt(Object? v) => _int(v);

/// Parses the `daily` object of an Open-Meteo forecast response.
Result<List<DailyForecast>> parseDaily(Map<String, Object?> forecast) {
  final daily = forecast['daily'];
  if (daily is! Map<String, Object?>) {
    return Failure<List<DailyForecast>>.reason(
      FailureKind.invalidData,
      message: 'daily block missing',
    );
  }
  final times = daily['time'];
  if (times is! List) {
    return Failure<List<DailyForecast>>.reason(
      FailureKind.invalidData,
      message: 'daily.time missing',
    );
  }
  final maxes = (daily['temperature_2m_max'] as List?) ?? const [];
  final mins = (daily['temperature_2m_min'] as List?) ?? const [];
  final codes = (daily['weather_code'] as List?) ?? const [];
  final pops = (daily['precipitation_probability_max'] as List?) ?? const [];

  final out = <DailyForecast>[];
  for (var i = 0; i < times.length; i++) {
    final date = DateTime.tryParse('${times[i]}');
    if (date == null) continue;
    out.add(
      DailyForecast(
        date: date,
        code: parseInt(codes.elementAtOrNull(i)) ?? -1,
        high: parseInt(maxes.elementAtOrNull(i)) == null
            ? (parseDouble(maxes.elementAtOrNull(i)) ?? 0)
            : (parseDouble(maxes.elementAtOrNull(i)) ?? 0),
        low: parseDouble(mins.elementAtOrNull(i)) ?? 0,
        precipitationProbability: parseInt(pops.elementAtOrNull(i)),
      ),
    );
  }
  if (out.isEmpty) {
    return Failure<List<DailyForecast>>.reason(
      FailureKind.invalidData,
      message: 'daily contained no parseable rows',
    );
  }
  return Success(out);
}
