import '../../core/config/app_config.dart';
import '../../core/network/api_client.dart';
import '../../core/result.dart';
import '../../core/storage/settings.dart';
import 'weather_models.dart';

/// Fetches current conditions, a 7-day forecast, and air quality.
///
/// Data comes from Open-Meteo, which is free, keyless and attribution-free.
/// Two requests are made in parallel rather than serially so a slow air-quality
/// endpoint does not gate the weather the user actually asked for — air
/// quality is therefore best-effort and may be absent.
class WeatherRepository {
  WeatherRepository({
    required this.client,
    required this.settings,
  });

  final ApiClient client;
  final AppSettings settings;

  Future<Result<WeatherSnapshot>> load() async {
    final geo = await settings.location();
    final metric = await settings.metricWeather();

    final forecast = await _fetchForecast(geo, metric);
    if (forecast is Failure) return forecast;

    final airQuality = await _fetchAirQuality(geo);

    final snapshot = forecast.requireValue;
    return Success(
      airQuality is Success
          ? snapshot.copyWith(airQuality: airQuality.dataOrNull!)
          : snapshot,
    );
  }

  Future<Result<WeatherSnapshot>> _fetchForecast(
    Geo geo,
    bool metric,
  ) async {
    final unit = metric ? 'celsius' : 'fahrenheit';
    final windUnit = metric ? 'kmh' : 'mph';

    final uri = AppConfig.weatherForecast.replace(
      queryParameters: {
        'latitude': geo.latitude.toStringAsFixed(5),
        'longitude': geo.longitude.toStringAsFixed(5),
        'current': [
          'temperature_2m',
          'relative_humidity_2m',
          'apparent_temperature',
          'precipitation',
          'weather_code',
          'wind_speed_10m',
          'is_day',
        ].join(','),
        'daily': [
          'weather_code',
          'temperature_2m_max',
          'temperature_2m_min',
          'precipitation_probability_max',
        ].join(','),
        'temperature_unit': unit,
        'wind_speed_unit': windUnit,
        'timezone': 'Asia/Shanghai',
        'forecast_days': '7',
      },
    );

    final raw = await client.getJson(uri);
    if (raw is Failure) return Failure<WeatherSnapshot>(raw.errorOrNull!);

    final payload = raw.requireValue;
    final current = payload['current'];
    if (current is! Map<String, Object?>) {
      return Failure<WeatherSnapshot>.reason(
        FailureKind.invalidData,
        message: 'forecast response missing current block',
        endpoint: 'open-meteo/forecast',
      );
    }

    final parsedCurrent = CurrentWeather.fromJson(current);
    if (parsedCurrent is Failure) {
      return Failure<WeatherSnapshot>(parsedCurrent.errorOrNull!);
    }

    final daily = parseDaily(payload);
    if (daily is Failure) {
      return Failure<WeatherSnapshot>(daily.errorOrNull!);
    }

    return Success(
      WeatherSnapshot(
        current: parsedCurrent.dataOrNull!,
        daily: daily.dataOrNull!,
        locationLabel: geo.name,
        fetchedAt: DateTime.now(),
      ),
    );
  }

  Future<Result<AirQuality>> _fetchAirQuality(Geo geo) async {
    final uri = AppConfig.airQuality.replace(
      queryParameters: {
        'latitude': geo.latitude.toStringAsFixed(5),
        'longitude': geo.longitude.toStringAsFixed(5),
        'current': 'us_aqi,pm2_5',
        'timezone': 'Asia/Shanghai',
      },
    );
    final raw = await client.getJson(uri);
    if (raw is Failure) return Failure<AirQuality>(raw.errorOrNull!);
    return AirQuality.fromJson(raw.requireValue);
  }

  /// Reverse geocode-free place search, used by the location picker.
  Future<Result<List<PlaceSearchResult>>> searchPlaces(
    String query, {
    int limit = 8,
  }) async {
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      return Failure<List<PlaceSearchResult>>.reason(
        FailureKind.validation,
        message: 'Query must be at least 2 characters',
      );
    }
    final uri = AppConfig.geocoding.replace(
      queryParameters: {
        'name': trimmed,
        'count': '$limit',
        'language': 'zh',
        'format': 'json',
      },
    );
    final raw = await client.getJson(uri);
    if (raw is Failure) {
      return Failure<List<PlaceSearchResult>>(raw.errorOrNull!);
    }

    final results = raw.requireValue['results'];
    if (results is! List) {
      return Failure<List<PlaceSearchResult>>.reason(
        FailureKind.invalidData,
        message: 'geocoding response missing results',
      );
    }
    final out = <PlaceSearchResult>[];
    for (final item in results) {
      if (item is! Map<String, Object?>) continue;
      final lat = parseDouble(item['latitude']);
      final lon = parseDouble(item['longitude']);
      if (lat == null || lon == null) continue;
      out.add(
        PlaceSearchResult(
          name: '${item['name'] ?? ''}',
          detail: [
            if (item['admin1'] != null) '${item['admin1']}',
            if (item['country'] != null) '${item['country']}',
          ].join(' · '),
          latitude: lat,
          longitude: lon,
        ),
      );
    }
    return Success(out);
  }
}

class PlaceSearchResult {
  const PlaceSearchResult({
    required this.name,
    required this.detail,
    required this.latitude,
    required this.longitude,
  });

  final String name;
  final String detail;
  final double latitude;
  final double longitude;

  Geo toGeo() => Geo(latitude, longitude, name: name);
}
