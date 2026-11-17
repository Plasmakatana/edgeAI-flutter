import 'package:flutter/material.dart';

import '../services/content_pack_service.dart';
import '../services/embedder_service.dart';
import '../services/knowledge_library.dart';
import '../services/settings_service.dart';
import '../widgets/task_progress_dialog.dart';

/// Catalog of bundled and downloadable offline knowledge packs.
///
/// Every pack is ingested through the same chunk/embed pipeline as user-added
/// documents, so the chat retrieves from it automatically.
class OfflineContentScreen extends StatefulWidget {
  const OfflineContentScreen({super.key});

  @override
  State<OfflineContentScreen> createState() => _OfflineContentScreenState();
}

class _OfflineContentScreenState extends State<OfflineContentScreen> {
  List<ContentPack> _packs = const [];
  Map<String, int> _versions = const {};
  bool _loading = true;
  String? _busyPackId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<ContentPack> packs = const [];
    final versions = <String, int>{};
    try {
      await KnowledgeLibrary.instance.load();
      packs = await ContentPackService.instance.loadCatalog();
      for (final pack in packs) {
        versions[pack.id] = await ContentPackService.instance.installedVersion(
          pack.id,
        );
      }
    } catch (_) {
      // Assets/plugins unavailable (tests): show an empty catalog.
    }
    if (!mounted) return;
    setState(() {
      _packs = packs;
      _versions = versions;
      _loading = false;
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  List<LibraryDocument> _docsFor(String packId) => KnowledgeLibrary
      .instance
      .documents
      .where((d) => d.packId == packId)
      .toList();

  Future<bool> _maybeInstallEmbedder() async {
    // Only offer the 115 MB embedder when semantic search is enabled; users
    // who keep keyword search do not need it.
    if (!SettingsService.instance.semanticSearch.value) return false;
    final choice = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Build semantic index?'),
        content: const Text(
          'Semantic search is on but the embedding model is not installed. '
          'Download it now (${EmbedderService.downloadSizeLabel}, one-time) '
          'and embed this pack? Indexing many chunks can take several '
          'minutes on a phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Install text only'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Download & index'),
          ),
        ],
      ),
    );
    if (choice != true || !mounted) return false;

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
      return true;
    } catch (e) {
      _snack('Semantic model download failed: $e');
      return false;
    }
  }

  Future<void> _install(ContentPack pack) async {
    if (_busyPackId != null) return;
    setState(() => _busyPackId = pack.id);
    try {
      var embed = ContentPackService.instance.shouldEmbedPack;
      if (!embed) {
        embed = await _maybeInstallEmbedder();
      }
      if (!mounted) return;

      final result = await runWithProgressDialog<ContentPackInstallResult>(
        // ignore: use_build_context_synchronously
        context,
        title: 'Installing ${pack.name}',
        task: (report) => ContentPackService.instance.installPack(
          pack,
          embed: embed,
          onProgress: (stage, progress) => report(stage, progress),
        ),
      );
      if (!mounted) return;
      final version = await ContentPackService.instance.installedVersion(
        pack.id,
      );
      if (!mounted) return;
      setState(() {
        _versions = {..._versions, pack.id: version};
      });
      _snack(
        'Installed "${pack.name}": ${result.documentCount} documents, '
        '${result.chunkCount} chunks'
        '${result.embedded ? ', embedded.' : '.'}',
      );
    } catch (e) {
      _snack('Could not install "${pack.name}": $e');
    } finally {
      if (mounted) setState(() => _busyPackId = null);
    }
  }

  Future<void> _remove(ContentPack pack) async {
    if (_busyPackId != null) return;
    final docs = _docsFor(pack.id);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove content pack?'),
        content: Text(
          '"${pack.name}" (${docs.length} documents, '
          '${docs.fold<int>(0, (sum, d) => sum + d.chunkCount)} chunks) will '
          'be removed from the library. Your own documents are not touched.',
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

    setState(() => _busyPackId = pack.id);
    try {
      await ContentPackService.instance.removePack(pack);
      if (!mounted) return;
      setState(() {
        _versions = {..._versions, pack.id: 0};
      });
      _snack('Removed "${pack.name}".');
    } catch (e) {
      _snack('Could not remove "${pack.name}": $e');
    } finally {
      if (mounted) setState(() => _busyPackId = null);
    }
  }

  Future<void> _reindex() async {
    if (_busyPackId != null) return;
    setState(() => _busyPackId = 'all');
    try {
      final total = KnowledgeLibrary.instance.totalChunks;
      await runWithProgressDialog(
        // ignore: use_build_context_synchronously
        context,
        title: 'Building semantic index',
        task: (report) => KnowledgeLibrary.instance.reindexAll(
          onProgress: (done, _) => report(
            'Embedding chunk $done of $total',
            total == 0 ? null : done / total,
          ),
        ),
      );
      if (!mounted) return;
      setState(() {});
      _snack('Semantic index updated.');
    } catch (e) {
      _snack('Indexing failed: $e');
    } finally {
      if (mounted) setState(() => _busyPackId = null);
    }
  }

  void _showAttribution(ContentPack pack) {
    final docs = _docsFor(pack.id);
    final sources = <String>{
      for (final doc in docs)
        if (doc.sourceUrl != null && doc.sourceUrl!.isNotEmpty) doc.sourceUrl!,
    }.toList()..sort();
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Sources — ${pack.name}'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              Text(
                'License: ${pack.license}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(pack.attribution),
              if (sources.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text(
                  'Source URLs',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                for (final url in sources)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      url,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  bool _needsIndexing() =>
      KnowledgeLibrary.instance.documents.any((d) => !d.hasEmbeddings);

  bool _embedderReady() {
    try {
      return EmbedderService.instance.isReady;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final docs = KnowledgeLibrary.instance.documents;
    final embedded = docs.where((d) => d.hasEmbeddings).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Offline content')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Knowledge packs are chunked on-device and searched by the '
                  'assistant exactly like documents you add yourself.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                Card(
                  color: theme.colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.health_and_safety_outlined,
                          color: theme.colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Health and emergency guides are general '
                            'information only, not medical advice. In an '
                            'emergency call your local emergency number.',
                            style: TextStyle(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_packs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('No content packs available.'),
                  )
                else
                  for (final pack in _packs) ...[
                    _PackCard(
                      pack: pack,
                      docs: _docsFor(pack.id),
                      installedVersion: _versions[pack.id] ?? 0,
                      busy: _busyPackId != null,
                      onInstall: () => _install(pack),
                      onRemove: () => _remove(pack),
                      onAttribution: () => _showAttribution(pack),
                    ),
                    const SizedBox(height: 8),
                  ],
                if (docs.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.storage_outlined),
                      title: Text(
                        '${docs.length} documents, '
                        '${KnowledgeLibrary.instance.totalChunks} chunks',
                      ),
                      subtitle: Text(
                        '$embedded of ${docs.length} documents have '
                        'embeddings${_needsIndexing() ? ' — enable semantic '
                                  'search or re-index to embed everything.' : '.'}',
                      ),
                      trailing: TextButton(
                        onPressed:
                            _busyPackId == null &&
                                _embedderReady() &&
                                _needsIndexing()
                            ? _reindex
                            : null,
                        child: const Text('Index now'),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                Text(
                  'Content licenses and attributions are shown per pack. '
                  'Downloaded packs can be removed at any time; removing a '
                  'pack never deletes your own documents.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
    );
  }
}

class _PackCard extends StatelessWidget {
  const _PackCard({
    required this.pack,
    required this.docs,
    required this.installedVersion,
    required this.busy,
    required this.onInstall,
    required this.onRemove,
    required this.onAttribution,
  });

  final ContentPack pack;
  final List<LibraryDocument> docs;
  final int installedVersion;
  final bool busy;
  final VoidCallback onInstall;
  final VoidCallback onRemove;
  final VoidCallback onAttribution;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final installed = docs.isNotEmpty;
    final updateAvailable = installed && installedVersion < pack.version;
    final chunks = docs.fold<int>(0, (sum, d) => sum + d.chunkCount);

    String status;
    if (!installed) {
      status = pack.bundled ? 'Bundled · not installed' : 'Not installed';
    } else if (updateAvailable) {
      status = 'Installed v$installedVersion · update to v${pack.version}';
    } else {
      status = 'Installed v$installedVersion';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  pack.id.contains('wiki')
                      ? Icons.public
                      : Icons.menu_book_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(pack.name, style: theme.textTheme.titleMedium),
                ),
                if (pack.bundled)
                  Chip(
                    label: const Text('Bundled'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(pack.description, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            Text(
              '$status · ${pack.sizeLabel}'
              '${chunks > 0 ? ' · $chunks chunks' : ''}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  onPressed: busy ? null : onInstall,
                  icon: Icon(installed ? Icons.sync : Icons.download),
                  label: Text(installed ? 'Reinstall' : 'Install'),
                ),
                if (installed)
                  OutlinedButton.icon(
                    onPressed: busy ? null : onRemove,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove'),
                  ),
                TextButton(
                  onPressed: onAttribution,
                  child: const Text('Sources'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
