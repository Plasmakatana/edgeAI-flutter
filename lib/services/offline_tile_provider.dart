import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';

import 'map_service.dart';

/// [TileProvider] that reads tiles from [MapService]'s disk cache first and
/// downloads (then caches) them on a miss.
class OfflineTileProvider extends TileProvider {
  OfflineTileProvider({required this.tileUrlTemplate, super.headers});

  final String tileUrlTemplate;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return OfflineTileImage(
      z: coordinates.z,
      x: coordinates.x,
      y: coordinates.y,
      tileUrlTemplate: tileUrlTemplate,
    );
  }
}

/// Disk-cache-first tile image used by [OfflineTileProvider].
class OfflineTileImage extends ImageProvider<OfflineTileImage> {
  const OfflineTileImage({
    required this.z,
    required this.x,
    required this.y,
    required this.tileUrlTemplate,
  });

  final int z;
  final int x;
  final int y;
  final String tileUrlTemplate;

  @override
  Future<OfflineTileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<OfflineTileImage>(this);

  @override
  ImageStreamCompleter loadImage(
    OfflineTileImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: 1.0,
      debugLabel: 'offline-map-$z/$x/$y',
    );
  }

  Future<ui.Codec> _load(
    OfflineTileImage key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await MapService.instance.tileBytes(
      z: key.z,
      x: key.x,
      y: key.y,
      tileUrlTemplate: key.tileUrlTemplate,
    );
    if (bytes == null || bytes.isEmpty) {
      throw StateError(
        'Tile ${key.z}/${key.x}/${key.y} is not cached and '
        'could not be downloaded.',
      );
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is OfflineTileImage &&
      other.z == z &&
      other.x == x &&
      other.y == y &&
      other.tileUrlTemplate == tileUrlTemplate;

  @override
  int get hashCode => Object.hash(z, x, y, tileUrlTemplate);

  @override
  String toString() => 'OfflineTileImage($z/$x/$y)';
}
