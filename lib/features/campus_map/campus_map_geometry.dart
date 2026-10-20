import 'dart:math' as math;
import 'dart:ui';

import 'campus_data.dart';

/// Projects campus coordinates into a widget-sized canvas.
///
/// A plain equirectangular projection with the longitude span corrected by
/// `cos(latitude)` — at 30.5°N a degree of longitude is about 14% shorter than
/// a degree of latitude, and ignoring that would stretch the campus east-west.
/// The result is letterboxed inside [size] so the campus keeps its shape instead
/// of being squashed into whatever the widget happens to be.
class CampusMapGeometry {
  CampusMapGeometry(this.size) {
    final midLat = (campusSouth + campusNorth) / 2 * math.pi / 180;
    final lonSpan = (campusEast - campusWest) * math.cos(midLat);
    final latSpan = campusNorth - campusSouth;
    final aspect = lonSpan / latSpan;

    var width = size.width;
    var height = width / aspect;
    if (height > size.height) {
      height = size.height;
      width = height * aspect;
    }
    rect = Rect.fromLTWH(
      (size.width - width) / 2,
      (size.height - height) / 2,
      width,
      height,
    );
  }

  final Size size;

  /// Where the campus actually sits inside [size].
  late final Rect rect;

  Offset offsetOf(double latitude, double longitude) => Offset(
        rect.left +
            (longitude - campusWest) /
                (campusEast - campusWest) *
                rect.width,
        rect.top +
            (campusNorth - latitude) /
                (campusNorth - campusSouth) *
                rect.height,
      );

  ({double lat, double lon}) latLonOf(Offset point) => (
        lat: campusNorth -
            (point.dy - rect.top) /
                rect.height *
                (campusNorth - campusSouth),
        lon: campusWest +
            (point.dx - rect.left) /
                rect.width *
                (campusEast - campusWest),
      );
}

/// The place under [at], or null when nothing is within [maxDistance].
///
/// A generous default because a dot is small and a finger is not: 20 logical
/// pixels is about the radius at which people expect a tap to count.
CampusPlace? nearestPlace(
  List<CampusPlace> places,
  CampusMapGeometry geometry,
  Offset at, {
  double maxDistance = 20,
}) {
  CampusPlace? best;
  var bestDistance = maxDistance;
  for (final place in places) {
    final distance =
        (geometry.offsetOf(place.latitude, place.longitude) - at).distance;
    if (distance <= bestDistance) {
      bestDistance = distance;
      best = place;
    }
  }
  return best;
}
