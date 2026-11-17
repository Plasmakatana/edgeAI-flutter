import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'embedder_service.dart';
import 'knowledge_library.dart';
import 'settings_service.dart';
import 'wikimedia_client.dart';

/// Where a content pack's documents come from.
enum ContentPackSource { asset, wikimedia, url }

/// A downloadable or bundled set of knowledge documents.
class ContentPack {
  const ContentPack({
    required this.id,
    required this.version,
    required this.name,
    required this.description,
    required this.license,
    required this.attribution,
    required this.approxBytes,
    required this.bundled,
    required this.source,
    this.assetPath,
    this.titlesAsset,
    this.project,
    this.url,
    this.sha256,
  });

  final String id;
  final int version;
  final String name;
  final String description;
  final String license;
  final String attribution;
  final int approxBytes;

  /// True when the pack ships inside the APK and is seeded on first launch.
  final bool bundled;
  final ContentPackSource source;

  final String? assetPath;
  final String? titlesAsset;
  final String? project;
  final String? url;
  final String? sha256;

  String get sizeLabel {
    if (approxBytes >= 1024 * 1024) {
      return '~${(approxBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (approxBytes >= 1024) {
      return '~${(approxBytes / 1024).round()} KB';
    }
    return '~$approxBytes bytes';
  }

  factory ContentPack.fromJson(Map<String, dynamic> json) {
    final sourceName = json['source'] as String? ?? 'asset';
    final source = ContentPackSource.values.firstWhere(
      (s) => s.name == sourceName,
      orElse: () => ContentPackSource.asset,
    );
    return ContentPack(
      id: json['id'] as String,
      version: (json['version'] as num?)?.toInt() ?? 1,
      name: json['name'] as String? ?? json['id'] as String,
      description: json['description'] as String? ?? '',
      license: json['license'] as String? ?? '',
      attribution: json['attribution'] as String? ?? '',
      approxBytes: (json['approxBytes'] as num?)?.toInt() ?? 0,
      bundled: json['bundled'] as bool? ?? false,
      source: source,
      assetPath: json['assetPath'] as String?,
      titlesAsset: json['titlesAsset'] as String?,
      project: json['project'] as String?,
      url: json['url'] as String?,
      sha256: json['sha256'] as String?,
    );
  }
}

/// A single document inside a pack file.
class ContentPackDocument {
  const ContentPackDocument({
    required this.id,
    required this.name,
    required this.text,
    this.sourceUrl,
    this.license,
    this.attribution,
  });

  final String id;
  final String name;
  final String text;
  final String? sourceUrl;
  final String? license;
  final String? attribution;

  factory ContentPackDocument.fromJson(Map<String, dynamic> json) {
    return ContentPackDocument(
      id: json['id'] as String,
      name: json['name'] as String? ?? json['id'] as String,
      text: json['text'] as String? ?? '',
      sourceUrl: json['sourceUrl'] as String?,
      license: json['license'] as String?,
      attribution: json['attribution'] as String?,
    );
  }
}

/// Parsed pack file (bundled asset or downloaded JSON).
class ContentPackFile {
  const ContentPackFile({
    required this.id,
    required this.version,
    required this.name,
    required this.documents,
    this.license,
    this.attribution,
  });

  final String id;
  final int version;
  final String name;
  final List<ContentPackDocument> documents;
  final String? license;
  final String? attribution;

  factory ContentPackFile.fromJson(Map<String, dynamic> json) {
    final rawDocs = json['documents'];
    return ContentPackFile(
      id: json['id'] as String? ?? 'pack',
      version: (json['version'] as num?)?.toInt() ?? 1,
      name: json['name'] as String? ?? 'Content pack',
      license: json['license'] as String?,
      attribution: json['attribution'] as String?,
      documents: rawDocs is List
          ? [
              for (final d in rawDocs)
                if (d is Map<String, dynamic>) ContentPackDocument.fromJson(d),
            ]
          : const [],
    );
  }
}

/// Result of installing a pack into the knowledge library.
class ContentPackInstallResult {
  const ContentPackInstallResult({
    required this.pack,
    required this.documentCount,
    required this.chunkCount,
    required this.embedded,
  });

  final ContentPack pack;
  final int documentCount;
  final int chunkCount;
  final bool embedded;
}

/// Loads the bundled catalog and installs content packs into the document
/// library. All text goes through the same chunking/embedding path as
/// user-added files.
class ContentPackService {
  ContentPackService._();
  static final ContentPackService instance = ContentPackService._();

  static const String catalogAsset = 'assets/packs/catalog.json';
  static const String _versionPrefix = 'content_pack_version:';
  static const String _removedPrefix = 'content_pack_removed:';

  List<ContentPack>? _catalogCache;

  /// Reads and caches `assets/packs/catalog.json`.
  Future<List<ContentPack>> loadCatalog() async {
    final cached = _catalogCache;
    if (cached != null) return cached;
    final raw = jsonDecode(await rootBundle.loadString(catalogAsset));
    final list = (raw as Map<String, dynamic>)['packs'] as List? ?? [];
    final packs = [
      for (final p in list)
        if (p is Map<String, dynamic>) ContentPack.fromJson(p),
    ];
    _catalogCache = packs;
    return packs;
  }

  String _versionKey(String packId) => '$_versionPrefix$packId';
  String _removedKey(String packId) => '$_removedPrefix$packId';

  /// Whether pack chunks should be embedded on install: semantic search must
  /// be enabled and the embedding model installed.
  bool get shouldEmbedPack {
    try {
      return SettingsService.instance.semanticSearch.value &&
          EmbedderService.instance.isReady;
    } catch (_) {
      // Services not initialized (tests): install text only.
      return false;
    }
  }

  /// Installs bundled packs once per version. Safe to call on every launch.
  ///
  /// If the user clears the whole library, bundled packs are seeded again; if
  /// the user removed a single pack, that choice is remembered until they
  /// install it again explicitly.
  Future<void> seedBundled() async {
    final library = KnowledgeLibrary.instance;
    await library.load();
    final prefs = await SharedPreferences.getInstance();
    final catalog = await loadCatalog();

    for (final pack in catalog.where((p) => p.bundled)) {
      if (prefs.getBool(_removedKey(pack.id)) ?? false) continue;
      final installed = prefs.getInt(_versionKey(pack.id)) ?? 0;
      final hasDocs = library.documents.any((d) => d.packId == pack.id);
      if (installed >= pack.version && hasDocs) continue;
      if (installed > 0 && !hasDocs && library.documents.isNotEmpty) {
        // The user removed these pack documents; do not resurrect them.
        continue;
      }
      // First-launch seeding should stay fast; only embed when the user has
      // already opted into semantic search and the model is installed.
      await installPack(pack, embed: shouldEmbedPack);
    }
  }

  /// Installs or upgrades [pack]. Returns counts for a UI summary.
  Future<ContentPackInstallResult> installPack(
    ContentPack pack, {
    bool embed = false,
    void Function(String stage, double? progress)? onProgress,
  }) async {
    onProgress?.call('Preparing ${pack.name}...', null);
    final docs = await _loadDocuments(pack, onProgress: onProgress);
    if (docs.isEmpty) {
      throw Exception('No documents found in "${pack.name}".');
    }

    final entries = <LibraryEntry>[
      for (final doc in docs)
        LibraryEntry(
          id: 'pack:${pack.id}:${doc.id}',
          name: doc.name,
          text: doc.text,
          sourcePath:
              doc.sourceUrl ??
              switch (pack.source) {
                ContentPackSource.asset =>
                  pack.assetPath ?? 'asset://${pack.id}',
                ContentPackSource.wikimedia => pack.project ?? 'wikimedia',
                ContentPackSource.url => pack.url ?? 'url://${pack.id}',
              },
          packId: pack.id,
          packDocId: doc.id,
          license: doc.license ?? pack.license,
          sourceUrl: doc.sourceUrl,
          attribution: doc.attribution ?? pack.attribution,
          isBuiltIn: true,
        ),
    ];

    final stored = await KnowledgeLibrary.instance.replacePackDocuments(
      pack.id,
      entries,
      embed: embed,
      onProgress: (done, total, stage) {
        if (total <= 0) {
          onProgress?.call(stage, null);
          return;
        }
        onProgress?.call(stage, 0.45 + (done / total).clamp(0.0, 1.0) * 0.55);
      },
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_versionKey(pack.id), pack.version);
    await prefs.remove(_removedKey(pack.id));
    onProgress?.call('Installed ${pack.name}.', 1.0);

    return ContentPackInstallResult(
      pack: pack,
      documentCount: stored.length,
      chunkCount: stored.fold<int>(0, (sum, d) => sum + d.chunkCount),
      embedded: embed,
    );
  }

  /// Removes every document belonging to [pack] and remembers the choice so
  /// bundled packs are not re-seeded on the next launch.
  Future<void> removePack(ContentPack pack) async {
    await KnowledgeLibrary.instance.removePack(pack.id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_versionKey(pack.id));
    await prefs.setBool(_removedKey(pack.id), true);
  }

  /// Version stored on this device, or 0 when never installed.
  Future<int> installedVersion(String packId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_versionKey(packId)) ?? 0;
  }

  Future<List<ContentPackDocument>> _loadDocuments(
    ContentPack pack, {
    void Function(String stage, double? progress)? onProgress,
  }) async {
    switch (pack.source) {
      case ContentPackSource.asset:
        final path = pack.assetPath;
        if (path == null) {
          throw Exception('Bundled pack "${pack.id}" has no asset path.');
        }
        onProgress?.call('Reading bundled pack...', 0.1);
        final file = ContentPackFile.fromJson(
          jsonDecode(await rootBundle.loadString(path)) as Map<String, dynamic>,
        );
        onProgress?.call('Prepared ${file.documents.length} documents.', 0.45);
        return file.documents;

      case ContentPackSource.wikimedia:
        return _loadWikimediaPack(pack, onProgress: onProgress);

      case ContentPackSource.url:
        return _loadUrlPack(pack, onProgress: onProgress);
    }
  }

  Future<List<ContentPackDocument>> _loadWikimediaPack(
    ContentPack pack, {
    void Function(String stage, double? progress)? onProgress,
  }) async {
    final titlesAsset = pack.titlesAsset;
    if (titlesAsset == null) {
      throw Exception('Wikimedia pack "${pack.id}" has no titles asset.');
    }
    final raw = jsonDecode(await rootBundle.loadString(titlesAsset));
    final titles = <String>[];
    if (raw is Map<String, dynamic>) {
      final categories = raw['categories'];
      if (categories is Map<String, dynamic>) {
        for (final value in categories.values) {
          if (value is List) {
            titles.addAll(value.whereType<String>());
          }
        }
      }
      final flat = raw['titles'];
      if (flat is List) {
        titles.addAll(flat.whereType<String>());
      }
    } else if (raw is List) {
      titles.addAll(raw.whereType<String>());
    }
    if (titles.isEmpty) {
      throw Exception('No article titles configured for "${pack.name}".');
    }

    final client = WikimediaClient();
    try {
      final pages = await client.fetchExtracts(
        project: pack.project ?? 'en.wikipedia.org',
        titles: titles,
        onProgress: (done, total) {
          onProgress?.call(
            'Downloading Wikipedia articles ($done/$total)...',
            total == 0 ? null : done / total * 0.9,
          );
        },
      );
      final seenIds = <String>{};
      final documents = <ContentPackDocument>[];
      for (final page in pages) {
        var slug = page.title
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
            .replaceAll(RegExp(r'^-+|-+$'), '');
        if (slug.isEmpty) slug = 'article';
        var id = slug;
        var suffix = 2;
        while (!seenIds.add(id)) {
          id = '$slug-$suffix';
          suffix++;
        }
        documents.add(
          ContentPackDocument(
            id: id,
            name: 'Wikipedia: ${page.title}',
            text:
                'Source: Wikipedia — "${page.title}"\n'
                'URL: ${page.url}\n'
                'License: CC BY-SA 4.0\n\n'
                '${page.extract}',
            sourceUrl: page.url,
            license: 'CC BY-SA 4.0',
            attribution: 'Wikipedia contributors, CC BY-SA 4.0',
          ),
        );
      }
      onProgress?.call('Prepared ${documents.length} articles.', 0.45);
      return documents;
    } finally {
      client.close();
    }
  }

  Future<List<ContentPackDocument>> _loadUrlPack(
    ContentPack pack, {
    void Function(String stage, double? progress)? onProgress,
  }) async {
    final url = pack.url;
    if (url == null) {
      throw Exception('Downloadable pack "${pack.id}" has no URL.');
    }
    onProgress?.call('Downloading pack...', null);
    final response = await http.get(
      Uri.parse(url),
      headers: const {
        'User-Agent': WikimediaClient.userAgent,
        'Accept': 'application/json',
      },
    );
    if (response.statusCode != 200) {
      throw Exception('Download failed: HTTP ${response.statusCode}.');
    }
    final expected = pack.sha256;
    if (expected != null && expected.isNotEmpty) {
      final actual = sha256.convert(response.bodyBytes).toString();
      if (actual != expected.toLowerCase()) {
        throw Exception('Pack checksum mismatch (file may be corrupted).');
      }
    }
    final file = ContentPackFile.fromJson(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
    );
    onProgress?.call('Prepared ${file.documents.length} documents.', 0.45);
    return file.documents;
  }
}
