/// Compile-time and runtime configuration.
///
/// Everything that differs between a development build and a release build
/// lives here, so there is one obvious place to look — and one place to audit
/// before shipping.
library;

/// Campus coordinates. Used as the default for weather and map queries until
/// the user overrides them in settings.
class GeoPoint {
  const GeoPoint(this.latitude, this.longitude);
  final double latitude;
  final double longitude;

  @override
  String toString() =>
      '${latitude.toStringAsFixed(5)},${longitude.toStringAsFixed(5)}';
}

abstract final class AppConfig {
  /// App-wide identity. Deliberately distinct from any other campus client so
  /// servers can tell us apart and so logs are not ambiguous.
  static const String appName = 'Campus Atlas';
  static const String userAgent = 'campus-atlas/0.1 (+open-source)';

  /// Default location: central campus. Overridable per user.
  ///
  /// The raw doubles are exposed alongside [GeoPoint] because Dart cannot read
  /// a field off a const object inside another const expression.
  static const double defaultLatitude = 30.538;
  static const double defaultLongitude = 114.362;
  static const GeoPoint defaultLocation =
      GeoPoint(defaultLatitude, defaultLongitude);

  /// Open-Meteo — public, keyless, attribution-free.
  /// https://open-meteo.com/en/docs
  static final Uri weatherForecast = Uri.parse(
    'https://api.open-meteo.com/v1/forecast',
  );
  static final Uri airQuality = Uri.parse(
    'https://air-quality-api.open-meteo.com/v1/air-quality',
  );
  static final Uri geocoding = Uri.parse(
    'https://geocoding-api.open-meteo.com/v1/search',
  );

  /// OpenStreetMap Nominatim — keyless, but rate-limited and requires an
  /// identifying User-Agent, which [ApiClient] supplies.
  /// https://nominatim.org/release-docs/develop/api/Search/
  static final Uri nominatimSearch = Uri.parse(
    'https://nominatim.openstreetmap.org/search',
  );

  /// Public course / timetable catalogue.
  ///
  /// This host serves the course catalogue, the master timetable and the
  /// six-dimension rating aggregates without authentication. It is a third
  /// party service: the app points at whatever base URL is configured, and the
  /// user can override it in settings if the operator relocates it.
  static final Uri courseApi = Uri.parse('https://api-whu-sb.tsinbei.cn');

  /// Default AI endpoint shape. OpenAI-compatible `/v1` works with a lot of
  /// local and hosted servers (llama.cpp, Ollama, vLLM, OpenAI, etc.).
  static const String defaultAiBase = '';
  static const List<String> knownChatCompletionsPaths = [
    '/chat/completions',
    '/v1/chat/completions',
    '/completions',
  ];

  /// Network policy.
  static const Duration requestTimeout = Duration(seconds: 20);
  static const int maxRetries = 2;

  /// Nominatim asks for a maximum of one request per second from a client.
  static const Duration nominatimMinInterval = Duration(milliseconds: 1100);

  /// Only https by default. Cleartext is opt-in because several campus
  /// backends still serve plain HTTP, and we do not want to silently downgrade.
  static const bool allowCleartext = false;
}
