import 'dart:typed_data';

/// Encodes/decodes chunk embeddings to/from a compact little-endian float32
/// byte representation.
///
/// Embeddings are persisted as per-document sidecar files instead of as JSON
/// arrays: a library with thousands of chunks would otherwise produce a
/// `library.json` of tens of megabytes (decimal doubles are ~20 bytes each,
/// float32 is 4).
class EmbeddingCodec {
  EmbeddingCodec._();

  /// Flattens [vectors] into little-endian float32 bytes.
  ///
  /// Throws [ArgumentError] when the vectors are ragged or empty.
  static Uint8List encode(List<List<double>> vectors) {
    if (vectors.isEmpty) return Uint8List(0);
    final dim = vectors.first.length;
    if (dim == 0) return Uint8List(0);
    for (final v in vectors) {
      if (v.length != dim) {
        throw ArgumentError('Embedding vectors have inconsistent dimensions.');
      }
    }
    final data = ByteData(vectors.length * dim * 4);
    var offset = 0;
    for (final v in vectors) {
      for (var i = 0; i < dim; i++) {
        data.setFloat32(offset, v[i], Endian.little);
        offset += 4;
      }
    }
    return data.buffer.asUint8List();
  }

  /// Decodes [bytes] into [count] vectors of [dim] doubles.
  static List<List<double>> decode(
    Uint8List bytes, {
    required int count,
    required int dim,
  }) {
    if (count <= 0 || dim <= 0) return const [];
    final expected = count * dim * 4;
    if (bytes.length < expected) {
      throw ArgumentError(
        'Embedding sidecar is truncated: expected $expected bytes, '
        'got ${bytes.length}.',
      );
    }
    final data = ByteData.sublistView(bytes, 0, expected);
    final out = <List<double>>[];
    var offset = 0;
    for (var row = 0; row < count; row++) {
      final vector = List<double>.filled(dim, 0);
      for (var i = 0; i < dim; i++) {
        vector[i] = data.getFloat32(offset, Endian.little);
        offset += 4;
      }
      out.add(vector);
    }
    return out;
  }
}
