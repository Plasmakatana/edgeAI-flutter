import 'package:flutter/material.dart';

import '../services/model_service.dart';
import 'chat_screen.dart';
import 'download_screen.dart';
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
    if (mounted) {
      setState(() => _modelInstalled = installed);
    }
  }

  Future<void> _onDownload(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DownloadScreen()),
    );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not use that model: $e')),
        );
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
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ChatScreen()),
      );
    }
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
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
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
                        : 'To get started, install the Gemma 4 E2B model or '
                            'locate one already on your device.'),
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
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
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
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
