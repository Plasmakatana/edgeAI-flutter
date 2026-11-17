import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'tile_math.dart';

/// A map area the user chose to store for offline use.
class MapRegion {
  MapRegion({
    required this.id,
    required this.name,
    required this.south,
    required this.west,
    required this.north,
    required this.east,
    required this.minZoom,
    required this.maxZoom,
    required this.createdAt,
    required this.tileUrlTemplate,
    this.downloadedAt,
    this.tileCount = 0,
    this.bytes = 0,
    this.failedTiles = 0,
    this.keepOffline = false,
  });

  final String id;
  final String name;
  final double south;
  final double west;
  final double north;
  final double east;
  final int minZoom;
  final int maxZoom;
  final DateTime createdAt;
  String tileUrlTemplate;

  DateTime? downloadedAt;
  int tileCount;
  int bytes;
  int failedTiles;
  bool keepOffline;

  bool get isDownloaded => downloadedAt != null;

  String get sizeLabel => formatBytes(bytes);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'south': south,
    'west': west,
    'north': north,
    'east': east,
    'minZoom': minZoom,
    'maxZoom': maxZoom,
    'createdAt': createdAt.toIso8601String(),
    'tileUrlTemplate': tileUrlTemplate,
    if (downloadedAt != null) 'downloadedAt': downloadedAt!.toIso8601String(),
    'tileCount': tileCount,
    'bytes': bytes,
    'failedTiles': failedTiles,
    'keepOffline': keepOffline,
  };

  factory MapRegion.fromJson(Map<String, dynamic> json) => MapRegion(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'Map region',
    south: (json['south'] as num).toDouble(),
    west: (json['west'] as num).toDouble(),
    north: (json['north'] as num).toDouble(),
    east: (json['east'] as num).toDouble(),
    minZoom: (json['minZoom'] as num?)?.toInt() ?? 0,
    maxZoom: (json['maxZoom'] as num?)?.toInt() ?? 0,
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    tileUrlTemplate:
        json['tileUrlTemplate'] as String? ?? MapService.defaultTileUrl,
    downloadedAt: DateTime.tryParse(json['downloadedAt'] as String? ?? ''),
    tileCount: (json['tileCount'] as num?)?.toInt() ?? 0,
    bytes: (json['bytes'] as num?)?.toInt() ?? 0,
    failedTiles: (json['failedTiles'] as num?)?.toInt() ?? 0,
    keepOffline: json['keepOffline'] as bool? ?? false,
  );
}

class TileAccess {
  TileAccess({required this.lastAccessMs, Set<String>? regionIds})
    : regionIds = regionIds ?? <String>{};

  int lastAccessMs;
  final Set<String> regionIds;
}

class MapCleanupResult {
  const MapCleanupResult({
    required this.deletedTiles,
    required this.freedBytes,
    required this.totalBytes,
    required this.remainingTiles,
  });

  final int deletedTiles;
  final int freedBytes;
  final int totalBytes;
  final int remainingTiles;

  static const empty = MapCleanupResult(
    deletedTiles: 0,
    freedBytes: 0,
    totalBytes: 0,
    remainingTiles: 0,
  );
}

String formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes bytes';
}

/// Disk-backed tile cache with TTL + LRU size-cap cleanup.
///
/// Layout:
/// ```
/// <appSupport>/map_cache/
///   regions.json
///   tile_access.json
///   tiles/<sourceId>/<z>/<x>/<y>.tile
/// ```
///
/// Transient tiles (viewed while online) expire after 14 days; tiles belonging
/// to a downloaded region expire after 180 days. Pinned regions are exempt
/// from TTL/eviction. The total cache is capped at 1 GB and evicted down to
/// ~800 MB, oldest access first, skipping anything touched in the last hour.
class MapService {
  MapService._();
  static final MapService instance = MapService._();

  static const Duration tileTimeout = Duration(seconds: 20);
  static const Duration regionTileDelay = Duration(milliseconds: 80);
  static const int transientTtlMs = 14 * 24 * 60 * 60 * 1000;
  static const int regionTtlMs = 180 * 24 * 60 * 60 * 1000;
  static const int maxCacheBytes = 1024 * 1024 * 1024;
  static const int targetCacheBytes = 800 * 1024 * 1024;
  static const int graceMs = 60 * 60 * 1000;
  static const int maxTilesPerRegion = 20000;
  static const int accessTouchIntervalMs = 5 * 60 * 1000;
  static const String defaultTileUrl =
      'https://tile.openstreetmap.de/{z}/{x}/{y}.png';
  static const String legacyOsmTileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String userAgent =
      'GemmaOfflineAssistant/1.0 '
      '(+https://github.com/Plasmakatana/edgeAI-flutter)';

  /// Overrides the cache root in tests.
  @visibleForTesting
  static Directory? debugRootDirectory;

  /// Overrides the HTTP client in tests.
  @visibleForTesting
  static http.Client? debugHttpClient;

  Directory? _root;
  http.Client? _client;
  Future<void>? _initializing;
  bool _loaded = false;

  final List<MapRegion> _regions = [];
  final Map<String, TileAccess> _access = {};
  int _cachedBytes = 0;
  int _writesSinceCapCheck = 0;

  Timer? _flushTimer;
  bool _accessDirty = false;

  List<MapRegion> get regions => List.unmodifiable(_regions);
  int get cachedBytes => _cachedBytes;
  bool get isLoaded => _loaded;

  MapRegion? regionById(String id) {
    for (final r in _regions) {
      if (r.id == id) return r;
    }
    return null;
  }

  static String sourceIdFor(String tileUrlTemplate) =>
      sha1.convert(utf8.encode(tileUrlTemplate)).toString().substring(0, 12);

  Future<void> initialize() {
    final inFlight = _initializing;
    if (inFlight != null) return inFlight;
    final future = _initialize();
    _initializing = future;
    future.then(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_initializing, future)) {
          _initializing = null;
        }
      },
    );
    return future;
  }

  Future<void> _initialize() async {
    final base =
        debugRootDirectory ??
        Directory(
          p.join((await getApplicationSupportDirectory()).path, 'map_cache'),
        );
    _root = base;
    await Directory(p.join(base.path, 'tiles')).create(recursive: true);
    await _loadState();
    _client = debugHttpClient ?? http.Client();
    await _runCleanup();
  }

  Future<File> _regionsFile() async =>
      File(p.join(_root!.path, 'regions.json'));

  Future<File> _accessFile() async =>
      File(p.join(_root!.path, 'tile_access.json'));

  File _tileFile(String sourceId, int z, int x, int y) =>
      File(p.join(_root!.path, 'tiles', sourceId, '$z', '$x', '$y.tile'));

  Future<void> _loadState() async {
    if (_loaded) return;
    _loaded = true;
    _regions.clear();
    _access.clear();

    try {
      final file = await _regionsFile();
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        final list = (raw as Map<String, dynamic>)['regions'] as List? ?? [];
        for (final item in list) {
          if (item is Map<String, dynamic>) {
            _regions.add(MapRegion.fromJson(item));
          }
        }
      }
    } catch (_) {
      _regions.clear();
    }

    await _loadAccessFromDisk();
  }

  Future<void> _loadAccessFromDisk() async {
    _access.clear();
    try {
      final file = await _accessFile();
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        final tiles = (raw as Map<String, dynamic>)['tiles'];
        if (tiles is Map<String, dynamic>) {
          tiles.forEach((key, value) {
            if (value is Map<String, dynamic>) {
              _access[key] = TileAccess(
                lastAccessMs: (value['t'] as num?)?.toInt() ?? 0,
                regionIds: {
                  for (final id in (value['r'] as List? ?? const []))
                    if (id is String) id,
                },
              );
            }
          });
        }
      }
    } catch (_) {
      _access.clear();
    }
  }

  Future<void> _saveRegions() async {
    if (_root == null) return;
    final file = await _regionsFile();
    final payload = jsonEncode({
      'version': 1,
      'regions': [for (final r in _regions) r.toJson()],
    });
    await _atomicWrite(file, payload);
  }

  Future<void> _atomicWrite(File file, String payload) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(file.path);
  }

  Future<void> _flushAccessNow() async {
    if (_root == null || !_accessDirty) return;
    _accessDirty = false;
    _flushTimer?.cancel();
    _flushTimer = null;
    final file = await _accessFile();
    final payload = jsonEncode({
      'version': 1,
      'tiles': {
        for (final entry in _access.entries)
          entry.key: {
            't': entry.value.lastAccessMs,
            if (entry.value.regionIds.isNotEmpty)
              'r': entry.value.regionIds.toList(),
          },
      },
    });
    try {
      await _atomicWrite(file, payload);
    } catch (_) {
      _accessDirty = true;
      rethrow;
    }
  }

  void _markAccessed(String key, {String? regionId}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final entry = _access.putIfAbsent(key, () => TileAccess(lastAccessMs: now));
    entry.lastAccessMs = now;
    if (regionId != null) entry.regionIds.add(regionId);
    _accessDirty = true;
    _flushTimer ??= Timer(const Duration(seconds: 2), () {
      _flushTimer = null;
      unawaited(_flushAccessSafely());
    });
  }

  Future<void> _flushAccessSafely() async {
    try {
      await _flushAccessNow();
    } catch (e) {
      debugPrint('Map tile access flush failed: $e');
    }
  }

  void _touchIfStale(String key) {
    final entry = _access[key];
    final now = DateTime.now().millisecondsSinceEpoch;
    if (entry == null || now - entry.lastAccessMs > accessTouchIntervalMs) {
      _markAccessed(key);
    }
  }

  /// Returns cached bytes for a tile, or null on a cache miss.
  Future<Uint8List?> cachedTile({
    required int z,
    required int x,
    required int y,
    required String tileUrlTemplate,
  }) async {
    await initialize();
    final sourceId = sourceIdFor(tileUrlTemplate);
    final file = _tileFile(sourceId, z, x, y);
    try {
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      _touchIfStale('$sourceId/${tileKey(z, x, y)}');
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<http.Response> _requestTile(Uri uri) async {
    final client = _client ??= http.Client();
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      http.Response? response;
      try {
        response = await client
            .get(
              uri,
              headers: const {
                'User-Agent': userAgent,
                'Accept': 'image/png,image/jpeg,image/*',
              },
            )
            .timeout(tileTimeout);
      } catch (e) {
        lastError = e;
      }
      if (response != null) {
        if (response.statusCode == 200) return response;
        final retryable =
            response.statusCode == 429 || response.statusCode >= 500;
        if (!retryable) {
          throw Exception(
            'Tile request failed: HTTP ${response.statusCode} for $uri',
          );
        }
        lastError = 'HTTP ${response.statusCode}';
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    throw Exception('Tile request failed after retries: $lastError');
  }

  /// Downloads and caches one tile. Throws on network/HTTP failure.
  Future<Uint8List> fetchTile({
    required int z,
    required int x,
    required int y,
    required String tileUrlTemplate,
    String? regionId,
  }) async {
    await initialize();
    final uri = Uri.parse(buildTileUrl(tileUrlTemplate, z, x, y));
    final response = await _requestTile(uri);
    final contentType = response.headers['content-type'] ?? '';
    if (contentType.isNotEmpty && !contentType.startsWith('image/')) {
      throw Exception(
        'Tile request returned "$contentType" instead of an image: $uri',
      );
    }
    // OpenStreetMap's tile CDN answers blocked clients with HTTP 200 and an
    // "Access blocked" PNG plus this header; never cache that as a tile.
    final blocked = response.headers['x-blocked'];
    if (blocked != null && blocked.isNotEmpty) {
      throw Exception('Tile source blocked the request ($blocked): $uri');
    }
    final bytes = response.bodyBytes;
    if (bytes.isEmpty) {
      throw Exception('Tile request returned an empty body.');
    }

    final sourceId = sourceIdFor(tileUrlTemplate);
    final file = _tileFile(sourceId, z, x, y);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(file.path);

    _cachedBytes += bytes.length;
    _markAccessed('$sourceId/${tileKey(z, x, y)}', regionId: regionId);

    _writesSinceCapCheck++;
    if (_writesSinceCapCheck >= 300 && _cachedBytes > maxCacheBytes) {
      _writesSinceCapCheck = 0;
      unawaited(_safeCleanup());
    }
    return bytes;
  }

  /// Cache-first tile loader used by the map's image provider.
  Future<Uint8List?> tileBytes({
    required int z,
    required int x,
    required int y,
    required String tileUrlTemplate,
  }) async {
    final cached = await cachedTile(
      z: z,
      x: x,
      y: y,
      tileUrlTemplate: tileUrlTemplate,
    );
    if (cached != null) return cached;
    try {
      return await fetchTile(
        z: z,
        x: x,
        y: y,
        tileUrlTemplate: tileUrlTemplate,
      );
    } catch (e) {
      debugPrint('Map tile $z/$x/$y failed: $e');
      return null;
    }
  }

  /// Downloads every missing tile in [region] at its configured zoom range.
  ///
  /// [tileUrlTemplate] selects the tile source (stored on the region so later
  /// deletion works even if the user changes the source).
  Future<MapRegion> downloadRegion(
    MapRegion region, {
    required String tileUrlTemplate,
    void Function(int done, int total, int failed)? onProgress,
  }) async {
    await initialize();
    final coords = <TileCoord>[];
    for (var z = region.minZoom; z <= region.maxZoom; z++) {
      coords.addAll(
        tileRangeForBounds(
          south: region.south,
          west: region.west,
          north: region.north,
          east: region.east,
          zoom: z,
        ).tiles,
      );
    }
    final total = coords.length;
    if (total == 0) {
      throw Exception('This area contains no tiles at the selected zooms.');
    }
    if (total > maxTilesPerRegion) {
      throw Exception(
        'Region is too large ($total tiles; limit $maxTilesPerRegion). '
        'Zoom out less or choose a smaller area.',
      );
    }

    final sourceId = sourceIdFor(tileUrlTemplate);
    final iterator = coords.iterator;
    var done = 0;
    var failed = 0;
    var storedBytes = 0;
    var abort = false;
    Object? firstError;

    void report() {
      onProgress?.call(done, total, failed);
    }

    Future<void> worker() async {
      while (!abort) {
        if (!iterator.moveNext()) return;
        final coord = iterator.current;
        final file = _tileFile(sourceId, coord.z, coord.x, coord.y);
        try {
          if (await file.exists()) {
            storedBytes += await file.length();
            _markAccessed('$sourceId/${coord.key}', regionId: region.id);
          } else {
            final bytes = await fetchTile(
              z: coord.z,
              x: coord.x,
              y: coord.y,
              tileUrlTemplate: tileUrlTemplate,
              regionId: region.id,
            );
            storedBytes += bytes.length;
          }
        } catch (e) {
          failed++;
          firstError ??= e;
          if (e.toString().contains('429')) abort = true;
        }
        done++;
        if (done % 5 == 0 || done == total) report();
        if (!abort && regionTileDelay > Duration.zero) {
          await Future<void>.delayed(regionTileDelay);
        }
      }
    }

    await Future.wait([worker(), worker()]);
    report();

    if (done - failed == 0) {
      throw Exception(
        'Could not download any tiles. Check your connection. '
        '${firstError ?? ''}',
      );
    }

    region
      ..downloadedAt = DateTime.now()
      ..tileCount = done - failed
      ..bytes = storedBytes
      ..failedTiles = failed
      ..tileUrlTemplate = tileUrlTemplate;
    final existing = _regions.indexWhere((r) => r.id == region.id);
    if (existing >= 0) {
      _regions[existing] = region;
    } else {
      _regions.add(region);
    }
    await _saveRegions();
    await _flushAccessNow();
    unawaited(_safeCleanup());
    return region;
  }

  Future<void> setRegionKeepOffline(MapRegion region, bool keep) async {
    await initialize();
    region.keepOffline = keep;
    await _saveRegions();
    if (!keep) {
      unawaited(_safeCleanup());
    }
  }

  Future<void> deleteRegion(MapRegion region) async {
    await initialize();
    _regions.removeWhere((r) => r.id == region.id);

    final keysToDelete = <String>[];
    _access.forEach((key, entry) {
      if (entry.regionIds.remove(region.id) && entry.regionIds.isEmpty) {
        keysToDelete.add(key);
      }
    });
    for (final key in keysToDelete) {
      _access.remove(key);
      final file = _tileFileFromKey(key);
      try {
        if (await file.exists()) {
          final length = await file.length();
          await file.delete();
          _cachedBytes -= length;
        }
      } catch (_) {
        // Best effort; cleanup will remove leftovers.
      }
    }
    if (_cachedBytes < 0) _cachedBytes = 0;
    await _saveRegions();
    await _flushAccessNow();
  }

  File _tileFileFromKey(String key) =>
      File(p.join(_root!.path, 'tiles', '$key.tile'));

  /// Removes all cached tiles and region records.
  Future<void> clearCache() async {
    await initialize();
    try {
      final tiles = Directory(p.join(_root!.path, 'tiles'));
      if (await tiles.exists()) {
        await tiles.delete(recursive: true);
      }
      await tiles.create(recursive: true);
    } catch (_) {
      // The cleanup pass below still clears the metadata.
    }
    _regions.clear();
    _access.clear();
    _cachedBytes = 0;
    _accessDirty = true;
    await _saveRegions();
    await _flushAccessNow();
  }

  Future<void> _safeCleanup() async {
    try {
      await cleanup();
    } catch (e) {
      debugPrint('Map cache cleanup failed: $e');
    }
  }

  /// Runs TTL + size-cap cleanup. Uses a background isolate for file scanning.
  Future<MapCleanupResult> cleanup() async {
    if (_root == null) {
      await initialize();
      return MapCleanupResult.empty;
    }
    return _runCleanup();
  }

  Future<MapCleanupResult> _runCleanup() async {
    final root = _root;
    if (root == null) return MapCleanupResult.empty;

    await _flushAccessNow();
    final rootPath = root.path;
    final pinned = [
      for (final region in _regions)
        if (region.keepOffline) region.id,
    ];
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final rawResult = await Isolate.run(
      () => runMapCacheCleanup({
        'root': rootPath,
        'now': startedAt,
        'pinnedRegionIds': pinned,
        'transientTtlMs': transientTtlMs,
        'regionTtlMs': regionTtlMs,
        'maxBytes': maxCacheBytes,
        'targetBytes': targetCacheBytes,
        'graceMs': graceMs,
      }),
    );
    final result = MapCleanupResult(
      deletedTiles: rawResult['deletedTiles'] ?? 0,
      freedBytes: rawResult['freedBytes'] ?? 0,
      totalBytes: rawResult['totalBytes'] ?? 0,
      remainingTiles: rawResult['remainingTiles'] ?? 0,
    );

    // Preserve access timestamps recorded while the isolate was scanning.
    final touchedDuringCleanup = <String, TileAccess>{
      for (final entry in _access.entries)
        if (entry.value.lastAccessMs >= startedAt)
          entry.key: TileAccess(
            lastAccessMs: entry.value.lastAccessMs,
            regionIds: {...entry.value.regionIds},
          ),
    };
    await _loadAccessFromDisk();
    for (final entry in touchedDuringCleanup.entries) {
      final existing = _access[entry.key];
      if (existing == null ||
          existing.lastAccessMs < entry.value.lastAccessMs) {
        _access[entry.key] = entry.value;
        _accessDirty = true;
      }
    }
    _cachedBytes = result.totalBytes;
    await _flushAccessNow();
    return result;
  }

  /// Flushes pending access timestamps (called on app pause).
  Future<void> flush() => _flushAccessNow();

  void dispose() {
    _flushTimer?.cancel();
    _client?.close();
  }

  @visibleForTesting
  void resetForTest() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _client?.close();
    _client = null;
    _root = null;
    _initializing = null;
    _loaded = false;
    _regions.clear();
    _access.clear();
    _cachedBytes = 0;
    _writesSinceCapCheck = 0;
    _accessDirty = false;
  }
}

/// Synchronous cleanup worker executed inside `Isolate.run`.
///
/// Reads/writes `<root>/tile_access.json`, deletes expired or over-cap tiles,
/// and returns aggregate stats. Kept free of Flutter/singleton state so it can
/// run off the UI isolate.
Map<String, int> runMapCacheCleanup(Map<String, Object?> args) {
  final root = args['root'] as String;
  final now = args['now'] as int;
  final pinned = {
    for (final id in (args['pinnedRegionIds'] as List? ?? const []))
      if (id is String) id,
  };
  final transientTtlMs = args['transientTtlMs'] as int;
  final regionTtlMs = args['regionTtlMs'] as int;
  final maxBytes = args['maxBytes'] as int;
  final targetBytes = args['targetBytes'] as int;
  final graceMs = args['graceMs'] as int;

  final tilesDir = Directory(p.join(root, 'tiles'));
  final accessFile = File(p.join(root, 'tile_access.json'));
  if (!tilesDir.existsSync()) {
    return {
      'deletedTiles': 0,
      'freedBytes': 0,
      'totalBytes': 0,
      'remainingTiles': 0,
    };
  }

  final access = <String, ({int lastAccess, List<String> regions})>{};
  try {
    if (accessFile.existsSync()) {
      final raw = jsonDecode(accessFile.readAsStringSync());
      final tiles = (raw as Map<String, dynamic>)['tiles'];
      if (tiles is Map<String, dynamic>) {
        tiles.forEach((key, value) {
          if (value is Map<String, dynamic>) {
            access[key] = (
              lastAccess: (value['t'] as num?)?.toInt() ?? 0,
              regions: [
                for (final id in (value['r'] as List? ?? const []))
                  if (id is String) id,
              ],
            );
          }
        });
      }
    }
  } catch (_) {
    access.clear();
  }

  final survivors = <String, ({int lastAccess, List<String> regions})>{};
  var deleted = 0;
  var freed = 0;
  var total = 0;

  void deleteFile(File file) {
    try {
      final size = file.lengthSync();
      file.deleteSync();
      deleted++;
      freed += size;
      total -= size;
    } catch (_) {
      // Best effort.
    }
  }

  for (final entity in tilesDir.listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative = p.relative(entity.path, from: tilesDir.path);
    final parts = relative.split(RegExp(r'[\\/]'));
    if (parts.length != 4) continue;
    final key =
        '${parts[0]}/${parts[1]}/${parts[2]}/${p.basenameWithoutExtension(parts[3])}';
    final entry = access[key];
    final lastAccess =
        entry?.lastAccess ?? entity.statSync().modified.millisecondsSinceEpoch;
    final regions = entry?.regions ?? const <String>[];
    final isPinned = regions.any(pinned.contains);
    final ttl = regions.isEmpty ? transientTtlMs : regionTtlMs;
    final size = entity.statSync().size;
    total += size;

    final expired = now - lastAccess > ttl;
    final withinGrace = now - lastAccess < graceMs;
    if (isPinned || !expired || withinGrace) {
      survivors[key] = (lastAccess: lastAccess, regions: regions);
      continue;
    }
    deleteFile(entity);
    access.remove(key);
  }

  if (total > maxBytes) {
    final candidates = survivors.entries.toList()
      ..sort((a, b) => a.value.lastAccess.compareTo(b.value.lastAccess));
    for (final candidate in candidates) {
      if (total <= targetBytes) break;
      final regions = candidate.value.regions;
      if (regions.any(pinned.contains)) continue;
      if (now - candidate.value.lastAccess < graceMs) continue;
      final file = File(p.join(tilesDir.path, '${candidate.key}.tile'));
      if (file.existsSync()) {
        deleteFile(file);
        survivors.remove(candidate.key);
        access.remove(candidate.key);
      }
    }
  }

  final payload = jsonEncode({
    'version': 1,
    'tiles': {
      for (final entry in survivors.entries)
        entry.key: {
          't': entry.value.lastAccess,
          if (entry.value.regions.isNotEmpty) 'r': entry.value.regions,
        },
    },
  });
  try {
    final tmp = File('${accessFile.path}.tmp');
    tmp.writeAsStringSync(payload, flush: true);
    if (accessFile.existsSync()) accessFile.deleteSync();
    tmp.renameSync(accessFile.path);
  } catch (_) {
    // Keep going: the next cleanup retries.
  }

  return {
    'deletedTiles': deleted,
    'freedBytes': freed,
    'totalBytes': total < 0 ? 0 : total,
    'remainingTiles': survivors.length,
  };
}
