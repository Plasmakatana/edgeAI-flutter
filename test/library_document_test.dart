import 'package:flutter_test/flutter_test.dart';
import 'package:testapp/services/knowledge_library.dart';

void main() {
  group('LibraryDocument JSON', () {
    test('round-trips pack metadata and chunk text', () {
      final doc = LibraryDocument(
        id: 'pack:core:first-aid',
        name: 'First aid basics',
        sourcePath: 'asset://packs/core',
        addedAt: DateTime.utc(2026, 11, 7, 12),
        chunks: const ['Call emergency services first.', 'Check breathing.'],
        packId: 'core',
        packDocId: 'first-aid',
        license: 'Public domain',
        sourceUrl: 'https://example.invalid/first-aid',
        attribution: 'Original summary',
        isBuiltIn: true,
        embeddingFile: 'pack_core_first-aid.f32',
        embeddingDim: 3,
        embeddingCount: 2,
      );

      final restored = LibraryDocument.fromJson(doc.toJson());
      expect(restored.id, doc.id);
      expect(restored.packId, 'core');
      expect(restored.packDocId, 'first-aid');
      expect(restored.license, 'Public domain');
      expect(restored.sourceUrl, doc.sourceUrl);
      expect(restored.attribution, 'Original summary');
      expect(restored.isBuiltIn, isTrue);
      expect(restored.embeddingFile, 'pack_core_first-aid.f32');
      expect(restored.embeddingDim, 3);
      expect(restored.embeddingCount, 2);
      expect(restored.chunks, doc.chunks);
    });

    test('loads legacy inline embeddings arrays', () {
      final doc = LibraryDocument.fromJson({
        'id': 'legacy-1',
        'name': 'Legacy',
        'sourcePath': '',
        'addedAt': '2026-01-01T00:00:00.000Z',
        'chunks': ['alpha beta'],
        'embeddings': [
          [1.0, 2.0, 3.0],
        ],
      });
      expect(doc.embeddings, isNotNull);
      expect(doc.embeddings!.first, [1.0, 2.0, 3.0]);
      expect(doc.hasEmbeddings, isTrue);
    });

    test('user documents default to non-built-in metadata', () {
      final doc = LibraryDocument.fromJson({
        'id': 'user-1',
        'name': 'Notes.txt',
        'sourcePath': '/tmp/Notes.txt',
        'addedAt': '2026-01-01T00:00:00.000Z',
        'chunks': ['some text'],
      });
      expect(doc.isBuiltIn, isFalse);
      expect(doc.packId, isNull);
      expect(doc.hasEmbeddings, isFalse);
    });
  });
}
