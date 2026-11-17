import 'dart:math' as math;

/// Web-Mercator (slippy map) math shared by the map viewer, region downloads
/// and cache cleanup. Zoom levels are integral; tile x/y are clamped to the
/// valid range for that zoom.
class TileCoord {
  const TileCoord(this.z, this.x, this.y);

  final int z;
  final int x;
  final int y;

  String get key => tileKey(z, x, y);

  @override
  bool operator ==(Object other) =>
      other is TileCoord && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);

  @override
  String toString() => 'TileCoord($z/$x/$y)';
}

/// Inclusive rectangle of tile indices at one zoom level.
class TileRange {
  const TileRange({
    required this.zoom,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });

  final int zoom;
  final int minX;
  final int maxX;
  final int minY;
  final int maxY;

  int get width => maxX - minX + 1;
  int get height => maxY - minY + 1;
  int get tileCount => width * height;

  Iterable<TileCoord> get tiles sync* {
    for (var x = minX; x <= maxX; x++) {
      for (var y = minY; y <= maxY; y++) {
        yield TileCoord(zoom, x, y);
      }
    }
  }
}

const double mercatorMaxLatitude = 85.0511287798066;

String tileKey(int z, int x, int y) => '$z/$x/$y';

/// Parses a `z/x/y` cache key, returning null when malformed.
TileCoord? tileCoordFromKey(String key) {
  final parts = key.split('/');
  if (parts.length != 3) return null;
  final z = int.tryParse(parts[0]);
  final x = int.tryParse(parts[1]);
  final y = int.tryParse(parts[2]);
  if (z == null || x == null || y == null || z < 0) return null;
  final limit = 1 << z;
  if (x < 0 || y < 0 || x >= limit || y >= limit) return null;
  return TileCoord(z, x, y);
}

double _clampLatitude(double latitude) =>
    latitude.clamp(-mercatorMaxLatitude, mercatorMaxLatitude).toDouble();

int tileXForLon(double lon, int zoom) {
  final n = 1 << zoom;
  return (((lon + 180) / 360) * n).floor().clamp(0, n - 1);
}

int tileYForLat(double lat, int zoom) {
  final n = 1 << zoom;
  final clamped = _clampLatitude(lat);
  final radians = clamped * math.pi / 180;
  final value =
      (1 - math.log(math.tan(radians) + 1 / math.cos(radians)) / math.pi) / 2;
  return (value * n).floor().clamp(0, n - 1);
}

double lonForTileX(int x, int zoom) {
  final n = 1 << zoom;
  return x / n * 360 - 180;
}

double latForTileY(int y, int zoom) {
  final n = 1 << zoom;
  final value = math.pi * (1 - 2 * y / n);
  // dart:math has no sinh; compute it directly.
  final sinh = (math.exp(value) - math.exp(-value)) / 2;
  final radians = math.atan(sinh);
  return radians * 180 / math.pi;
}

/// Tile rectangle covering [south]-[north] / [west]-[east] at [zoom].
///
/// Bounds crossing the antimeridian (west > east) are not supported; callers
/// should split them first.
TileRange tileRangeForBounds({
  required double south,
  required double west,
  required double north,
  required double east,
  required int zoom,
}) {
  if (zoom < 0 || zoom > 30) {
    throw ArgumentError.value(zoom, 'zoom', 'must be between 0 and 30');
  }
  if (west > east) {
    throw ArgumentError('west ($west) must be <= east ($east)');
  }
  if (south > north) {
    throw ArgumentError('south ($south) must be <= north ($north)');
  }
  final minX = tileXForLon(west, zoom);
  final maxX = tileXForLon(east, zoom);
  final minY = tileYForLat(north, zoom);
  final maxY = tileYForLat(south, zoom);
  return TileRange(zoom: zoom, minX: minX, maxX: maxX, minY: minY, maxY: maxY);
}

/// Number of tiles needed to cover the bounds across an inclusive zoom range.
int tileCountForBounds({
  required double south,
  required double west,
  required double north,
  required double east,
  required int minZoom,
  required int maxZoom,
}) {
  var total = 0;
  for (var z = minZoom; z <= maxZoom; z++) {
    total += tileRangeForBounds(
      south: south,
      west: west,
      north: north,
      east: east,
      zoom: z,
    ).tileCount;
  }
  return total;
}

/// Approximate on-disk size of [tiles] raster tiles (~15 KB each).
int estimatedTileBytes(int tiles) => tiles * 15 * 1024;

/// Replaces `{z}`, `{x}` and `{y}` in a tile URL template.
String buildTileUrl(String template, int z, int x, int y) => template
    .replaceAll('{z}', '$z')
    .replaceAll('{x}', '$x')
    .replaceAll('{y}', '$y');
