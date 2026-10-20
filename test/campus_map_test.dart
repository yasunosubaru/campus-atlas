import 'dart:ui';

import 'package:campus_atlas/features/campus_map/campus_data.dart';
import 'package:campus_atlas/features/campus_map/campus_map_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('campus data', () {
    test('every place lies inside the map box', () {
      for (final place in campusPlaces) {
        expect(
          place.latitude,
          inInclusiveRange(campusSouth, campusNorth),
          reason: place.name,
        );
        expect(
          place.longitude,
          inInclusiveRange(campusWest, campusEast),
          reason: place.name,
        );
      }
    });

    test('the fixture is a campus, not a handful of rows', () {
      expect(campusPlaces.length, greaterThan(200));
      for (final category in CampusCategory.values) {
        expect(
          campusPlaces.where((p) => p.category == category),
          isNotEmpty,
          reason: '$category has no entries',
        );
      }
    });

    test('names are unique within a category', () {
      final seen = <String>{};
      for (final place in campusPlaces) {
        final key = '${place.category.name}|${place.name}';
        expect(seen.add(key), isTrue, reason: 'duplicate ${place.name}');
      }
    });

    test('landmarks from the live campus are present', () {
      final names = campusPlaces.map((p) => p.name).toSet();
      expect(
        names,
        containsAll(<String>[
          '武汉大学图书馆',
          '工学部图书馆',
          '老图书馆',
          '梅园食堂',
          '桂园食堂',
        ]),
      );
    });

    test('every entry keeps an OSM id and a usable URL', () {
      for (final place in campusPlaces) {
        expect(place.osmId, matches(RegExp(r'^(node|way|relation)/\d+$')));
        expect(place.osmUrl, startsWith('https://www.openstreetmap.org/'));
      }
    });
  });

  group('CampusMapGeometry', () {
    test('a nearly square box is height-limited and centred', () {
      final geometry = CampusMapGeometry(const Size(400, 400));
      expect(geometry.rect.height, closeTo(400, 0.001));
      expect(geometry.rect.width, lessThan(400));
      expect(geometry.rect.center.dx, closeTo(200, 0.001));
      expect(geometry.rect.top, closeTo(0, 0.001));
    });

    test('a wide box is height-limited and centred horizontally', () {
      final geometry = CampusMapGeometry(const Size(1000, 300));
      expect(geometry.rect.height, closeTo(300, 0.001));
      expect(geometry.rect.width, lessThan(300));
      expect(geometry.rect.center.dx, closeTo(500, 0.001));
    });

    test('a tall box is width-limited and centred vertically', () {
      final geometry = CampusMapGeometry(const Size(300, 1000));
      expect(geometry.rect.width, closeTo(300, 0.001));
      expect(geometry.rect.height, greaterThan(300));
      expect(geometry.rect.center.dy, closeTo(500, 0.001));
    });

    test('the corners of the box map to the corners of the rectangle', () {
      final geometry = CampusMapGeometry(const Size(400, 400));
      expect(geometry.offsetOf(campusNorth, campusWest).dx,
          closeTo(geometry.rect.left, 0.001));
      expect(geometry.offsetOf(campusNorth, campusWest).dy,
          closeTo(geometry.rect.top, 0.001));
      expect(geometry.offsetOf(campusSouth, campusEast).dx,
          closeTo(geometry.rect.right, 0.001));
      expect(geometry.offsetOf(campusSouth, campusEast).dy,
          closeTo(geometry.rect.bottom, 0.001));
    });

    test('a point survives projection and back', () {
      final geometry = CampusMapGeometry(const Size(360, 640));
      const lat = 30.5376;
      const lon = 114.3575;
      final back = geometry.latLonOf(geometry.offsetOf(lat, lon));
      expect(back.lat, closeTo(lat, 1e-9));
      expect(back.lon, closeTo(lon, 1e-9));
    });

    test('north is up: a higher latitude has a smaller y', () {
      final geometry = CampusMapGeometry(const Size(400, 400));
      final north = geometry.offsetOf(30.545, 114.36);
      final south = geometry.offsetOf(30.535, 114.36);
      expect(north.dy, lessThan(south.dy));
    });
  });

  group('nearestPlace', () {
    const a = CampusPlace(
      name: 'A',
      latitude: 30.5400,
      longitude: 114.3600,
      category: CampusCategory.teaching,
    );
    const b = CampusPlace(
      name: 'B',
      latitude: 30.5350,
      longitude: 114.3550,
      category: CampusCategory.library,
    );
    const places = [a, b];

    test('a tap on a dot returns that place', () {
      final geometry = CampusMapGeometry(const Size(400, 400));
      final hit = nearestPlace(
        places,
        geometry,
        geometry.offsetOf(a.latitude, a.longitude),
      );
      expect(hit?.name, 'A');
    });

    test('a tap far from every dot returns null', () {
      final geometry = CampusMapGeometry(const Size(400, 400));
      final hit = nearestPlace(
        places,
        geometry,
        geometry.rect.topLeft + const Offset(2, 2),
      );
      expect(hit, isNull);
    });

    test('the closer of two nearby dots wins', () {
      final geometry = CampusMapGeometry(const Size(400, 400));
      final nearB = geometry.offsetOf(b.latitude, b.longitude) +
          const Offset(4, 0);
      expect(nearestPlace(places, geometry, nearB)?.name, 'B');
    });
  });
}
