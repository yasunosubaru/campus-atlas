import '../../core/config/app_config.dart';
import '../../core/network/api_client.dart';
import '../../core/result.dart';

/// A searchable place, resolved through OpenStreetMap Nominatim.
class MapPlace {
  const MapPlace({
    required this.id,
    required this.name,
    required this.details,
    required this.latitude,
    required this.longitude,
    this.category = '',
  });

  final String id;
  final String name;
  final String details;
  final double latitude;
  final double longitude;
  final String category;

  /// `https://www.openstreetmap.org/<osm_type>/<osm_id>` when available.
  String? get osmUrl {
    final type = category.split('.').first;
    final id = this.id;
    if (type.isEmpty || id.isEmpty) return null;
    return 'https://www.openstreetmap.org/$type/$id';
  }
}

/// Place search over OSM Nominatim.
///
/// Nominatim is free but asks clients to (a) send an identifying User-Agent —
/// which [ApiClient] does — and (b) not hammer it. [lastQueryAt] enforces a
/// client-side minimum interval so an eager user typing quickly cannot trip
/// the public service's rate limit.
class MapRepository {
  MapRepository({required this.client, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final ApiClient client;
  final DateTime Function() _now;

  DateTime? lastQueryAt;

  Future<Result<List<MapPlace>>> search(String query, {int limit = 10}) async {
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      return Failure<List<MapPlace>>.reason(
        FailureKind.validation,
        message: 'Query must be at least 2 characters',
      );
    }

    final now = _now();
    final last = lastQueryAt;
    if (last != null) {
      final elapsed = now.difference(last);
      if (elapsed < AppConfig.nominatimMinInterval) {
        return Failure<List<MapPlace>>.reason(
          FailureKind.rateLimited,
          message: 'Please wait before searching again',
        );
      }
    }
    lastQueryAt = now;

    final uri = AppConfig.nominatimSearch.replace(
      queryParameters: {
        'q': trimmed,
        'format': 'jsonv2',
        'limit': '$limit',
        'addressdetails': '1',
        'accept-language': 'zh-CN,zh;q=0.9,en;q=0.6',
      },
    );

    final raw = await client.getJson(uri);
    if (raw is Failure) return Failure<List<MapPlace>>(raw.errorOrNull!);

    final results = raw.requireValue['data'];
    if (results is! List) {
      // jsonv2 returns a bare array; ApiClient wraps it under `data`.
      return Failure<List<MapPlace>>.reason(
        FailureKind.invalidData,
        message: 'Nominatim response missing results',
      );
    }

    final places = <MapPlace>[];
    for (final item in results) {
      if (item is! Map<String, Object?>) continue;
      final lat = double.tryParse('${item['lat'] ?? ''}');
      final lon = double.tryParse('${item['lon'] ?? ''}');
      if (lat == null || lon == null) continue;
      places.add(
        MapPlace(
          id: '${item['osm_id'] ?? ''}',
          name: '${item['name'] ?? ''}',
          details: _buildDetails(item),
          latitude: lat,
          longitude: lon,
          category: '${item['type'] ?? ''}.${item['osm_type'] ?? ''}',
        ),
      );
    }
    return Success(places);
  }

  static String _buildDetails(Map<String, Object?> item) {
    final address = item['address'];
    if (address is! Map<String, Object?>) {
      return '${item['display_name'] ?? ''}';
    }
    final locality = address['city'] ?? address['town'] ?? address['village'];
    final parts = <String>[
      if (address['road'] != null) '${address['road']}',
      if (address['suburb'] != null) '${address['suburb']}',
      if (locality != null) '$locality',
    ];
    if (parts.isEmpty) {
      final display = '${item['display_name'] ?? ''}';
      return display.split(',').take(3).join(', ');
    }
    return parts.join(' · ');
  }
}
