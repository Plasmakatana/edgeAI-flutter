import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:testapp/services/map_service.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('map_service_test');
    MapService.debugRootDirectory = root;
    MapService.instance.resetForTest();
  });

  tearDown(() async {
    MapService.instance.resetForTest();
    MapService.debugRootDirectory = null;
    MapService.debugHttpClient = null;
    try {
      await root.delete(recursive: true);
    } catch (_) {
      // Best effort on Windows.
    }
  });

  test('source ids are stable per tile template', () {
    final first = MapService.sourceIdFor(MapService.defaultTileUrl);
    final second = MapService.sourceIdFor(MapService.defaultTileUrl);
    final other = MapService.sourceIdFor('https://example.com/{z}/{x}/{y}.png');
    expect(first, second);
    expect(first, isNot(other));
    expect(first, hasLength(12));
  });

  test('initialize cleans expired tiles through the isolate', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final source = MapService.sourceIdFor(MapService.defaultTileUrl);
    final tile = File(p.join(root.path, 'tiles', source, '3', '1', '2.tile'));
    await tile.parent.create(recursive: true);
    await tile.writeAsString('expired');
    await File(p.join(root.path, 'tile_access.json')).writeAsString(
      jsonEncode({
        'version': 1,
        'tiles': {
          '$source/3/1/2': {'t': now - 15 * 24 * 60 * 60 * 1000},
        },
      }),
    );

    await MapService.instance.initialize();

    expect(await tile.exists(), isFalse);
    expect(MapService.instance.isLoaded, isTrue);
    expect(MapService.instance.cachedBytes, 0);
  });

  test('retries transient tile failures then caches the image', () async {
    var requests = 0;
    MapService.debugHttpClient = MockClient((request) async {
      requests++;
      if (requests == 1) {
        return http.Response('busy', 503);
      }
      return http.Response.bytes(
        const [137, 80, 78, 71, 13, 10, 26, 10],
        200,
        headers: {'content-type': 'image/png'},
      );
    });

    final bytes = await MapService.instance.fetchTile(
      z: 3,
      x: 1,
      y: 2,
      tileUrlTemplate: MapService.defaultTileUrl,
    );

    expect(requests, 2);
    expect(bytes, orderedEquals(const [137, 80, 78, 71, 13, 10, 26, 10]));
    final source = MapService.sourceIdFor(MapService.defaultTileUrl);
    final tile = File(p.join(root.path, 'tiles', source, '3', '1', '2.tile'));
    expect(await tile.exists(), isTrue);
  });

  test('rejects blocked tile responses without caching them', () async {
    MapService.debugHttpClient = MockClient((request) async {
      return http.Response.bytes(
        const [137, 80, 78, 71, 13, 10, 26, 10],
        200,
        headers: {
          'content-type': 'image/png',
          'x-blocked': 'Access blocked',
        },
      );
    });

    await expectLater(
      MapService.instance.fetchTile(
        z: 3,
        x: 1,
        y: 2,
        tileUrlTemplate: MapService.defaultTileUrl,
      ),
      throwsA(predicate((e) => e.toString().contains('blocked'))),
    );
    final source = MapService.sourceIdFor(MapService.defaultTileUrl);
    final tile = File(p.join(root.path, 'tiles', source, '3', '1', '2.tile'));
    expect(await tile.exists(), isFalse);
  });

  test('region JSON round-trips and keeps its tile source', () {
    final region = MapRegion(
      id: 'r1',
      name: 'Home',
      south: 1,
      west: 2,
      north: 3,
      east: 4,
      minZoom: 5,
      maxZoom: 7,
      createdAt: DateTime.utc(2026, 1, 2),
      tileUrlTemplate: 'https://example.com/{z}/{x}/{y}.png',
      downloadedAt: DateTime.utc(2026, 1, 3),
      tileCount: 42,
      bytes: 1234,
      failedTiles: 2,
      keepOffline: true,
    );

    final restored = MapRegion.fromJson(region.toJson());
    expect(restored.id, 'r1');
    expect(restored.name, 'Home');
    expect(restored.south, 1);
    expect(restored.east, 4);
    expect(restored.minZoom, 5);
    expect(restored.maxZoom, 7);
    expect(restored.tileUrlTemplate, region.tileUrlTemplate);
    expect(restored.tileCount, 42);
    expect(restored.failedTiles, 2);
    expect(restored.keepOffline, isTrue);
    expect(restored.isDownloaded, isTrue);
  });
}
