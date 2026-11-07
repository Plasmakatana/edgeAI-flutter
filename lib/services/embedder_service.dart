import 'package:flutter_gemma/flutter_gemma.dart';

/// On-device semantic embeddings via flutter_gemma's embedder pipeline.
///
/// Uses the public Gecko-110M retrieval model (the `EmbeddingModel.gecko110M`
/// URLs baked into flutter_gemma 1.6.5 are stale — `gecko.tflite` 404s — so
/// explicit working URLs are used here).
///
/// The embedder model (~115MB) is only downloaded when the user opts into
/// semantic search. The instance is cached while semantic search stays
/// enabled and released via [close] to free the ~200MB of RAM it holds.
class EmbedderService {
  EmbedderService._();
  static final EmbedderService instance = EmbedderService._();

  static const String modelUrl =
      'https://huggingface.co/litert-community/Gecko-110m-en/resolve/main/Gecko_512_quant.tflite';
  static const String tokenizerUrl =
      'https://huggingface.co/litert-community/Gecko-110m-en/resolve/main/sentencepiece.model';

  /// Displayed size of the one-time semantic-model download.
  static const String downloadSizeLabel = '~115 MB';

  EmbeddingModel? _model;

  /// True when an embedder model has been installed (persists restarts).
  bool get isInstalled => FlutterGemma.hasActiveEmbedder();

  /// True when embeddings can be produced right now.
  bool get isReady => isInstalled || _model != null;

  /// Downloads (~115MB) and installs the Gecko embedding model.
  ///
  /// Idempotent: a no-op (besides progress callbacks) when already installed.
  Future<void> install({
    void Function(int progress)? onModelProgress,
    void Function(int progress)? onTokenizerProgress,
  }) async {
    final builder = FlutterGemma.installEmbedder()
        .modelFromNetwork(modelUrl)
        .tokenizerFromNetwork(tokenizerUrl);
    if (onModelProgress != null) {
      builder.withModelProgress(onModelProgress);
    }
    if (onTokenizerProgress != null) {
      builder.withTokenizerProgress(onTokenizerProgress);
    }
    await builder.install();
  }

  Future<EmbeddingModel> _ensureModel() async {
    final cached = _model;
    if (cached != null) return cached;
    final model = await FlutterGemma.getActiveEmbedder();
    _model = model;
    return model;
  }

  /// Embeds a user query ([TaskType.retrievalQuery]). Returns null when no
  /// embedder is installed or embedding fails; callers must fall back to the
  /// heuristic semantic layer.
  Future<List<double>?> embedQuery(String text) async {
    try {
      final model = await _ensureModel();
      return await model.generateEmbedding(
        text,
        taskType: TaskType.retrievalQuery,
      );
    } catch (_) {
      return null;
    }
  }

  /// Embeds document chunks ([TaskType.retrievalDocument]).
  ///
  /// Throws when no embedder is installed or embedding fails — indexing
  /// failures must surface to the user, not silently degrade.
  Future<List<List<double>>> embedDocuments(
    List<String> texts, {
    void Function(int index)? onChunk,
  }) async {
    final model = await _ensureModel();
    // Batch in groups to keep memory bounded and report progress.
    const batchSize = 16;
    final out = <List<double>>[];
    for (var i = 0; i < texts.length; i += batchSize) {
      final batch = texts.sublist(
        i,
        (i + batchSize).clamp(0, texts.length),
      );
      final vectors = await model.generateEmbeddings(
        batch,
        taskType: TaskType.retrievalDocument,
      );
      out.addAll(vectors);
      for (var j = 0; j < batch.length; j++) {
        onChunk?.call(i + j);
      }
    }
    return out;
  }

  /// Releases the embedder and its RAM. Safe to call when not loaded.
  Future<void> close() async {
    try {
      await _model?.close();
    } catch (_) {
      // Best effort; the native handle may already be gone.
    }
    _model = null;
  }
}
