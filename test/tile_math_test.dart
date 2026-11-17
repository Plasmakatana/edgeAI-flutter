import 'package:flutter_test/flutter_test.dart';
import 'package:testapp/services/tile_math.dart';

void main() {
  group('tile math', () {
    test('whole world is one tile at zoom 0', () {
      final range = tileRangeForBounds(
        south: -85.0511,
        west: -180,
        north: 85.0511,
        east: 180,
        zoom: 0,
      );
      expect(range.tileCount, 1);
      expect(range.minX, 0);
      expect(range.maxX, 0);
      expect(range.minY, 0);
      expect(range.maxY, 0);
    });

    test('center of the world maps to the middle tile', () {
      expect(tileXForLon(0, 1), 1);
      expect(tileYForLat(0, 1), 1);
      expect(tileXForLon(0, 2), 2);
      expect(tileYForLat(0, 2), 2);
    });

    test('antimeridian edges clamp to first and last tile', () {
      expect(tileXForLon(-180, 3), 0);
      expect(tileXForLon(180, 3), (1 << 3) - 1);
      expect(tileYForLat(90, 3), 0);
      expect(tileYForLat(-90, 3), (1 << 3) - 1);
    });

    test('tile centers round-trip through lon/lat', () {
      const zoom = 5;
      for (final x in [0, 7, 30]) {
        final lon = (lonForTileX(x, zoom) + lonForTileX(x + 1, zoom)) / 2;
        expect(tileXForLon(lon, zoom), x);
      }
      for (final y in [0, 7, 30]) {
        final lat = (latForTileY(y, zoom) + latForTileY(y + 1, zoom)) / 2;
        expect(tileYForLat(lat, zoom), y);
      }
    });

    test('range covers a small box and counts zoom levels', () {
      final range = tileRangeForBounds(
        south: 0,
        west: 0,
        north: 1,
        east: 1,
        zoom: 2,
      );
      expect(range.minX, 2);
      expect(range.maxX, 2);
      expect(range.minY, 1);
      expect(range.maxY, 2);
      expect(range.tileCount, 2);

      final total = tileCountForBounds(
        south: 0,
        west: 0,
        north: 1,
        east: 1,
        minZoom: 0,
        maxZoom: 2,
      );
      expect(total, 1 + 2 + 2);
    });

    test('range rejects inverted bounds', () {
      expect(
        () =>
            tileRangeForBounds(south: 10, west: 0, north: 0, east: 1, zoom: 2),
        throwsArgumentError,
      );
      expect(
        () =>
            tileRangeForBounds(south: 0, west: 10, north: 1, east: 0, zoom: 2),
        throwsArgumentError,
      );
    });

    test('parses cache keys safely', () {
      expect(tileCoordFromKey('5/10/12'), const TileCoord(5, 10, 12));
      expect(tileCoordFromKey('5/32/0'), isNull);
      expect(tileCoordFromKey('5/-1/0'), isNull);
      expect(tileCoordFromKey('bad'), isNull);
    });

    test('builds tile URLs and estimates sizes', () {
      expect(
        buildTileUrl('https://tiles/{z}/{x}/{y}.png', 3, 4, 5),
        'https://tiles/3/4/5.png',
      );
      expect(estimatedTileBytes(4), 4 * 15 * 1024);
    });
  });
}
