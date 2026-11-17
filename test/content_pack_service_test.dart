import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:testapp/services/content_pack_service.dart';
import 'package:testapp/services/knowledge_library.dart';
import 'package:testapp/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ContentPack models', () {
    test('parses catalog fields and formats sizes', () {
      final pack = ContentPack.fromJson({
        'id': 'core',
        'version': 2,
        'name': 'Core',
        'description': 'Essential docs',
        'license': 'CC0-1.0',
        'attribution': 'Example',
        'approxBytes': 1536 * 1024,
        'bundled': true,
        'source': 'asset',
        'assetPath': 'assets/packs/core_v1.json',
      });

      expect(pack.id, 'core');
      expect(pack.version, 2);
      expect(pack.bundled, isTrue);
      expect(pack.source, ContentPackSource.asset);
      expect(pack.sizeLabel, '~1.5 MB');
    });

    test('parses pack files and skips malformed documents', () {
      final file = ContentPackFile.fromJson({
        'id': 'demo',
        'version': 3,
        'name': 'Demo',
        'documents': [
          {'id': 'a', 'name': 'A', 'text': 'hello'},
          'not-a-document',
          {'id': 'b', 'text': 'world'},
        ],
      });

      expect(file.id, 'demo');
      expect(file.version, 3);
      expect(file.documents, hasLength(2));
      expect(file.documents.first.name, 'A');
      expect(file.documents.last.name, 'b');
    });
  });

  group('ContentPackService', () {
    late Directory tempDir;
    late List<ContentPack> catalog;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('content_packs_test');
      KnowledgeLibrary.debugDocumentsDirectory = tempDir;
      KnowledgeLibrary.instance.resetForTest();
      SharedPreferences.setMockInitialValues({});
      catalog = await ContentPackService.instance.loadCatalog();
    });

    tearDown(() async {
      KnowledgeLibrary.debugDocumentsDirectory = null;
      KnowledgeLibrary.instance.resetForTest();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Best effort on Windows.
      }
    });

    test('pack embedding requires semantic search and an embedder', () {
      SettingsService.instance.semanticSearch.value = true;
      expect(ContentPackService.instance.shouldEmbedPack, isFalse);
      SettingsService.instance.semanticSearch.value = false;
      expect(ContentPackService.instance.shouldEmbedPack, isFalse);
    });

    test('bundled catalog contains the core pack and Wikipedia pack', () async {
      expect(
        catalog.map((p) => p.id),
        containsAll(['core', 'wikipedia-essentials']),
      );
      final core = catalog.firstWhere((p) => p.id == 'core');
      expect(core.bundled, isTrue);
      expect(core.source, ContentPackSource.asset);

      final wikipedia = catalog.firstWhere(
        (p) => p.id == 'wikipedia-essentials',
      );
      expect(wikipedia.source, ContentPackSource.wikimedia);
      expect(wikipedia.titlesAsset, isNotNull);
    });

    test('Wikipedia title asset is bundled and categorized', () async {
      final wikipedia = catalog.firstWhere(
        (p) => p.id == 'wikipedia-essentials',
      );
      final raw = jsonDecode(
        await rootBundle.loadString(wikipedia.titlesAsset!),
      ) as Map<String, dynamic>;
      final categories = raw['categories'] as Map<String, dynamic>;
      expect(categories, isNotEmpty);
      var titles = 0;
      for (final value in categories.values) {
        if (value is List) {
          titles += value.whereType<String>().length;
        }
      }
      expect(titles, greaterThan(50));
    });

    test(
      'seeds bundled packs once and records the installed version',
      () async {
        final service = ContentPackService.instance;
        final core = catalog.firstWhere((p) => p.id == 'core');

        await service.seedBundled();

        final docs = KnowledgeLibrary.instance.documents
            .where((d) => d.packId == core.id)
            .toList();
        expect(docs, hasLength(19));
        expect(docs.every((d) => d.isBuiltIn), isTrue);
        expect(docs.any((d) => d.chunkCount > 0), isTrue);
        expect(docs.first.id, startsWith('pack:core:'));
        expect(await service.installedVersion(core.id), core.version);

        final documentCount = KnowledgeLibrary.instance.documents.length;
        await service.seedBundled();
        expect(KnowledgeLibrary.instance.documents, hasLength(documentCount));
      },
    );

    test('removing a bundled pack is remembered across seeds', () async {
      final service = ContentPackService.instance;
      final core = catalog.firstWhere((p) => p.id == 'core');

      await service.seedBundled();
      expect(KnowledgeLibrary.instance.documents, isNotEmpty);

      await service.removePack(core);
      expect(KnowledgeLibrary.instance.documents, isEmpty);
      expect(await service.installedVersion(core.id), 0);

      await service.seedBundled();
      expect(KnowledgeLibrary.instance.documents, isEmpty);
    });

    test('explicit reinstall clears the removed flag', () async {
      final service = ContentPackService.instance;
      final core = catalog.firstWhere((p) => p.id == 'core');

      await service.seedBundled();
      await service.removePack(core);
      await service.seedBundled();
      expect(KnowledgeLibrary.instance.documents, isEmpty);

      final result = await service.installPack(core, embed: false);
      expect(result.documentCount, 19);
      expect(result.chunkCount, greaterThan(0));
      expect(result.embedded, isFalse);
      expect(KnowledgeLibrary.instance.documents, hasLength(19));

      await service.seedBundled();
      expect(KnowledgeLibrary.instance.documents, hasLength(19));
    });

    test('removing one pack keeps user documents and other packs', () async {
      final service = ContentPackService.instance;
      final core = catalog.firstWhere((p) => p.id == 'core');
      await service.seedBundled();

      await KnowledgeLibrary.instance.addDocumentsFromEntries([
        const LibraryEntry(
          id: 'user-1',
          name: 'My notes',
          text: 'A private note about my own project.',
        ),
      ]);
      expect(KnowledgeLibrary.instance.documents, hasLength(20));

      await service.removePack(core);
      final remaining = KnowledgeLibrary.instance.documents;
      expect(remaining, hasLength(1));
      expect(remaining.single.id, 'user-1');
    });
  });
}
