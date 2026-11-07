import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'chunker.dart';
import 'embedder_service.dart';
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
  });

  final String id;
  final String name;
  final String sourcePath;
  final DateTime addedAt;
  final List<String> chunks;

  /// One embedding per chunk, or null when semantic indexing is off.
  final List<List<double>>? embeddings;

  int get chunkCount => chunks.length;

  LibraryDocument copyWith({List<List<double>>? embeddings}) {
    return LibraryDocument(
      id: id,
      name: name,
      sourcePath: sourcePath,
      addedAt: addedAt,
      chunks: chunks,
      embeddings: embeddings ?? this.embeddings,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sourcePath': sourcePath,
        'addedAt': addedAt.toIso8601String(),
        'chunks': chunks,
        if (embeddings != null)
          'embeddings': [
            for (final e in embeddings!) e,
          ],
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
    );
  }
}

/// Persisted library of user documents that the LLM can retrieve from.
///
/// Stores extracted + chunked text (and optional chunk embeddings) as JSON in
/// the app documents directory. A single singleton instance is shared by the
/// home, library and chat screens.
class KnowledgeLibrary {
  KnowledgeLibrary._();
  static final KnowledgeLibrary instance = KnowledgeLibrary._();

  final List<LibraryDocument> _documents = [];
  bool _loaded = false;

  /// Notifies listeners (UI) when documents are added/removed/re-indexed.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  List<LibraryDocument> get documents => List.unmodifiable(_documents);

  bool get isEmpty => _documents.isEmpty;

  int get totalChunks => _documents.fold(0, (sum, doc) => sum + doc.chunkCount);

  Future<Directory> _libraryDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'documents', 'knowledge'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _libraryFile() async {
    final dir = await _libraryDir();
    return File(p.join(dir.path, 'library.json'));
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

  Future<void> _persist() async {
    final file = await _libraryFile();
    final payload = jsonEncode({
      'version': 1,
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

    onProgress?.call('Splitting into chunks...');
    final chunks = chunkText(text);
    if (chunks.isEmpty) {
      throw Exception('No readable text found in this document.');
    }

    List<List<double>>? embeddings;
    if (embed) {
      onProgress?.call('Indexing ${chunks.length} chunks...');
      embeddings = await EmbedderService.instance.embedDocuments(chunks);
    }

    final name = p.basename(path);
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_documents.length}';
    final doc = LibraryDocument(
      id: id,
      name: name,
      sourcePath: path,
      addedAt: DateTime.now(),
      chunks: chunks,
      embeddings: embeddings,
    );
    _documents.add(doc);
    onProgress?.call('Saving...');
    await _persist();
    revision.value++;
    return doc;
  }

  Future<void> removeDocument(String id) async {
    await load();
    _documents.removeWhere((d) => d.id == id);
    await _persist();
    revision.value++;
  }

  Future<void> clear() async {
    await load();
    _documents.clear();
    await _persist();
    revision.value++;
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
  /// runs too: real embeddings if present (and an embedder is available),
  /// otherwise the no-download heuristic reranker.
  Future<List<RetrievedChunk>> retrieve(
    String query, {
    bool semantic = false,
    int topK = 5,
  }) async {
    await load();
    if (_documents.isEmpty || query.trim().isEmpty) return const [];

    final flatChunks = <String>[];
    final owners = <LibraryDocument>[];
    for (final doc in _documents) {
      for (final chunk in doc.chunks) {
        flatChunks.add(chunk);
        owners.add(doc);
      }
    }

    List<double>? queryEmbedding;
    List<List<double>>? chunkEmbeddings;
    if (semantic && EmbedderService.instance.isReady) {
      // Use cached embeddings when the documents carry them.
      if (_documents.every((d) => d.embeddings != null)) {
        chunkEmbeddings = [for (final d in _documents) ...d.embeddings!];
        queryEmbedding = await EmbedderService.instance.embedQuery(query);
      }
    }

    final ranked = rankChunks(
      query: query,
      chunks: flatChunks,
      semantic: semantic,
      queryEmbedding: queryEmbedding,
      chunkEmbeddings: chunkEmbeddings,
      topK: topK,
    );

    return [
      for (final c in ranked)
        RetrievedChunk(
          text: flatChunks[c.index],
          documentName: owners[c.index].name,
          score: c.score,
          keywordScore: c.keywordScore,
          semanticScore: c.semanticScore,
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
  });

  final String text;
  final String documentName;
  final double score;
  final double keywordScore;
  final double semanticScore;
}
