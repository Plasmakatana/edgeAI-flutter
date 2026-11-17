import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:testapp/services/embedding_codec.dart';

void main() {
  group('EmbeddingCodec', () {
    test('round-trips float32 vectors', () {
      final vectors = [
        [0.5, -1.25, 3.0],
        [2.5, 0.0, -0.75],
      ];
      final bytes = EmbeddingCodec.encode(vectors);
      expect(bytes.length, 2 * 3 * 4);

      final decoded = EmbeddingCodec.decode(bytes, count: 2, dim: 3);
      expect(decoded.length, 2);
      for (var row = 0; row < vectors.length; row++) {
        for (var i = 0; i < 3; i++) {
          expect(decoded[row][i], closeTo(vectors[row][i], 1e-6));
        }
      }
    });

    test('empty input encodes to empty bytes', () {
      expect(EmbeddingCodec.encode(const []), isEmpty);
    });

    test('rejects ragged vectors', () {
      expect(
        () => EmbeddingCodec.encode([
          [1.0, 2.0],
          [3.0],
        ]),
        throwsArgumentError,
      );
    });

    test('rejects truncated sidecars', () {
      expect(
        () => EmbeddingCodec.decode(Uint8List(8), count: 2, dim: 2),
        throwsArgumentError,
      );
    });
  });
}
