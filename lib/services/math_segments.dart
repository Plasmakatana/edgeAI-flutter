/// Splits chat text into plain prose and LaTeX math segments so assistant
/// replies can render `$...$` / `$$...$$` / `\(...\)` / `\[...\]` expressions
/// with a real math renderer instead of showing raw backslash commands.
class MathSegment {
  const MathSegment({
    required this.text,
    required this.isMath,
    this.displayMode = false,
  });

  final String text;
  final bool isMath;

  /// True for `$$...$$` and `\[...\]` (block equations).
  final bool displayMode;
}

/// Splits [text] into plain and math segments.
///
/// Unclosed delimiters and lone `$` (e.g. prices like "$5") stay plain text,
/// as do `\$` escapes.
List<MathSegment> parseMathSegments(String text) {
  final segments = <MathSegment>[];
  final plain = StringBuffer();

  void flushPlain() {
    if (plain.isNotEmpty) {
      segments.add(MathSegment(text: plain.toString(), isMath: false));
      plain.clear();
    }
  }

  var i = 0;
  while (i < text.length) {
    String? open;
    String? close;
    var display = false;
    if (text.startsWith(r'$$', i)) {
      open = r'$$';
      close = r'$$';
      display = true;
    } else if (text.startsWith(r'\[', i)) {
      open = r'\[';
      close = r'\]';
      display = true;
    } else if (text.startsWith(r'\(', i)) {
      open = r'\(';
      close = r'\)';
    } else if (text[i] == r'$' && (i == 0 || text[i - 1] != '\\')) {
      open = r'$';
      close = r'$';
    }

    if (open == null) {
      plain.write(text[i]);
      i++;
      continue;
    }
    final end = text.indexOf(close!, i + open.length);
    if (end < 0) {
      // Unclosed delimiter: treat the opener as ordinary text.
      plain.write(text[i]);
      i++;
      continue;
    }
    final math = text.substring(i + open.length, end).trim();
    if (math.isEmpty) {
      plain.write(text.substring(i, end + close.length));
    } else {
      flushPlain();
      segments.add(
        MathSegment(text: math, isMath: true, displayMode: display),
      );
    }
    i = end + close.length;
  }
  flushPlain();
  return segments;
}

/// Renders [text] speakable: math expressions become the word "formula" so
/// text-to-speech doesn't read out raw LaTeX commands.
String stripMathForSpeech(String text) {
  final buffer = StringBuffer();
  for (final segment in parseMathSegments(text)) {
    buffer.write(segment.isMath ? ' formula ' : segment.text);
  }
  return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}
