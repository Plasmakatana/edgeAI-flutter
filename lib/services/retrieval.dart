import 'dart:math';

/// Retrieval scoring for the document library.
///
/// Layer 1 (always): BM25-style keyword search over chunk tokens.
/// Layer 2 (optional): semantic similarity — cosine over model embeddings
/// when available, otherwise a no-download character n-gram fallback.
/// The two layers are blended and the top [topK] chunks are returned.

/// A chunk selected for prompt context, with its per-layer scores.
class ScoredChunk {
  const ScoredChunk({
    required this.index,
    required this.keywordScore,
    required this.semanticScore,
    required this.score,
  });

  final int index;

  /// Raw BM25 score (0 when the chunk had no keyword overlap).
  final double keywordScore;

  /// Raw semantic similarity (cosine; 0 when the layer is off or had no hit).
  final double semanticScore;

  /// Blended score used for ranking.
  final double score;
}

/// English stop words filtered out of queries and chunks before scoring.
const Set<String> kStopWords = {
  'a',
  'about',
  'above',
  'after',
  'again',
  'against',
  'all',
  'am',
  'an',
  'and',
  'any',
  'are',
  'as',
  'at',
  'be',
  'because',
  'been',
  'before',
  'being',
  'below',
  'between',
  'both',
  'but',
  'by',
  'can',
  'could',
  'did',
  'do',
  'does',
  'doing',
  'down',
  'during',
  'each',
  'few',
  'for',
  'from',
  'further',
  'had',
  'has',
  'have',
  'having',
  'he',
  'her',
  'here',
  'hers',
  'herself',
  'him',
  'himself',
  'his',
  'how',
  'i',
  'if',
  'in',
  'into',
  'is',
  'it',
  'its',
  'itself',
  'just',
  'me',
  'more',
  'most',
  'my',
  'myself',
  'no',
  'nor',
  'not',
  'now',
  'of',
  'off',
  'on',
  'once',
  'only',
  'or',
  'other',
  'our',
  'ours',
  'ourselves',
  'out',
  'over',
  'own',
  'same',
  'she',
  'should',
  'so',
  'some',
  'such',
  'than',
  'that',
  'the',
  'their',
  'theirs',
  'them',
  'themselves',
  'then',
  'there',
  'these',
  'they',
  'this',
  'those',
  'through',
  'to',
  'too',
  'under',
  'until',
  'up',
  'very',
  'was',
  'we',
  'were',
  'what',
  'when',
  'where',
  'which',
  'while',
  'who',
  'whom',
  'why',
  'will',
  'with',
  'would',
  'you',
  'your',
  'yours',
  'yourself',
};

/// Content words: lowercased, no stop words, no stemming (used for the
/// n-gram fallback so short glue words can't fabricate similarity).
List<String> contentWords(String text) {
  return text
      .toLowerCase()
      .split(RegExp('[^a-z0-9]+'))
      .where((w) => w.length > 1 && !kStopWords.contains(w))
      .toList();
}

/// Lowercases, splits on non-alphanumerics, drops stop words and stems.
List<String> tokenize(String text) {
  return contentWords(text).map(stem).toList();
}

/// Very light stemmer: plural 's', '-ing', '-ed', '-ly' so that
/// "connecting"/"connected" match "connect" without a dictionary.
String stem(String word) {
  var w = word;
  if (w.length > 4 && w.endsWith('ies')) {
    w = '${w.substring(0, w.length - 3)}y';
  } else if (w.length > 3 &&
      w.endsWith('s') &&
      !w.endsWith('ss') &&
      !w.endsWith('us')) {
    w = w.substring(0, w.length - 1);
  }
  if (w.length > 5 && w.endsWith('ing')) {
    w = w.substring(0, w.length - 3);
  } else if (w.length > 4 && w.endsWith('ed')) {
    w = w.substring(0, w.length - 2);
  } else if (w.length > 4 && w.endsWith('ly')) {
    w = w.substring(0, w.length - 2);
  }
  if (w.length > 3 && w.endsWith('_')) {
    w = w.substring(0, w.length - 1);
  }
  return w;
}

// ---------------------------------------------------------------------------
// Layer 1 — keyword (BM25)
// ---------------------------------------------------------------------------

/// BM25 scores of [query] against every chunk. Zeros mean no keyword overlap.
///
/// [tokenizedChunks] lets callers reuse a cached tokenization (important when
/// the library contains thousands of built-in chunks); when omitted the chunks
/// are tokenized on the fly.
List<double> keywordScores(
  String query,
  List<String> chunks, {
  List<List<String>>? tokenizedChunks,
}) {
  final queryTerms = tokenize(query).toSet();
  final scores = List<double>.filled(chunks.length, 0);
  if (queryTerms.isEmpty || chunks.isEmpty) return scores;

  const k1 = 1.2;
  const b = 0.4;

  final tokenized = tokenizedChunks ?? chunks.map(tokenize).toList();
  final lengths = tokenized.map((t) => t.length).toList();
  final avgLength = lengths.isEmpty
      ? 1.0
      : lengths.reduce((a, c) => a + c) / lengths.length;
  if (avgLength == 0) return scores;

  final n = chunks.length;
  for (final term in queryTerms) {
    var df = 0;
    final tfs = <int>[];
    for (final tokens in tokenized) {
      var tf = 0;
      for (final token in tokens) {
        if (token == term || (term.length >= 4 && token.startsWith(term))) {
          tf++;
        }
      }
      tfs.add(tf);
      if (tf > 0) df++;
    }
    if (df == 0) continue;
    final idf = log(1 + (n - df + 0.5) / (df + 0.5));
    for (var i = 0; i < n; i++) {
      final tf = tfs[i];
      if (tf == 0) continue;
      final norm = 1 - b + b * (lengths[i] / avgLength);
      scores[i] += idf * (tf * (k1 + 1)) / (tf + k1 * norm);
    }
  }

  // Whole-phrase bonus: an almost-exact match outranks scattered keywords.
  final phrase = _normalize(query);
  if (phrase.length >= 6) {
    for (var i = 0; i < n; i++) {
      if (_normalize(chunks[i]).contains(phrase)) {
        scores[i] += 2.0;
      }
    }
  }
  return scores;
}

String _normalize(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

// ---------------------------------------------------------------------------
// Layer 2 — semantic
// ---------------------------------------------------------------------------

/// Cosine similarity between two vectors (0 when either is empty).
double cosineSimilarity(List<double> a, List<double> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final len = min(a.length, b.length);
  var dot = 0.0;
  var na = 0.0;
  var nb = 0.0;
  for (var i = 0; i < len; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  final value = dot / (sqrt(na) * sqrt(nb));
  return value.isFinite ? value : 0;
}

/// Semantic scores from precomputed embeddings + a query embedding.
List<double> embeddingScores(
  String query,
  List<String> chunks,
  List<double>? queryEmbedding,
  List<List<double>>? chunkEmbeddings,
) {
  final n = chunks.length;
  if (queryEmbedding == null ||
      chunkEmbeddings == null ||
      chunkEmbeddings.length != n) {
    return List<double>.filled(n, 0);
  }
  return [
    for (final e in chunkEmbeddings)
      max(0, cosineSimilarity(queryEmbedding, e)),
  ];
}

/// No-download semantic fallback: IDF-weighted character 3-gram coverage of
/// the query by each chunk.
///
/// Unlike cosine, coverage is not diluted by long chunks, so a short
/// paraphrased query still scores high when the chunk contains most of its
/// character material ("grooming habits" vs "groom ..."), while unrelated
/// text scores near zero. Returns values in [0, 1].
List<double> heuristicScores(String query, List<String> chunks) {
  final n = chunks.length;
  if (n == 0) return const [];

  final chunkSets = <Set<String>>[];
  final df = <String, int>{};
  for (final chunk in chunks) {
    final grams = _ngramSet(chunk);
    chunkSets.add(grams);
    for (final gram in grams) {
      df[gram] = (df[gram] ?? 0) + 1;
    }
  }

  // Coverage is computed per query word so multi-word queries must match
  // broadly: a chunk matching one word out of four scores proportionally.
  final queryWordGrams = <String, Set<String>>{};
  for (final word in contentWords(query)) {
    queryWordGrams.putIfAbsent(word, () => <String>{}).addAll(_ngramSet(word));
  }
  if (queryWordGrams.isEmpty) return List<double>.filled(n, 0);

  // Rare grams carry more weight; unseen grams get a neutral weight of 1.
  final weights = <String, double>{};
  for (final grams in queryWordGrams.values) {
    for (final gram in grams) {
      weights[gram] = df.containsKey(gram)
          ? log((n + 1) / (df[gram]! + 1)) + 1
          : 1.0;
    }
  }
  final total = weights.values.reduce((a, c) => a + c);
  final wordCount = queryWordGrams.length;

  return [
    for (final set in chunkSets)
      () {
        var covered = 0.0;
        for (final entry in weights.entries) {
          if (set.contains(entry.key)) covered += entry.value;
        }
        final matched = queryWordGrams.values
            .where((grams) => grams.any(set.contains))
            .length;
        return (covered / total) * (matched / wordCount);
      }(),
  ];
}

/// Character 3-grams of each word (padded with spaces so prefixes and
/// suffixes become distinctive grams like " gro" and "ing ").
Set<String> _ngramSet(String text) {
  final grams = <String>{};
  for (final word in text.toLowerCase().split(RegExp('[^a-z0-9]+'))) {
    if (word.isEmpty) continue;
    final padded = ' $word ';
    for (var i = 0; i + 3 <= padded.length; i++) {
      grams.add(padded.substring(i, i + 3));
    }
  }
  return grams;
}

// ---------------------------------------------------------------------------
// Combined ranking
// ---------------------------------------------------------------------------

/// Ranks [chunks] for [query] and returns up to [topK] candidates.
///
/// - Layer 1 always contributes keyword scores.
/// - Layer 2 contributes when [semantic] is true: embedding cosine when
///   [queryEmbedding] + [chunkEmbeddings] are present, the n-gram fallback
///   otherwise.
///
/// Fusion rule: the top slots are split between the two layers (roughly
/// half keyword-best, half semantic-best) so the context is comprehensive —
/// exact word matches AND semantically similar chunks both make it in, even
/// when one layer alone could fill every slot. A layer with no candidates
/// yields its slots to the other. With [semantic] off, all slots go to
/// keyword matches. The final order is by blended score
/// (`(1 - weight) * keyword + weight * semantic`), keyword winning ties, so
/// exact matches still surface first without starving semantic matches.
List<ScoredChunk> rankChunks({
  required String query,
  required List<String> chunks,
  List<List<String>>? tokenizedChunks,
  bool semantic = false,
  List<double>? queryEmbedding,
  List<List<double>>? chunkEmbeddings,
  int topK = 5,
  double semanticWeight = 0.5,
}) {
  if (chunks.isEmpty) return const [];

  final keyword = keywordScores(
    query,
    chunks,
    tokenizedChunks: tokenizedChunks,
  );
  final maxKeyword = keyword.fold<double>(0, max);

  List<double> semanticScores;
  double floor;
  double weight;
  if (!semantic) {
    semanticScores = List<double>.filled(chunks.length, 0);
    floor = double.infinity;
    weight = 0;
  } else if (queryEmbedding != null) {
    semanticScores = embeddingScores(
      query,
      chunks,
      queryEmbedding,
      chunkEmbeddings,
    );
    floor = 0.25; // cosine below this is noise for a 768-d text embedder
    weight = semanticWeight;
  } else {
    semanticScores = heuristicScores(query, chunks);
    final maxSem = semanticScores.fold<double>(0, max);
    // Absolute floor kills trigram noise; relative floor keeps the set tight
    // around the best hit.
    floor = max(0.15, maxSem * 0.5);
    weight = semanticWeight.clamp(0.0, 1.0);
  }
  final maxSemantic = semanticScores.fold<double>(0, max);

  // Best-first index lists per layer.
  final keywordOrder = <int>[];
  final semanticOrder = <int>[];
  {
    final kwRanked = [for (var i = 0; i < chunks.length; i++) i]
      ..sort((a, b) => keyword[b].compareTo(keyword[a]));
    final semRanked = [for (var i = 0; i < chunks.length; i++) i]
      ..sort((a, b) => semanticScores[b].compareTo(semanticScores[a]));
    for (final i in kwRanked) {
      if (maxKeyword > 0 && keyword[i] > 0) keywordOrder.add(i);
    }
    if (semantic && maxSemantic > 0) {
      for (final i in semRanked) {
        if (semanticScores[i] >= floor) semanticOrder.add(i);
      }
    }
  }

  // Fill slots: keyword layer first, then semantic layer, then leftovers.
  final picked = <int>[];
  if (!semantic) {
    picked.addAll(keywordOrder.take(topK));
  } else {
    picked.addAll(keywordOrder.take((topK + 1) ~/ 2));
    for (final i in semanticOrder) {
      if (picked.length >= topK) break;
      if (!picked.contains(i)) picked.add(i);
    }
    for (final i in keywordOrder) {
      if (picked.length >= topK) break;
      if (!picked.contains(i)) picked.add(i);
    }
  }

  final ranked = [
    for (final i in picked)
      ScoredChunk(
        index: i,
        keywordScore: keyword[i],
        semanticScore: semanticScores[i],
        score:
            (1 - weight) * (maxKeyword > 0 ? keyword[i] / maxKeyword : 0.0) +
            weight * (maxSemantic > 0 ? semanticScores[i] / maxSemantic : 0.0),
      ),
  ];
  // Blended score decides prompt order; exact matches win ties so the most
  // literal context leads.
  ranked.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final byKeyword = b.keywordScore.compareTo(a.keywordScore);
    if (byKeyword != 0) return byKeyword;
    return a.index.compareTo(b.index);
  });
  return ranked;
}
