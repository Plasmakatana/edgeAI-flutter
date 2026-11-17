import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/embedder_service.dart';
import '../services/knowledge_library.dart';
import '../services/model_service.dart';
import '../services/settings_service.dart';
import '../services/text_extractor.dart';
import '../widgets/task_progress_dialog.dart';
import 'chat_screen.dart';
import 'download_screen.dart';
import 'library_screen.dart';
import 'map_screen.dart';
import 'offline_content_screen.dart';
import 'settings_screen.dart';

/// Landing screen. Shows "start talking" when a model is installed, or the
/// download/locate options when it is not.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool? _modelInstalled;
  int _docCount = 0;
  bool _addingDocument = false;

  @override
  void initState() {
    super.initState();
    _checkModel();
  }

  Future<void> _checkModel() async {
    bool installed;
    try {
      installed = await ModelService.instance.isModelInstalled();
    } catch (_) {
      installed = false;
    }
    var docCount = 0;
    try {
      await KnowledgeLibrary.instance.load();
      docCount = KnowledgeLibrary.instance.documents.length;
    } catch (_) {
      // Plugins unavailable (tests): keep the library count at zero.
    }
    if (mounted) {
      setState(() {
        _modelInstalled = installed;
        _docCount = docCount;
      });
    }
  }

  Future<void> _onDownload(BuildContext context) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const DownloadScreen()));
    if (!mounted) return;
    await _checkModel();
    if (!mounted) return;
    _goToChatIfReady();
  }

  Future<void> _onLocate() async {
    try {
      await ModelService.instance.locateAndInstallModel();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not use that model: $e')));
      }
      return;
    }
    if (!mounted) return;
    await _checkModel();
    if (!mounted) return;
    _goToChatIfReady();
  }

  void _goToChatIfReady() {
    if (_modelInstalled == true) {
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const ChatScreen()));
    }
  }

  /// Picks a text/PDF/Word file and adds it to the document library.
  Future<void> _onAddDocument() async {
    if (_addingDocument) return;
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Select a document',
      type: FileType.custom,
      allowedExtensions: TextExtractor.pickableExtensions,
    );
    if (picked == null) return; // user cancelled
    if (picked.path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not access that file.')),
        );
      }
      return;
    }
    setState(() => _addingDocument = true);
    try {
      final embed =
          SettingsService.instance.semanticSearch.value &&
          EmbedderService.instance.isReady;
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
      setState(() => _docCount = KnowledgeLibrary.instance.documents.length);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added "${doc.name}" (${doc.chunkCount} chunks).'),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not add file: $e')));
      }
    } finally {
      if (mounted) setState(() => _addingDocument = false);
    }
  }

  Future<void> _openLibrary() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const LibraryScreen()));
    if (!mounted) return;
    setState(() => _docCount = KnowledgeLibrary.instance.documents.length);
  }

  Future<void> _openOfflineContent() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const OfflineContentScreen()));
    if (!mounted) return;
    setState(() => _docCount = KnowledgeLibrary.instance.documents.length);
  }

  Future<void> _openMap() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const MapScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasModel = _modelInstalled == true;
    final checking = _modelInstalled == null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gemma E2B'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 48 > 0
                      ? constraints.maxHeight - 48
                      : 0,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.smart_toy_outlined,
                      size: 80,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Welcome',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      hasModel
                          ? 'Your Gemma 4 E2B model is ready. Start a conversation!'
                          : (checking
                                ? 'Checking for installed model...'
                                : 'To get started, install the Gemma 4 E2B model '
                                      'or locate one already on your device.'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 48),
                    if (hasModel) ...[
                      FilledButton.icon(
                        onPressed: _goToChatIfReady,
                        icon: const Icon(Icons.chat_bubble_outline),
                        label: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'Start talking',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: _addingDocument ? null : _onAddDocument,
                        icon: const Icon(Icons.upload_file),
                        label: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'Add document',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _openLibrary,
                        icon: const Icon(Icons.folder_open),
                        label: Text(
                          _docCount == 0
                              ? 'Document library'
                              : 'Document library ($_docCount)',
                        ),
                      ),
                    ] else ...[
                      FilledButton.icon(
                        onPressed: () => _onDownload(context),
                        icon: const Icon(Icons.download),
                        label: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'Download model',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: _onLocate,
                        icon: const Icon(Icons.folder_open),
                        label: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'Locate model',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _openOfflineContent,
                      icon: const Icon(Icons.menu_book_outlined),
                      label: const Text('Offline content'),
                    ),
                    TextButton.icon(
                      onPressed: _openMap,
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('Offline map'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
