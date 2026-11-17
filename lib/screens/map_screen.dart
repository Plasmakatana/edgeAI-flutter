import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/map_service.dart';
import '../services/offline_tile_provider.dart';
import '../services/settings_service.dart';
import '../services/tile_math.dart';
import '../widgets/task_progress_dialog.dart';

/// Offline-capable map viewer with region downloads.
///
/// Tiles are cached to disk as they are viewed (and expire after 14 days of no
/// access). Downloaded regions keep their tiles for 180 days unless pinned.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  final MapController _mapController = MapController();
  bool _mapReady = false;
  bool _initializing = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await MapService.instance.initialize();
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = '$e';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_cleanupOnResume());
    } else if (state == AppLifecycleState.paused) {
      unawaited(MapService.instance.flush());
    }
  }

  Future<void> _cleanupOnResume() async {
    try {
      await MapService.instance.initialize();
      await MapService.instance.cleanup();
    } catch (e) {
      debugPrint('Map cleanup on resume failed: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mapController.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _downloadCurrentView() async {
    if (!_mapReady) return;
    final camera = _mapController.camera;
    final bounds = camera.visibleBounds;
    if (bounds.west > bounds.east) {
      _snack('This view crosses the antimeridian; pan east or west first.');
      return;
    }
    final initialMin = camera.zoom.floor().clamp(2, 17);
    final initialMax = (initialMin + 3).clamp(initialMin, 17);

    final request = await showDialog<_RegionRequest>(
      context: context,
      builder: (_) => _RegionDownloadDialog(
        bounds: bounds,
        initialMinZoom: initialMin,
        initialMaxZoom: initialMax,
      ),
    );
    if (request == null || !mounted) return;

    final template = SettingsService.instance.mapTileUrl.value;
    final region = MapRegion(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: request.name,
      south: bounds.south,
      west: bounds.west,
      north: bounds.north,
      east: bounds.east,
      minZoom: request.minZoom,
      maxZoom: request.maxZoom,
      createdAt: DateTime.now(),
      tileUrlTemplate: template,
      keepOffline: request.keepOffline,
    );

    try {
      await runWithProgressDialog(
        context,
        title: 'Downloading "${region.name}"',
        task: (report) => MapService.instance.downloadRegion(
          region,
          tileUrlTemplate: template,
          onProgress: (done, total, failed) {
            final suffix = failed > 0 ? ' — $failed failed' : '';
            report(
              'Tile $done of $total$suffix',
              total == 0 ? null : done / total,
            );
          },
        ),
      );
      if (!mounted) return;
      setState(() {});
      _snack(
        region.failedTiles > 0
            ? 'Saved "${region.name}" (${region.tileCount} tiles, '
                  '${region.failedTiles} failed). Re-download to retry.'
            : 'Saved "${region.name}" for offline use '
                  '(${region.tileCount} tiles, ${region.sizeLabel}).',
      );
    } catch (e) {
      _snack('Region download failed: $e');
    }
  }

  Future<void> _showRegions() async {
    await MapService.instance.initialize();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final service = MapService.instance;
            final regions = service.regions;
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.68,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Downloaded regions',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              final confirmed = await _confirmClearCache();
                              if (confirmed != true) return;
                              await service.clearCache();
                              setSheetState(() {});
                              if (mounted) setState(() {});
                            },
                            child: const Text('Clear cache'),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        '${regions.length} regions · '
                        '${formatBytes(service.cachedBytes)} cached tiles. '
                        'Unpinned tiles auto-delete after 14 days (regions '
                        'after 180 days).',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: regions.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: Text(
                                  'No downloaded regions yet. Tap '
                                  '"Download this area" on the map to save '
                                  'the current view for offline use.',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: regions.length,
                              itemBuilder: (context, index) {
                                final region = regions[index];
                                return ListTile(
                                  leading: Icon(
                                    region.keepOffline
                                        ? Icons.push_pin
                                        : Icons.map_outlined,
                                  ),
                                  title: Text(region.name),
                                  subtitle: Text(
                                    'Zoom ${region.minZoom}–${region.maxZoom} · '
                                    '${region.tileCount} tiles · '
                                    '${region.sizeLabel}'
                                    '${region.failedTiles > 0 ? ' · '
                                              '${region.failedTiles} failed' : ''}',
                                  ),
                                  onTap: () {
                                    Navigator.of(sheetContext).pop();
                                    _mapController.fitCamera(
                                      CameraFit.bounds(
                                        bounds: LatLngBounds(
                                          LatLng(region.south, region.west),
                                          LatLng(region.north, region.east),
                                        ),
                                        padding: const EdgeInsets.all(32),
                                      ),
                                    );
                                  },
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: region.keepOffline
                                            ? 'Allow auto-delete'
                                            : 'Keep offline (pin)',
                                        icon: Icon(
                                          region.keepOffline
                                              ? Icons.push_pin
                                              : Icons.push_pin_outlined,
                                        ),
                                        onPressed: () async {
                                          await service.setRegionKeepOffline(
                                            region,
                                            !region.keepOffline,
                                          );
                                          setSheetState(() {});
                                          if (mounted) setState(() {});
                                        },
                                      ),
                                      IconButton(
                                        tooltip: 'Delete region',
                                        icon: const Icon(Icons.delete_outline),
                                        onPressed: () async {
                                          final confirmed =
                                              await _confirmDeleteRegion(
                                                region,
                                              );
                                          if (confirmed != true) return;
                                          await service.deleteRegion(region);
                                          setSheetState(() {});
                                          if (mounted) setState(() {});
                                        },
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (mounted) setState(() {});
  }

  Future<bool?> _confirmDeleteRegion(MapRegion region) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete offline region?'),
        content: Text(
          '"${region.name}" and its ${region.tileCount} cached tiles '
          '(${region.sizeLabel}) will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmClearCache() {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear map cache?'),
        content: const Text(
          'All cached tiles and downloaded regions will be deleted. '
          'The map still works online afterwards.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline map'),
        actions: [
          IconButton(
            tooltip: 'Downloaded regions',
            icon: const Icon(Icons.download_done_outlined),
            onPressed: _showRegions,
          ),
        ],
      ),
      body: _initializing
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Map storage unavailable:\n$_error',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () {
                        setState(() {
                          _initializing = true;
                          _error = null;
                        });
                        _initialize();
                      },
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          : Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: const LatLng(20, 0),
                    initialZoom: 2.5,
                    minZoom: 2,
                    maxZoom: 19,
                    backgroundColor: theme.colorScheme.surfaceContainerHigh,
                    onMapReady: () {
                      if (mounted) setState(() => _mapReady = true);
                    },
                  ),
                  children: [
                    ValueListenableBuilder<String>(
                      valueListenable: SettingsService.instance.mapTileUrl,
                      builder: (context, tileUrl, _) {
                        return TileLayer(
                          urlTemplate: tileUrl,
                          tileProvider: OfflineTileProvider(
                            tileUrlTemplate: tileUrl,
                          ),
                          minZoom: 2,
                          maxZoom: 19,
                          maxNativeZoom: 19,
                          errorTileCallback: (tile, error, stackTrace) {
                            debugPrint(
                              'Map tile ${tile.coordinates} error: $error',
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
                Positioned(
                  left: 8,
                  right: 8,
                  top: 8,
                  child: Card(
                    color: theme.colorScheme.surface.withValues(alpha: 0.9),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Text(
                        '© OpenStreetMap contributors (tile.openstreetmap.de). '
                        'Tiles are cached as you browse; downloaded regions '
                        'stay available offline.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16 + MediaQuery.paddingOf(context).bottom,
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _mapReady ? _downloadCurrentView : null,
                          icon: const Icon(Icons.download_for_offline),
                          label: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text('Download this area'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FloatingActionButton.small(
                        heroTag: 'map-regions',
                        tooltip: 'Downloaded regions',
                        onPressed: _showRegions,
                        child: const Icon(Icons.layers_outlined),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _RegionRequest {
  const _RegionRequest({
    required this.name,
    required this.minZoom,
    required this.maxZoom,
    required this.keepOffline,
  });

  final String name;
  final int minZoom;
  final int maxZoom;
  final bool keepOffline;
}

class _RegionDownloadDialog extends StatefulWidget {
  const _RegionDownloadDialog({
    required this.bounds,
    required this.initialMinZoom,
    required this.initialMaxZoom,
  });

  final LatLngBounds bounds;
  final int initialMinZoom;
  final int initialMaxZoom;

  @override
  State<_RegionDownloadDialog> createState() => _RegionDownloadDialogState();
}

class _RegionDownloadDialogState extends State<_RegionDownloadDialog> {
  late final TextEditingController _nameController;
  late RangeValues _zoomRange;
  bool _keepOffline = false;

  @override
  void initState() {
    super.initState();
    final center = widget.bounds.center;
    _nameController = TextEditingController(
      text:
          'Area near ${center.latitude.toStringAsFixed(2)}, '
          '${center.longitude.toStringAsFixed(2)}',
    );
    _zoomRange = RangeValues(
      widget.initialMinZoom.toDouble(),
      widget.initialMaxZoom.toDouble(),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  int get _minZoom => _zoomRange.start.round();
  int get _maxZoom => _zoomRange.end.round();

  int get _tileCount => tileCountForBounds(
    south: widget.bounds.south,
    west: widget.bounds.west,
    north: widget.bounds.north,
    east: widget.bounds.east,
    minZoom: _minZoom,
    maxZoom: _maxZoom,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = _tileCount;
    final tooLarge = count > MapService.maxTilesPerRegion;
    final estimated = formatBytes(estimatedTileBytes(count));

    return AlertDialog(
      title: const Text('Download this area'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameController,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Region name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Bounds: ${widget.bounds.south.toStringAsFixed(3)}, '
                '${widget.bounds.west.toStringAsFixed(3)} → '
                '${widget.bounds.north.toStringAsFixed(3)}, '
                '${widget.bounds.east.toStringAsFixed(3)}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Text('Zoom levels $_minZoom–$_maxZoom'),
              RangeSlider(
                values: _zoomRange,
                min: 2,
                max: 17,
                divisions: 15,
                labels: RangeLabels('$_minZoom', '$_maxZoom'),
                onChanged: (values) {
                  setState(() {
                    _zoomRange = RangeValues(
                      values.start.roundToDouble(),
                      values.end.roundToDouble(),
                    );
                  });
                },
              ),
              Text(
                '$count tiles, about $estimated',
                style: theme.textTheme.bodyMedium,
              ),
              if (tooLarge)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Too many tiles for one region (limit '
                    '${MapService.maxTilesPerRegion}). Choose fewer zoom '
                    'levels or a smaller view.',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _keepOffline,
                onChanged: (value) =>
                    setState(() => _keepOffline = value ?? false),
                title: const Text('Keep offline (never auto-delete)'),
                subtitle: const Text(
                  'Unpinned regions are removed after 180 days without use.',
                ),
              ),
              Text(
                'Tiles are downloaded from the configured tile source '
                '(openstreetmap.de by default). Respect the provider\'s usage '
                'policy for large downloads.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: tooLarge
              ? null
              : () {
                  final name = _nameController.text.trim();
                  Navigator.of(context).pop(
                    _RegionRequest(
                      name: name.isEmpty ? 'Map region' : name,
                      minZoom: _minZoom,
                      maxZoom: _maxZoom,
                      keepOffline: _keepOffline,
                    ),
                  );
                },
          child: const Text('Download'),
        ),
      ],
    );
  }
}
