import 'package:flutter_test/flutter_test.dart';
import 'package:testapp/services/chunker.dart';

void main() {
  group('chunkText', () {
    test('returns empty list for blank input', () {
      expect(chunkText(''), isEmpty);
      expect(chunkText('   \n\n  '), isEmpty);
    });

    test('packs short paragraphs into as few chunks as fit', () {
      const text = 'First paragraph.\n\nSecond paragraph.\n\nThird paragraph.';
      final chunks = chunkText(text, maxChars: 200);
      expect(chunks, hasLength(1));
      expect(chunks.first, contains('First paragraph.'));
      expect(chunks.first, contains('Third paragraph.'));
    });

    test('starts a new chunk when the next paragraph would overflow', () {
      const text = 'First paragraph here.\n\nSecond paragraph here.';
      final chunks = chunkText(text, maxChars: 30);
      expect(chunks, hasLength(2));
      expect(chunks[0], 'First paragraph here.');
      expect(chunks[1], 'Second paragraph here.');
    });

    test('windows an oversized paragraph with overlap', () {
      final words = List.generate(200, (i) => 'word$i').join(' ');
      final chunks = chunkText(words, maxChars: 100, overlap: 20);
      expect(chunks.length, greaterThan(2));
      for (final chunk in chunks) {
        expect(chunk.length, lessThanOrEqualTo(100));
      }
      // First window starts at the beginning, last ends at the end.
      expect(chunks.first.startsWith('word0'), isTrue);
      expect(chunks.last.endsWith('word199'), isTrue);
      // Overlap: each window starts with a whole word already covered by the
      // previous window, and every word is covered by at least one window.
      for (var i = 1; i < chunks.length; i++) {
        final firstWord = chunks[i].split(' ').first;
        expect(firstWord, isNotEmpty);
        expect(chunks[i - 1], contains(firstWord));
      }
      for (var i = 0; i < 200; i++) {
        expect(
          chunks.any((c) => c.split(' ').contains('word$i')),
          isTrue,
          reason: 'word$i covered',
        );
      }
    });

    test('collapses single newlines inside paragraphs', () {
      const text = 'line one\nline two\n\nnext para';
      final chunks = chunkText(text, maxChars: 500);
      expect(chunks, hasLength(1));
      expect(chunks.first, contains('line one line two'));
    });

    test('rejects invalid arguments', () {
      expect(() => chunkText('x', maxChars: 0), throwsArgumentError);
    });
  });
}
