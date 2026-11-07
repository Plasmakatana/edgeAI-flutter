import 'package:flutter_test/flutter_test.dart';
import 'package:testapp/services/math_segments.dart';

void main() {
  group('parseMathSegments', () {
    test('plain text yields a single segment', () {
      final segments = parseMathSegments('Just some words.');
      expect(segments, hasLength(1));
      expect(segments.first.isMath, isFalse);
    });

    test('splits inline, display and escaped forms', () {
      final segments = parseMathSegments(
        r'Energy is $E=mc^2$ and $$\int_0^1 x\,dx$$ plus \(a+b\) and \[c+d\].',
      );
      final math = segments.where((s) => s.isMath).toList();
      expect(math.map((s) => s.text),
          ['E=mc^2', r'\int_0^1 x\,dx', 'a+b', 'c+d']);
      expect(
        math.map((s) => s.displayMode),
        [false, true, false, true],
      );
      expect(segments.first.text, 'Energy is ');
    });

    test('lone dollar signs and unclosed delimiters stay plain', () {
      expect(
        parseMathSegments('That costs \$5 total.').single.isMath,
        isFalse,
      );
      final segments = parseMathSegments(r'Open $x+2 and done');
      expect(segments.every((s) => !s.isMath), isTrue);
      expect(segments.single.text, r'Open $x+2 and done');
    });

    test('empty math is treated as plain text', () {
      final segments = parseMathSegments(r'Nothing $$ here.');
      expect(segments.every((s) => !s.isMath), isTrue);
    });
  });

  group('stripMathForSpeech', () {
    test('replaces math with a speakable word', () {
      expect(
        stripMathForSpeech(r'The solution is $x=2$ ok'),
        'The solution is formula ok',
      );
    });

    test('leaves plain text untouched', () {
      expect(stripMathForSpeech('Hello world'), 'Hello world');
    });
  });
}
