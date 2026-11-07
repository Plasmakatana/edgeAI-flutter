import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:testapp/services/knowledge_library.dart';

/// End-to-end pipeline check on a real device: write sample files, add them
/// to the library, retrieve, then clean up (never touches pre-existing docs).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('document pipeline: txt + pdf + docx add/retrieve/remove',
      (tester) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/lib_test_${DateTime.now().millisecondsSinceEpoch}');
    await dir.create(recursive: true);

    final txt = File('${dir.path}/cats.txt');
    await txt.writeAsString(
      'Cats are independent pets.\n\nThey groom themselves daily and '
      'sleep up to sixteen hours.',
    );

    final pdf = File('${dir.path}/dogs.pdf');
    final doc = sf.PdfDocument();
    doc.pages
        .add()
        .graphics
        .drawString(
          'Dogs are loyal animals that love long walks in the park.',
          sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 12),
        );
    await pdf.writeAsBytes(await doc.save());
    doc.dispose();

    const docxXml = '''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Electric cars use lithium batteries.</w:t></w:r></w:p>
  </w:body>
</w:document>''';
    final archive = Archive()
      ..addFile(ArchiveFile(
        'word/document.xml',
        docxXml.length,
        utf8.encode(docxXml),
      ));
    final docx = File('${dir.path}/cars.docx');
    await docx.writeAsBytes(ZipEncoder().encode(archive));

    final library = KnowledgeLibrary.instance;
    await library.load();
    final before = library.documents.length;

    final added = <String>[];
    for (final path in [txt.path, pdf.path, docx.path]) {
      final stored = await library.addDocumentFromFile(path);
      added.add(stored.id);
      expect(stored.chunkCount, greaterThan(0));
    }
    expect(library.documents.length, before + 3);

    // Layer 1: keyword retrieval finds the right document.
    var hits = await library.retrieve('loyal dogs long walks');
    expect(hits, isNotEmpty);
    expect(hits.first.documentName, 'dogs.pdf');

    // Layer 2 (heuristic fallback, no embedder needed): paraphrased query.
    hits = await library.retrieve(
      'feline pets grooming habits',
      semantic: true,
    );
    expect(hits, isNotEmpty);
    expect(hits.first.documentName, 'cats.txt');

    // Unrelated query stays silent (no misleading context).
    hits = await library.retrieve('quantum chromodynamics', semantic: true);
    expect(hits, isEmpty);

    // Persistence round-trip is covered implicitly by load(); clean up.
    for (final id in added) {
      await library.removeDocument(id);
    }
    expect(library.documents.length, before);
    await dir.delete(recursive: true);
  });
}
