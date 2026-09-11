import 'package:flutter/material.dart';

import '../services/model_service.dart';

/// Screen shown while the Gemma 4 E2B model is downloaded and installed,
/// with live progress feedback.
class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  int _progress = 0;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  Future<void> _startDownload() async {
    setState(() {
      _progress = 0;
      _done = false;
      _error = null;
    });
    try {
      await ModelService.instance.downloadAndInstallModel(
        onProgress: (p) {
          if (mounted) {
            setState(() => _progress = p);
          }
        },
      );
      if (mounted) {
        setState(() {
          _progress = 100;
          _done = true;
        });
      }
      // Return to the home screen; it detects the newly installed model and
      // shows the "Start talking" entry point.
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloading model'),
        automaticallyImplyLeading: !_done,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error == null) ...[
                CircularProgressIndicator(value: _progress / 100),
                const SizedBox(height: 24),
                Text(
                  'Downloading Gemma 4 E2B (~2.4 GB)...\n$_progress%',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'This may take a while depending on your connection.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ] else ...[
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text('Download failed:', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text('$_error', textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _startDownload,
                  child: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
