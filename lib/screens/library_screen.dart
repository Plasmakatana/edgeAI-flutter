import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/embedder_service.dart';
import '../services/knowledge_library.dart';
import '../services/settings_service.dart';
import '../services/text_extractor.dart';
import '../widgets/task_progress_dialog.dart';
import 'offline_content_screen.dart';

/// Manages the user's document library: added files, chunk counts, deletion,
/// and the optional semantic-search layer.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  bool _loading = true;
  bool _semanticOn = false;
  bool _embedderInstalled = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    bool embedderInstalled = false;
    try {
      await KnowledgeLibrary.instance.load();
      embedderInstalled = EmbedderService.instance.isInstalled;
    } catch (_) {
      // Plugin unavailable (tests/emulator): show an empty library.
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _semanticOn = SettingsService.instance.semanticSearch.value;
      _embedderInstalled = embedderInstalled;
    });
  }

  bool get _needsIndexing =>
      KnowledgeLibrary.instance.documents.any((d) => d.embeddings == null);

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _addFile() async {
    if (_busy) return;
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Select a document',
      type: FileType.custom,
      allowedExtensions: TextExtractor.pickableExtensions,
    );
    if (picked == null) return; // user cancelled
    if (picked.path == null) {
      _snack('Could not access that file.');
      return;
    }
    setState(() => _busy = true);
    try {
      final embed = _semanticOn && _embedderInstalled;
      final doc = await runWithProgressDialog(
        // ignore: use_build_context_synchronously
        context,
        title: 'Adding document',
        task: (report) => KnowledgeLibrary.instance.addDocumentFromFile(
          picked.path!,
          embed: embed,
          onProgress: (stage) => report(stage),
        ),
      );
      if (!mounted) return;
      setState(() {});
      _snack('Added "${doc.name}" (${doc.chunkCount} chunks).');
    } catch (e) {
      _snack('Could not add file: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDelete(LibraryDocument doc) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove document?'),
        content: Text(
          '"${doc.name}" and its ${doc.chunkCount} indexed chunks will be '
          'removed from the library.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await KnowledgeLibrary.instance.removeDocument(doc.id);
      if (!mounted) return;
      setState(() {});
      _snack('Removed "${doc.name}".');
    } catch (e) {
      _snack('Could not remove: $e');
    }
  }

  /// Shared enable-semantic flow: install embedder (if needed), flip the
  /// setting, then index any documents that lack embeddings.
  Future<bool> _enableSemantic() async {
    // 1. Install the embedder model on first use (~115 MB, one-time).
    if (!_embedderInstalled) {
      try {
        await runWithProgressDialog(
          // ignore: use_build_context_synchronously
          context,
          title: 'Downloading semantic model',
          task: (report) => EmbedderService.instance.install(
            onModelProgress: (p) => report(
              'Downloading model ($p%) — one-time, '
              '${EmbedderService.downloadSizeLabel}',
              p / 100 * 0.9,
            ),
            onTokenizerProgress: (p) =>
                report('Downloading tokenizer ($p%)', 0.9 + p / 100 * 0.1),
          ),
        );
      } catch (e) {
        _snack('Semantic download failed (staying on keyword search): $e');
        return false;
      }
      _embedderInstalled = true;
    }

    // 2. Index documents that don't have embeddings yet.
    if (KnowledgeLibrary.instance.documents.isNotEmpty && _needsIndexing) {
      final total = KnowledgeLibrary.instance.totalChunks;
      try {
        await runWithProgressDialog(
          // ignore: use_build_context_synchronously
          context,
          title: 'Indexing library',
          task: (report) => KnowledgeLibrary.instance.reindexAll(
            onProgress: (done, _) =>
                report('Embedding chunk $done of $total', done / total),
          ),
        );
      } catch (e) {
        _snack('Indexing failed (staying on keyword search): $e');
        return false;
      }
    }
    return true;
  }

  Future<void> _onSemanticToggle(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!value) {
        await SettingsService.instance.setSemanticSearch(false);
        await EmbedderService.instance.close(); // free embedder RAM
        if (mounted) setState(() => _semanticOn = false);
        return;
      }
      final ok = await _enableSemantic();
      if (ok) {
        await SettingsService.instance.setSemanticSearch(true);
      }
      if (mounted) {
        setState(
          () => _semanticOn = SettingsService.instance.semanticSearch.value,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final docs = KnowledgeLibrary.instance.documents;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Document library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.menu_book_outlined),
            tooltip: 'Offline content packs',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const OfflineContentScreen()),
              );
              if (!mounted) return;
              setState(() {});
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addFile,
        icon: const Icon(Icons.upload_file),
        label: const Text('Add file'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SemanticCard(
                  enabled: _semanticOn,
                  embedderInstalled: _embedderInstalled,
                  needsIndexing: _needsIndexing,
                  busy: _busy,
                  chunkCount: KnowledgeLibrary.instance.totalChunks,
                  onToggle: _onSemanticToggle,
                  onRetryIndex: () => _onSemanticToggle(true),
                ),
                const SizedBox(height: 12),
                if (docs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Column(
                      children: [
                        Icon(
                          Icons.folder_open,
                          size: 64,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No documents yet',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Add text files, PDFs or Word documents. '
                          'They are split into chunks on-device and the '
                          'assistant uses the most relevant ones to answer.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                else
                  ...docs.map(
                    (doc) => Card(
                      child: ListTile(
                        leading: Icon(_iconFor(doc.name)),
                        title: Text(
                          doc.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${doc.chunkCount} chunks'
                          '${doc.embeddings != null ? ' · indexed' : ''} · '
                          '${doc.addedAt.toLocal().toString().split('.').first}',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Remove',
                          onPressed: _busy ? null : () => _confirmDelete(doc),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 80), // room for the FAB
              ],
            ),
    );
  }

  IconData _iconFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (lower.endsWith('.docx') || lower.endsWith('.doc')) {
      return Icons.description_outlined;
    }
    return Icons.article_outlined;
  }
}

class _SemanticCard extends StatelessWidget {
  const _SemanticCard({
    required this.enabled,
    required this.embedderInstalled,
    required this.needsIndexing,
    required this.busy,
    required this.chunkCount,
    required this.onToggle,
    required this.onRetryIndex,
  });

  final bool enabled;
  final bool embedderInstalled;
  final bool needsIndexing;
  final bool busy;
  final int chunkCount;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRetryIndex;

  @override
  Widget build(BuildContext context) {
    final status = !enabled
        ? 'Off — plain keyword search.'
        : !embedderInstalled
        ? 'On — offline word-overlap rerank '
              '(download the model for true semantics).'
        : 'On — on-device embeddings over $chunkCount chunks.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          children: [
            SwitchListTile(
              title: const Text('Semantic search'),
              subtitle: Text(status),
              value: enabled,
              onChanged: busy ? null : onToggle,
            ),
            if (enabled && !embedderInstalled)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Semantic search is on but the embedding model is not '
                  'installed, so a lightweight offline reranker is used. '
                  'Turn the switch off and on again (needs internet) to '
                  'download the model (${EmbedderService.downloadSizeLabel}, '
                  'one-time).',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (enabled && embedderInstalled && needsIndexing)
              TextButton.icon(
                onPressed: busy ? null : onRetryIndex,
                icon: const Icon(Icons.sync),
                label: const Text('Index new documents'),
              ),
          ],
        ),
      ),
    );
  }
}
