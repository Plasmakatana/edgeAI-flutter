import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:xml/xml.dart';

/// Thrown when a picked file's format cannot be turned into text (e.g. the
/// legacy binary `.doc` format, scanned/image-only PDFs).
class UnsupportedDocumentException implements Exception {
  UnsupportedDocumentException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Extracts plain text from user-picked documents.
///
/// Supported: `.txt`, `.md`, `.markdown`, `.csv`, `.tsv`, `.json`, `.log`,
/// `.html`, `.htm` (markup stripped), `.pdf`, `.docx`.
/// Legacy binary `.doc` is intentionally rejected with a helpful message.
class TextExtractor {
  TextExtractor._();

  /// Extensions offered in the file picker.
  static const List<String> pickableExtensions = [
    'txt',
    'md',
    'markdown',
    'csv',
    'tsv',
    'json',
    'log',
    'html',
    'htm',
    'pdf',
    'docx',
    'doc',
  ];

  static const List<String> _plainTextExtensions = [
    'txt',
    'md',
    'markdown',
    'csv',
    'tsv',
    'json',
    'log',
  ];

  static const List<String> _htmlExtensions = ['html', 'htm'];

  /// Reads [path] and returns its textual content.
  ///
  /// Throws [UnsupportedDocumentException] for formats we cannot parse and
  /// generic [Exception]s for I/O or parse failures.
  static Future<String> extractText(String path) async {
    final ext = _extensionOf(path);
    if (ext == 'doc') {
      throw UnsupportedDocumentException(
        'The legacy .doc format is not supported. '
        'Please re-save the file as .docx (or .txt/.pdf) and try again.',
      );
    }
    if (_plainTextExtensions.contains(ext)) {
      return _readPlainText(path);
    }
    if (_htmlExtensions.contains(ext)) {
      return _stripHtml(await _readPlainText(path));
    }
    if (ext == 'pdf') {
      return _extractPdf(await File(path).readAsBytes());
    }
    if (ext == 'docx') {
      return _extractDocx(await File(path).readAsBytes());
    }
    throw UnsupportedDocumentException('Unsupported file type ".$ext".');
  }

  // -----------------------------------------------------------------------
  // Per-format extractors
  // -----------------------------------------------------------------------

  static Future<String> _readPlainText(String path) async {
    final bytes = await File(path).readAsBytes();
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      // Older Windows files are often Latin-1; never fail on encoding.
      text = latin1.decode(bytes);
    }
    return _normalize(text);
  }

  static String _extractPdf(List<int> bytes) {
    final doc = sf.PdfDocument(inputBytes: bytes);
    try {
      final text = sf.PdfTextExtractor(doc).extractText();
      final normalized = _normalize(text);
      if (normalized.trim().isEmpty) {
        throw UnsupportedDocumentException(
          'No selectable text found in this PDF '
          '(it may be a scanned/image-only document).',
        );
      }
      return normalized;
    } finally {
      doc.dispose();
    }
  }

  static String _extractDocx(List<int> bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw Exception('Not a valid .docx file: $e');
    }

    final entry = archive.findFile('word/document.xml');
    if (entry == null) {
      throw Exception('Not a valid .docx file (word/document.xml missing).');
    }
    final xmlBytes = entry.content as List<int>;
    final documentXml = XmlDocument.parse(utf8.decode(xmlBytes));

    final paragraphs = <String>[];
    for (final para in documentXml.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'p')) {
      final buffer = StringBuffer();
      for (final node in para.descendants) {
        if (node is XmlElement) {
          if (node.name.local == 't') {
            buffer.write(node.innerText);
          } else if (node.name.local == 'tab') {
            buffer.write(' ');
          } else if (node.name.local == 'br') {
            buffer.writeln();
          }
        }
      }
      paragraphs.add(buffer.toString().trimRight());
    }
    return _normalize(paragraphs.join('\n\n'));
  }

  /// Removes script/style blocks and tags from HTML, then decodes the few
  /// entities that matter for readable prose.
  static String _stripHtml(String html) {
    var text = html
        .replaceAll(
          RegExp(r'<(script|style)[^>]*>.*?</\1>',
              caseSensitive: false, dotAll: true),
          ' ',
        )
        .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ')
        .replaceAll(
          RegExp(r'</?(p|div|br|tr|li|h[1-6]|section|article)[^>]*>',
              caseSensitive: false),
          '\n',
        )
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1)!);
      return code != null && code >= 32 && code <= 0x10FFFF
          ? String.fromCharCode(code)
          : ' ';
    });
    return _normalize(text);
  }

  static String _normalize(String text) {
    var out = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    out = out.replaceAll(String.fromCharCodes([0]), ' ');
    // Collapse runs of 3+ blank lines, trim trailing spaces per line.
    out = out
        .split('\n')
        .map((line) => line.trimRight())
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return out.trim();
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '';
    return path.substring(dot + 1).toLowerCase();
  }
}
