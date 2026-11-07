/// Splits extracted document text into retrieval-sized chunks.
///
/// Strategy: split into paragraphs first (blank lines), greedily pack short
/// paragraphs up to [maxChars], and window any oversized paragraph at
/// sentence/word boundaries with a small overlap so answers that straddle a
/// split are still retrievable.
List<String> chunkText(
  String text, {
  int maxChars = 700,
  int overlap = 80,
}) {
  if (maxChars <= 0) throw ArgumentError.value(maxChars, 'maxChars');
  if (overlap < 0 || overlap >= maxChars) {
    ArgumentError.value(overlap, 'overlap');
  }

  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final paragraphs = normalized
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.replaceAll(RegExp(r'\n+'), ' ').trim())
      .where((p) => p.isNotEmpty)
      .toList();

  final chunks = <String>[];
  final buffer = StringBuffer();

  void flush() {
    if (buffer.isNotEmpty) {
      chunks.add(buffer.toString().trim());
      buffer.clear();
    }
  }

  for (final paragraph in paragraphs) {
    if (paragraph.length <= maxChars) {
      if (buffer.isEmpty) {
        buffer.write(paragraph);
      } else if (buffer.length + 2 + paragraph.length <= maxChars) {
        buffer
          ..write('\n\n')
          ..write(paragraph);
      } else {
        flush();
        buffer.write(paragraph);
      }
      continue;
    }

    // Oversized paragraph: window it with overlap, then continue packing.
    flush();
    chunks.addAll(_window(paragraph, maxChars, overlap));
  }
  flush();

  return chunks
      .where((c) => c.trim().isNotEmpty)
      .map((c) => c.trim())
      .toList();
}

/// Sliding-window split of a single oversized [text] at word boundaries.
List<String> _window(String text, int maxChars, int overlap) {
  final result = <String>[];
  var start = 0;
  while (start < text.length) {
    var end = (start + maxChars).clamp(0, text.length);
    if (end < text.length) {
      // Prefer breaking at a nearby space so words aren't cut in half.
      final slice = text.substring(start, end);
      final lastSpace = slice.lastIndexOf(' ');
      if (lastSpace > maxChars ~/ 2) {
        end = start + lastSpace;
      }
    }
    result.add(text.substring(start, end).trim());
    if (end >= text.length) break;
    var next = end - overlap;
    if (next <= start) {
      next = end; // guarantee forward progress
    } else {
      // Snap forward to the next word boundary so windows start cleanly.
      final space = text.indexOf(' ', next);
      if (space > 0 && space + 1 < text.length) {
        next = space + 1;
      }
    }
    start = next;
  }
  return result.where((c) => c.isNotEmpty).toList();
}
