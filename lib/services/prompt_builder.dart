import 'knowledge_library.dart';

/// Builds the grounded prompt that makes the LLM answer from the user's
/// document library.
///
/// The retrieved excerpts are prepended to the user question with a short
/// instruction to prefer them and to say so when they don't cover the
/// question. Sizes are capped so the small on-device context window is not
/// blown by context alone (a full 5-excerpt prompt is ~450 tokens).
String buildGroundedPrompt({
  required String query,
  required List<RetrievedChunk> sources,
  int maxCharsPerSource = 320,
  int maxTotalChars = 1800,
}) {
  final buffer = StringBuffer()
    ..writeln(
      'Use the excerpts from my document library below when they are '
      'relevant to my question. Base your answer on them where possible. '
      'If the excerpts do not contain the answer, say that my documents '
      'do not cover it (you may add a brief general answer after that).',
    )
    ..writeln();

  var used = 0;
  var n = 0;
  for (final source in sources) {
    if (used >= maxTotalChars) break;
    var text = source.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final room = maxTotalChars - used;
    final cap = room < maxCharsPerSource ? room : maxCharsPerSource;
    if (text.length > cap) {
      text = '${text.substring(0, cap).trimRight()}…';
    }
    if (text.isEmpty) continue;
    n++;
    buffer
      ..writeln('[$n] (${source.documentName})')
      ..writeln(text)
      ..writeln();
    used += text.length;
  }

  buffer.writeln('Question: $query');
  return buffer.toString();
}
