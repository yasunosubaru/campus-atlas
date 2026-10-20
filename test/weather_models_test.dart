import 'package:campus_atlas/core/result.dart';
import 'package:campus_atlas/features/weather/weather_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('weatherKindFromCode', () {
    test('maps the WMO codes we rely on', () {
      expect(weatherKindFromCode(0), WeatherKind.clear);
      expect(weatherKindFromCode(1), WeatherKind.partlyCloudy);
      expect(weatherKindFromCode(3), WeatherKind.overcast);
      expect(weatherKindFromCode(45), WeatherKind.fog);
      expect(weatherKindFromCode(61), WeatherKind.rain);
      expect(weatherKindFromCode(71), WeatherKind.snow);
      expect(weatherKindFromCode(95), WeatherKind.thunderstorm);
    });

    test('falls back to unknown rather than throwing', () {
      expect(weatherKindFromCode(-1), WeatherKind.unknown);
      expect(weatherKindFromCode(999), WeatherKind.unknown);
    });
  });

  group('CurrentWeather.fromJson', () {
    final payload = <String, Object?>{
      'time': '2026-10-14T12:00',
      'temperature_2m': 21.5,
      'apparent_temperature': 20.0,
      'relative_humidity_2m': 64,
      'wind_speed_10m': 12.3,
      'precipitation': 0.0,
      'weather_code': 2,
      'is_day': 1,
    };

    test('reads every field', () {
      final r = CurrentWeather.fromJson(payload);
      expect(r.isSuccess, isTrue);
      final c = r.requireValue;
      expect(c.temperature, 21.5);
      expect(c.feelsLike, 20.0);
      expect(c.humidity, 64);
      expect(c.windSpeed, 12.3);
      expect(c.precipitation, 0.0);
      expect(c.weatherCode, 2);
      expect(c.isDay, isTrue);
      expect(c.kind, WeatherKind.partlyCloudy);
    });

    test('falls back to the temperature when apparent is absent', () {
      final r =
          CurrentWeather.fromJson({...payload}..remove('apparent_temperature'));
      expect(r.requireValue.feelsLike, 21.5);
    });

    test('coerces an integer temperature', () {
      final r = CurrentWeather.fromJson({...payload}..['temperature_2m'] = 20);
      expect(r.requireValue.temperature, 20.0);
    });

    test('fails loudly when the headline temperature is missing', () {
      final r = CurrentWeather.fromJson({...payload}..remove('temperature_2m'));
      expect(r.isSuccess, isFalse);
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });
  });

  group('parseDaily', () {
    final payload = <String, Object?>{
      'daily': {
        'time': ['2026-10-14', '2026-10-15'],
        'temperature_2m_max': [24.0, 22.0],
        'temperature_2m_min': [15.0, 14.0],
        'weather_code': [1, 61],
        'precipitation_probability_max': [10, 80],
      },
    };

    test('produces one row per day', () {
      final r = parseDaily(payload);
      expect(r.isSuccess, isTrue);
      expect(r.requireValue.length, 2);
      expect(r.requireValue.first.high, 24.0);
      expect(r.requireValue.first.low, 15.0);
      expect(r.requireValue.first.precipitationProbability, 10);
      expect(r.requireValue.last.kind, WeatherKind.rain);
    });

    test('fails when the daily block is missing', () {
      final r = parseDaily(const {});
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });

    test('fails when daily.time is absent', () {
      final r = parseDaily(const {'daily': <String, Object?>{}});
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });

    test('fails rather than returning an empty forecast', () {
      final r = parseDaily(const {
        'daily': {'time': <Object?>[]},
      });
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });
  });

  group('AirQuality', () {
    test('reads us_aqi and pm2_5', () {
      final r = AirQuality.fromJson(const {
        'current': {'us_aqi': 42, 'pm2_5': 9.5},
      });
      expect(r.isSuccess, isTrue);
      expect(r.requireValue.usAqi, 42);
      expect(r.requireValue.pm25, 9.5);
    });

    test('fails when the current block is missing', () {
      final r = AirQuality.fromJson(const {});
      expect(r.errorOrNull?.kind, FailureKind.invalidData);
    });

    test('bands every AQI boundary correctly', () {
      expect(const AirQuality(usAqi: 0).band, 'good');
      expect(const AirQuality(usAqi: 50).band, 'good');
      expect(const AirQuality(usAqi: 51).band, 'moderate');
      expect(const AirQuality(usAqi: 100).band, 'moderate');
      expect(const AirQuality(usAqi: 101).band, 'unhealthySensitive');
      expect(const AirQuality(usAqi: 150).band, 'unhealthySensitive');
      expect(const AirQuality(usAqi: 151).band, 'unhealthy');
      expect(const AirQuality(usAqi: 200).band, 'unhealthy');
      expect(const AirQuality(usAqi: 201).band, 'veryUnhealthy');
      expect(const AirQuality(usAqi: 300).band, 'veryUnhealthy');
      expect(const AirQuality(usAqi: 301).band, 'hazardous');
      expect(const AirQuality(usAqi: 500).band, 'hazardous');
    });
  });
}
