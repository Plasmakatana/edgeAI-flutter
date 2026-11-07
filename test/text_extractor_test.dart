import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:testapp/services/text_extractor.dart';

/// Writes [bytes] to a temp file with the given extension and returns it.
Future<File> _tempFile(List<int> bytes, String ext) async {
  final dir = await Directory.systemTemp.createTemp('extractor_test');
  final file = File('${dir.path}/sample.$ext');
  await file.writeAsBytes(bytes);
  return file;
}

Future<List<int>> _samplePdf() async {
  final doc = sf.PdfDocument();
  final page = doc.pages.add();
  page.graphics.drawString(
    'Hello PDF world. Second sentence here.',
    sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12),
  );
  final bytes = await doc.save();
  doc.dispose();
  return bytes;
}

List<int> _sampleDocx() {
  const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Hello</w:t></w:r><w:r><w:t> docx</w:t></w:r><w:tab/><w:r><w:t>world</w:t></w:r></w:p>
    <w:p><w:r><w:t>Second paragraph.</w:t></w:r></w:p>
  </w:body>
</w:document>''';
  final archive = Archive()
    ..addFile(ArchiveFile(
      'word/document.xml',
      xml.length,
      utf8.encode(xml),
    ));
  return ZipEncoder().encode(archive);
}

void main() {
  group('TextExtractor', () {
    test('reads plain text with UTF-8 and Latin-1 fallback', () async {
      final utf8File = await _tempFile(utf8.encode('plain text'), 'txt');
      expect(await TextExtractor.extractText(utf8File.path), 'plain text');

      final latin1File =
          await _tempFile(latin1.encode('caf\xe9 \xfcnicode'), 'md');
      expect(
        await TextExtractor.extractText(latin1File.path),
        'café ünicode',
      );
    });

    test('strips HTML markup and decodes entities', () async {
      final file = await _tempFile(
        utf8.encode(
          '<html><head><style>p{color:red}</style></head>'
          '<body><h1>Title &amp; more</h1><p>First&#46;</p></body></html>',
        ),
        'html',
      );
      final text = await TextExtractor.extractText(file.path);
      expect(text, contains('Title & more'));
      expect(text, contains('First.'));
      expect(text, isNot(contains('color')));
      expect(text, isNot(contains('<')));
    });

    test('extracts text from a generated PDF', () async {
      final file = await _tempFile(await _samplePdf(), 'pdf');
      final text = await TextExtractor.extractText(file.path);
      expect(text, contains('Hello PDF world'));
    });

    test('extracts paragraphs from a minimal docx', () async {
      final file = await _tempFile(_sampleDocx(), 'docx');
      final text = await TextExtractor.extractText(file.path);
      expect(text, contains('Hello docx world'));
      expect(text, contains('Second paragraph.'));
    });

    test('rejects legacy .doc with a helpful message', () async {
      final file = await _tempFile([0xD0, 0xCF, 0x11, 0xE0], 'doc');
      expect(
        () => TextExtractor.extractText(file.path),
        throwsA(isA<UnsupportedDocumentException>()),
      );
    });
  });
}
