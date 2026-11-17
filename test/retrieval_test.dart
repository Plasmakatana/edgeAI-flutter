import 'package:flutter_test/flutter_test.dart';
import 'package:testapp/services/retrieval.dart';

const _catDoc = 'Cats are independent pets that groom themselves daily.';
const _dogDoc = 'Dogs are loyal animals that love long walks in the park.';
const _carDoc =
    'Electric cars use lithium batteries and regenerative braking systems.';

final _corpus = [_catDoc, _dogDoc, _carDoc];

void main() {
  group('tokenize/stem', () {
    test('drops stop words and stems plurals and verb forms', () {
      expect(tokenize('the connecting devices'), ['connect', 'device']);
    });

    test('empty or stop-word-only queries tokenize to nothing', () {
      expect(tokenize('what is the'), isEmpty);
    });
  });

  group('keywordScores', () {
    test('ranks the matching chunk first', () {
      final scores = keywordScores('loyal dogs', _corpus);
      expect(scores[1], greaterThan(scores[0]));
      expect(scores[1], greaterThan(scores[2]));
    });

    test('returns all zeros for an unrelated query', () {
      expect(keywordScores('quantum chromodynamics', _corpus), everyElement(0));
    });

    test('rewards exact phrases over scattered keywords', () {
      final chunks = [
        'Batteries store charge. Regenerative systems help cars.',
        _carDoc,
      ];
      final scores = keywordScores(
        'electric cars use lithium batteries',
        chunks,
      );
      expect(scores[1], greaterThan(scores[0]));
    });
  });

  group('rankChunks', () {
    test('keyword-only layer picks the right chunk', () {
      final ranked = rankChunks(query: 'long walks', chunks: _corpus);
      expect(ranked, isNotEmpty);
      expect(ranked.first.index, 1);
    });

    test('keyword-only layer returns empty for unrelated queries', () {
      // No context is better than misleading context: chat stays plain.
      final ranked = rankChunks(
        query: 'quantum chromodynamics',
        chunks: _corpus,
      );
      expect(ranked, isEmpty);
    });

    test('respects topK', () {
      final chunks = List.generate(10, (i) => 'cats and pets number $i');
      final ranked = rankChunks(query: 'cats pets', chunks: chunks, topK: 5);
      expect(ranked, hasLength(5));
    });

    test('embedding layer surfaces paraphrases with no keyword overlap', () {
      // Query vector aligned with chunk 0 only; no shared keywords at all.
      final ranked = rankChunks(
        query: 'zzz qqq',
        chunks: const ['alpha beta gamma', 'delta epsilon zeta'],
        semantic: true,
        queryEmbedding: const [1.0, 0.0, 0.0],
        chunkEmbeddings: const [
          [0.99, 0.01, 0.0],
          [0.0, 0.01, 0.99],
        ],
      );
      expect(ranked, isNotEmpty);
      expect(ranked.first.index, 0);
      expect(ranked.first.semanticScore, greaterThan(0.9));
    });

    test('combines keyword and semantic hits, keyword first on ties', () {
      // Chunk 1 is semantically identical to the query but shares no words;
      // chunk 0 shares a word but is semantically unrelated. Both make the
      // context; the exact word match leads on the tied blended score.
      final ranked = rankChunks(
        query: 'apple harvest',
        chunks: const [
          'Apple orchards need pruning in winter.',
          'Orchard fruit gathering season details.',
        ],
        semantic: true,
        queryEmbedding: const [0.0, 1.0],
        chunkEmbeddings: const [
          [1.0, 0.0],
          [0.0, 1.0],
        ],
      );
      expect(ranked.map((c) => c.index), [0, 1]);
    });

    test('semantic star is included even when keyword hits fill slots', () {
      // Five keyword-matching chunks could fill top-5 alone; the fusion
      // must still reserve room for the semantic-only star (index 5).
      final ranked = rankChunks(
        query: 'apple harvest',
        chunks: const [
          'Apple orchards need pruning in winter.',
          'Harvest season begins in autumn.',
          'Apple harvest festival plans announced.',
          'Orchard apples ripen slowly each year.',
          'Fresh apple facts for young readers.',
          'Orchard fruit gathering season details.',
        ],
        semantic: true,
        topK: 5,
        queryEmbedding: const [0.0, 1.0],
        chunkEmbeddings: const [
          [1.0, 0.0],
          [1.0, 0.0],
          [1.0, 0.0],
          [1.0, 0.0],
          [1.0, 0.0],
          [0.0, 1.0],
        ],
      );
      expect(ranked, hasLength(5));
      expect(ranked.map((c) => c.index), contains(5));
    });

    test('heuristic fallback reranks overlapping wording', () {
      final ranked = rankChunks(
        query: 'felines grooming habits',
        chunks: const [
          _catDoc,
          'Photosynthesis converts sunlight into chemical energy.',
        ],
        semantic: true,
      );
      expect(ranked, isNotEmpty);
      expect(ranked.first.index, 0);
    });

    test('heuristic fallback stays silent on unrelated queries', () {
      final ranked = rankChunks(
        query: 'quantum chromodynamics lecture notes',
        chunks: _corpus,
        semantic: true,
      );
      expect(ranked, isEmpty);
    });

    test('pre-tokenized chunks produce the same ranking', () {
      final tokenized = [for (final chunk in _corpus) tokenize(chunk)];
      final cached = rankChunks(
        query: 'loyal dogs',
        chunks: _corpus,
        tokenizedChunks: tokenized,
      );
      final fresh = rankChunks(query: 'loyal dogs', chunks: _corpus);
      expect(
        cached.map((c) => c.index).toList(),
        fresh.map((c) => c.index).toList(),
      );
      expect(
        cached.first.keywordScore,
        closeTo(fresh.first.keywordScore, 1e-9),
      );
    });

    test('missing embeddings only disable that chunk, not the layer', () {
      final ranked = rankChunks(
        query: 'zzz qqq',
        chunks: const ['alpha beta gamma', 'delta epsilon zeta'],
        semantic: true,
        queryEmbedding: const [1.0, 0.0, 0.0],
        chunkEmbeddings: const [
          <double>[],
          [0.99, 0.01, 0.0],
        ],
      );
      expect(ranked, isNotEmpty);
      expect(ranked.first.index, 1);
      expect(ranked.first.semanticScore, greaterThan(0.9));
    });
  });

  group('cosineSimilarity', () {
    test('identical vectors score 1, orthogonal score 0', () {
      expect(cosineSimilarity([1, 2, 3], [1, 2, 3]), closeTo(1.0, 1e-9));
      expect(cosineSimilarity([1, 0], [0, 1]), closeTo(0.0, 1e-9));
      expect(cosineSimilarity([], [1]), 0);
    });
  });

  group('heuristicScores', () {
    test('identical text outranks unrelated text', () {
      final scores = heuristicScores('hello friendly world', [
        'hello friendly world',
        'zxqv kwyj pfft br ap',
      ]);
      expect(scores[0], greaterThan(scores[1]));
    });
  });
}
