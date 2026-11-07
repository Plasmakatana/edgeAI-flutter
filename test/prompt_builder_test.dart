import 'package:flutter_test/flutter_test.dart';
import 'package:testapp/services/knowledge_library.dart';
import 'package:testapp/services/prompt_builder.dart';

RetrievedChunk _chunk(String text, [String name = 'notes.txt']) =>
    RetrievedChunk(
      text: text,
      documentName: name,
      score: 1,
      keywordScore: 1,
      semanticScore: 0,
    );

void main() {
  group('buildGroundedPrompt', () {
    test('includes excerpts, provenance and the question', () {
      final prompt = buildGroundedPrompt(
        query: 'What do cats do?',
        sources: [
          _chunk('Cats groom themselves daily.', 'pets.pdf'),
          _chunk('Cats sleep a lot.', 'pets.pdf'),
        ],
      );
      expect(prompt, contains('Question: What do cats do?'));
      expect(prompt, contains('[1] (pets.pdf)'));
      expect(prompt, contains('[2] (pets.pdf)'));
      expect(prompt, contains('Cats groom themselves daily.'));
      expect(
        prompt,
        contains('do not cover it'),
      );
    });

    test('caps per-source and total context size', () {
      final long = 'x' * 5000;
      final prompt = buildGroundedPrompt(
        query: 'Summarize.',
        sources: [
          _chunk(long, 'a.txt'),
          _chunk(long, 'b.txt'),
          _chunk(long, 'c.txt'),
          _chunk(long, 'd.txt'),
          _chunk(long, 'e.txt'),
          _chunk(long, 'f.txt'),
        ],
        maxCharsPerSource: 100,
        maxTotalChars: 250,
      );
      expect(prompt.length, lessThan(250 + 600));
      expect(prompt, contains('Question: Summarize.'));
    });

    test('skips empty sources', () {
      final prompt = buildGroundedPrompt(
        query: 'Hi.',
        sources: [_chunk('   '), _chunk('Real content.')],
      );
      expect(prompt, isNot(contains('[2]')));
      expect(prompt, contains('Real content.'));
    });
  });
}
