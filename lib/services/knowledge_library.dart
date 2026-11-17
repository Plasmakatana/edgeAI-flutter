import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'chunker.dart';
import 'embedder_service.dart';
import 'embedding_codec.dart';
import 'retrieval.dart';
import 'text_extractor.dart';

/// A single indexed document: its metadata plus the chunks (and optional
/// embeddings) the retriever searches over.
class LibraryDocument {
  LibraryDocument({
    required this.id,
    required this.name,
    required this.sourcePath,
    required this.addedAt,
    required this.chunks,
    this.embeddings,
    this.embeddingFile,
    this.embeddingDim,
    this.embeddingCount,
    this.packId,
    this.packDocId,
    this.license,
    this.sourceUrl,
    this.attribution,
    this.isBuiltIn = false,
  });

  final String id;
  final String name;
  final String sourcePath;
  final DateTime addedAt;
  final List<String> chunks;

  /// One embedding per chunk, or null when semantic indexing is off.
  ///
  /// Hydrated lazily from [embeddingFile] for libraries persisted in the
  /// compact sidecar format.
  List<List<double>>? embeddings;

  /// Relative filename of the float32 embedding sidecar (if persisted).
  String? embeddingFile;
  int? embeddingDim;
  int? embeddingCount;

  /// Built-in/content-pack provenance. Null for user-added documents.
  final String? packId;
  final String? packDocId;
  final String? license;
  final String? sourceUrl;
  final String? attribution;
  final bool isBuiltIn;

  int get chunkCount => chunks.length;

  bool get hasEmbeddings => embeddings != null || embeddingFile != null;

  LibraryDocument copyWith({
    List<List<double>>? embeddings,
    String? embeddingFile,
    int? embeddingDim,
    int? embeddingCount,
  }) {
    return LibraryDocument(
      id: id,
      name: name,
      sourcePath: sourcePath,
      addedAt: addedAt,
      chunks: chunks,
      embeddings: embeddings ?? this.embeddings,
      embeddingFile: embeddingFile ?? this.embeddingFile,
      embeddingDim: embeddingDim ?? this.embeddingDim,
      embeddingCount: embeddingCount ?? this.embeddingCount,
      packId: packId,
      packDocId: packDocId,
      license: license,
      sourceUrl: sourceUrl,
      attribution: attribution,
      isBuiltIn: isBuiltIn,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'sourcePath': sourcePath,
    'addedAt': addedAt.toIso8601String(),
    'chunks': chunks,
    if (embeddingFile != null) 'embeddingFile': embeddingFile,
    if (embeddingDim != null) 'embeddingDim': embeddingDim,
    if (embeddingCount != null) 'embeddingCount': embeddingCount,
    if (packId != null) 'packId': packId,
    if (packDocId != null) 'packDocId': packDocId,
    if (license != null) 'license': license,
    if (sourceUrl != null) 'sourceUrl': sourceUrl,
    if (attribution != null) 'attribution': attribution,
    if (isBuiltIn) 'isBuiltIn': isBuiltIn,
  };

  factory LibraryDocument.fromJson(Map<String, dynamic> json) {
    final rawEmbeddings = json['embeddings'];
    return LibraryDocument(
      id: json['id'] as String,
      name: json['name'] as String,
      sourcePath: json['sourcePath'] as String? ?? '',
      addedAt:
          DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
      chunks: (json['chunks'] as List).cast<String>(),
      embeddings: rawEmbeddings == null
          ? null
          : [
              for (final e in (rawEmbeddings as List))
                (e as List).map((v) => (v as num).toDouble()).toList(),
            ],
      embeddingFile: json['embeddingFile'] as String?,
      embeddingDim: (json['embeddingDim'] as num?)?.toInt(),
      embeddingCount: (json['embeddingCount'] as num?)?.toInt(),
      packId: json['packId'] as String?,
      packDocId: json['packDocId'] as String?,
      license: json['license'] as String?,
      sourceUrl: json['sourceUrl'] as String?,
      attribution: json['attribution'] as String?,
      isBuiltIn: json['isBuiltIn'] as bool? ?? false,
    );
  }
}

/// A document to ingest into the library. Used by the content-pack installer
/// and by [KnowledgeLibrary.addDocumentFromFile].
class LibraryEntry {
  const LibraryEntry({
    this.id,
    required this.name,
    required this.text,
    this.sourcePath,
    this.packId,
    this.packDocId,
    this.license,
    this.sourceUrl,
    this.attribution,
    this.isBuiltIn = false,
  });

  final String? id;
  final String name;
  final String text;
  final String? sourcePath;
  final String? packId;
  final String? packDocId;
  final String? license;
  final String? sourceUrl;
  final String? attribution;
  final bool isBuiltIn;
}

/// Progress callback for batch ingestion.
typedef LibraryBatchProgress = void Function(int done, int total, String stage);

/// Persisted library of user documents that the LLM can retrieve from.
///
/// Stores extracted + chunked text (and optional chunk embeddings) as JSON in
/// the app documents directory. Embeddings are stored in compact float32
/// sidecar files so the main JSON stays small even with large built-in packs.
class KnowledgeLibrary {
  KnowledgeLibrary._();
  static final KnowledgeLibrary instance = KnowledgeLibrary._();

  final List<LibraryDocument> _documents = [];
  bool _loaded = false;

  // Retrieval index cache, rebuilt when [revision] changes.
  int _indexRevision = -1;
  List<String> _flatChunks = const [];
  List<LibraryDocument> _owners = const [];
  List<List<String>> _tokenizedChunks = const [];

  /// Notifies listeners (UI) when documents are added/removed/re-indexed.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Overrides the app documents directory in tests.
  @visibleForTesting
  static Directory? debugDocumentsDirectory;

  List<LibraryDocument> get documents => List.unmodifiable(_documents);

  bool get isEmpty => _documents.isEmpty;

  int get totalChunks => _documents.fold(0, (sum, doc) => sum + doc.chunkCount);

  Future<Directory> _libraryDir() async {
    final docs =
        debugDocumentsDirectory ?? await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'documents', 'knowledge'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Clears in-memory state so tests can start from a clean singleton.
  @visibleForTesting
  void resetForTest() {
    _documents.clear();
    _loaded = false;
    _indexRevision = -1;
    _flatChunks = const [];
    _owners = const [];
    _tokenizedChunks = const [];
    revision.value++;
  }

  Future<Directory> _embeddingsDir() async {
    final dir = Directory(p.join((await _libraryDir()).path, 'embeddings'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _libraryFile() async {
    final dir = await _libraryDir();
    return File(p.join(dir.path, 'library.json'));
  }

  String _embeddingFileName(String id) =>
      '${id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.f32';

  Future<File> _embeddingFileFor(LibraryDocument doc) async {
    final dir = await _embeddingsDir();
    return File(
      p.join(dir.path, doc.embeddingFile ?? _embeddingFileName(doc.id)),
    );
  }

  /// Loads the persisted library once. Safe to call repeatedly.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _libraryFile();
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      final list = (raw as Map<String, dynamic>)['documents'] as List? ?? [];
      _documents
        ..clear()
        ..addAll(
          list.map((e) => LibraryDocument.fromJson(e as Map<String, dynamic>)),
        );
      revision.value++;
    } catch (_) {
      // Corrupt file: start fresh rather than crash the app.
      _documents.clear();
    }
  }

  Future<void> _persistEmbeddings(LibraryDocument doc) async {
    final embeddings = doc.embeddings;
    if (embeddings == null || embeddings.isEmpty) return;
    final file = await _embeddingFileFor(doc);
    final bytes = EmbeddingCodec.encode(embeddings);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(file.path);
    doc.embeddingFile = p.basename(file.path);
    doc.embeddingDim = embeddings.first.length;
    doc.embeddingCount = embeddings.length;
  }

  Future<void> _deleteEmbeddingSidecar(LibraryDocument doc) async {
    try {
      final dir = await _embeddingsDir();
      final names = <String>{
        if (doc.embeddingFile != null) doc.embeddingFile!,
        _embeddingFileName(doc.id),
      };
      for (final name in names) {
        final file = File(p.join(dir.path, name));
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (_) {
      // Best effort: an orphan sidecar is harmless and will be overwritten.
    }
  }

  Future<void> _persist() async {
    for (final doc in _documents) {
      if (doc.embeddings != null) {
        await _persistEmbeddings(doc);
      }
    }
    final file = await _libraryFile();
    final payload = jsonEncode({
      'version': 2,
      'documents': [for (final d in _documents) d.toJson()],
    });
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(file.path);
  }

  /// Extracts, chunks and stores the file at [path]. Returns the stored doc.
  ///
  /// When [embed] is true and an embedder is available, chunk embeddings are
  /// computed and persisted too.
  Future<LibraryDocument> addDocumentFromFile(
    String path, {
    void Function(String stage)? onProgress,
    bool embed = false,
  }) async {
    await load();
    onProgress?.call('Reading file...');
    final text = await TextExtractor.extractText(path);

    final docs = await addDocumentsFromEntries(
      [LibraryEntry(name: p.basename(path), text: text, sourcePath: path)],
      embed: embed,
      onProgress: (_, _, stage) => onProgress?.call(stage),
    );
    if (docs.isEmpty) {
      throw Exception('No readable text found in this document.');
    }
    return docs.first;
  }

  /// Chunks, optionally embeds, and upserts one or more documents in a single
  /// library write.
  ///
  /// Documents with the same [LibraryEntry.id] replace existing ones. Progress
  /// is reported per document while chunking and per chunk while embedding.
  Future<List<LibraryDocument>> addDocumentsFromEntries(
    List<LibraryEntry> entries, {
    bool embed = false,
    LibraryBatchProgress? onProgress,
  }) async {
    await load();
    if (entries.isEmpty) return const [];

    final preparedById = <String, LibraryDocument>{};
    final total = entries.length;
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      onProgress?.call(i, total, 'Splitting "${e.name}"...');
      final chunks = chunkText(e.text);
      if (chunks.isEmpty) continue;
      final id =
          e.id ??
          '${DateTime.now().microsecondsSinceEpoch}-${_documents.length + i}';
      preparedById[id] = LibraryDocument(
        id: id,
        name: e.name,
        sourcePath: e.sourcePath ?? '',
        addedAt: DateTime.now(),
        chunks: chunks,
        packId: e.packId,
        packDocId: e.packDocId,
        license: e.license,
        sourceUrl: e.sourceUrl,
        attribution: e.attribution,
        isBuiltIn: e.isBuiltIn,
      );
    }

    final prepared = preparedById.values.toList();
    if (prepared.isEmpty) return const [];

    if (embed) {
      final totalChunks = prepared.fold<int>(
        0,
        (sum, doc) => sum + doc.chunkCount,
      );
      var doneChunks = 0;
      for (var i = 0; i < prepared.length; i++) {
        final doc = prepared[i];
        onProgress?.call(doneChunks, totalChunks, 'Embedding "${doc.name}"...');
        try {
          doc.embeddings = await EmbedderService.instance.embedDocuments(
            doc.chunks,
            onChunk: (_) {
              doneChunks++;
              if (totalChunks > 0) {
                onProgress?.call(
                  doneChunks,
                  totalChunks,
                  'Embedding chunk $doneChunks of $totalChunks...',
                );
              }
            },
          );
        } catch (e) {
          // Keep the text searchable even when embedding fails (e.g. the
          // optional embedder was not installed). The UI offers re-indexing.
          debugPrint('Embedding failed for "${doc.name}": $e');
          doc.embeddings = null;
        }
      }
    }

    final ids = prepared.map((d) => d.id).toSet();
    for (final old in _documents.where((d) => ids.contains(d.id)).toList()) {
      await _deleteEmbeddingSidecar(old);
      _documents.remove(old);
    }
    _documents.addAll(prepared);

    onProgress?.call(prepared.length, prepared.length, 'Saving...');
    await _persist();
    revision.value++;
    return prepared;
  }

  /// Installs/replaces all documents belonging to [packId].
  ///
  /// Documents from the same pack that are no longer present in [entries] are
  /// removed (e.g. when a pack is upgraded). User documents are never touched.
  Future<List<LibraryDocument>> replacePackDocuments(
    String packId,
    List<LibraryEntry> entries, {
    bool embed = false,
    LibraryBatchProgress? onProgress,
  }) async {
    await load();
    final docs = await addDocumentsFromEntries(
      entries,
      embed: embed,
      onProgress: onProgress,
    );
    final newIds = docs.map((d) => d.id).toSet();
    final stale = _documents
        .where((d) => d.packId == packId && !newIds.contains(d.id))
        .toList();
    if (stale.isNotEmpty) {
      for (final doc in stale) {
        await _deleteEmbeddingSidecar(doc);
      }
      _documents.removeWhere(
        (d) => d.packId == packId && !newIds.contains(d.id),
      );
      await _persist();
      revision.value++;
    }
    return docs;
  }

  Future<void> removeDocument(String id) async {
    await load();
    final matches = _documents.where((d) => d.id == id).toList();
    for (final doc in matches) {
      await _deleteEmbeddingSidecar(doc);
    }
    _documents.removeWhere((d) => d.id == id);
    await _persist();
    revision.value++;
  }

  /// Removes every document belonging to [packId] (built-in/downloaded packs).
  Future<void> removePack(String packId) async {
    await load();
    final matches = _documents.where((d) => d.packId == packId).toList();
    if (matches.isEmpty) return;
    for (final doc in matches) {
      await _deleteEmbeddingSidecar(doc);
    }
    _documents.removeWhere((d) => d.packId == packId);
    await _persist();
    revision.value++;
  }

  Future<void> clear() async {
    await load();
    for (final doc in _documents) {
      await _deleteEmbeddingSidecar(doc);
    }
    _documents.clear();
    await _persist();
    revision.value++;
  }

  /// Loads sidecar embeddings for documents that have not been hydrated yet.
  Future<void> _hydrateEmbeddings() async {
    if (_documents.every((d) => d.embeddings != null || !d.hasEmbeddings)) {
      return;
    }
    final dir = await _embeddingsDir();
    for (final doc in _documents) {
      if (doc.embeddings != null) continue;
      final name = doc.embeddingFile;
      final dim = doc.embeddingDim;
      final count = doc.embeddingCount;
      if (name == null || dim == null || count == null) continue;
      try {
        final bytes = await File(p.join(dir.path, name)).readAsBytes();
        doc.embeddings = EmbeddingCodec.decode(bytes, count: count, dim: dim);
      } catch (_) {
        // Missing/corrupt sidecar: leave this doc on the keyword layer.
      }
    }
  }

  void _rebuildIndexIfNeeded() {
    if (_indexRevision == revision.value) return;
    final chunks = <String>[];
    final owners = <LibraryDocument>[];
    for (final doc in _documents) {
      for (final chunk in doc.chunks) {
        chunks.add(chunk);
        owners.add(doc);
      }
    }
    _flatChunks = chunks;
    _owners = owners;
    _tokenizedChunks = [for (final chunk in chunks) tokenize(chunk)];
    _indexRevision = revision.value;
  }

  /// Recomputes embeddings for every chunk of every document. Used when the
  /// user enables semantic search after documents were already added.
  Future<void> reindexAll({
    void Function(int done, int total)? onProgress,
  }) async {
    await load();
    final total = totalChunks;
    var done = 0;
    for (var i = 0; i < _documents.length; i++) {
      final doc = _documents[i];
      final embeddings = await EmbedderService.instance.embedDocuments(
        doc.chunks,
        onChunk: (_) {
          done++;
          onProgress?.call(done, total);
        },
      );
      _documents[i] = doc.copyWith(embeddings: embeddings);
    }
    await _persist();
    revision.value++;
  }

  /// Retrieves the top [topK] chunks relevant to [query] across all docs.
  ///
  /// Layer 1 keyword search always runs. When [semantic] is true, layer 2
  /// runs too: real embeddings where available (and an embedder is available),
  /// otherwise the no-download heuristic reranker.
  Future<List<RetrievedChunk>> retrieve(
    String query, {
    bool semantic = false,
    int topK = 5,
  }) async {
    await load();
    if (_documents.isEmpty || query.trim().isEmpty) return const [];

    List<double>? queryEmbedding;
    List<List<double>>? chunkEmbeddings;
    if (semantic && EmbedderService.instance.isReady) {
      await _hydrateEmbeddings();
      queryEmbedding = await EmbedderService.instance.embedQuery(query);
      if (queryEmbedding != null) {
        // Build one entry per chunk. Documents without embeddings contribute
        // an empty vector so cosine scores them at zero instead of disabling
        // the semantic layer for the whole library.
        chunkEmbeddings = <List<double>>[];
        for (final doc in _documents) {
          final emb = doc.embeddings;
          final valid = emb != null && emb.length == doc.chunks.length;
          for (var i = 0; i < doc.chunks.length; i++) {
            chunkEmbeddings.add(valid ? emb[i] : const <double>[]);
          }
        }
      }
    }

    _rebuildIndexIfNeeded();

    final ranked = rankChunks(
      query: query,
      chunks: _flatChunks,
      tokenizedChunks: _tokenizedChunks,
      semantic: semantic,
      queryEmbedding: queryEmbedding,
      chunkEmbeddings: chunkEmbeddings,
      topK: topK,
    );

    return [
      for (final c in ranked)
        RetrievedChunk(
          text: _flatChunks[c.index],
          documentName: _owners[c.index].name,
          score: c.score,
          keywordScore: c.keywordScore,
          semanticScore: c.semanticScore,
          sourceUrl: _owners[c.index].sourceUrl,
          license: _owners[c.index].license,
        ),
    ];
  }
}

/// A retrieved chunk plus its provenance, ready for prompt assembly.
class RetrievedChunk {
  const RetrievedChunk({
    required this.text,
    required this.documentName,
    required this.score,
    required this.keywordScore,
    required this.semanticScore,
    this.sourceUrl,
    this.license,
  });

  final String text;
  final String documentName;
  final double score;
  final double keywordScore;
  final double semanticScore;

  /// Original source (e.g. Wikipedia article), when known.
  final String? sourceUrl;

  /// Content license, when known (e.g. CC BY-SA 4.0).
  final String? license;
}
