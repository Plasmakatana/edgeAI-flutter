import 'package:flutter/material.dart';

import '../services/map_service.dart';
import '../services/settings_service.dart';

/// App settings: choose the theme and toggle spoken (TTS) replies.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Theme', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: settings.themeMode,
            builder: (context, current, _) {
              return SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('System'),
                    icon: Icon(Icons.brightness_auto),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode),
                  ),
                ],
                selected: {current},
                onSelectionChanged: (selection) {
                  settings.setThemeMode(selection.first);
                },
              );
            },
          ),
          const SizedBox(height: 32),
          Text('Audio', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ValueListenableBuilder<bool>(
            valueListenable: settings.ttsEnabled,
            builder: (context, enabled, _) {
              return SwitchListTile(
                title: const Text('Speak responses aloud'),
                subtitle: const Text(
                  'Read the assistant\'s replies using the '
                  'on-device text-to-speech engine',
                ),
                value: enabled,
                onChanged: settings.setTtsEnabled,
              );
            },
          ),
          const SizedBox(height: 32),
          Text('Offline map', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const _MapTileUrlEditor(),
        ],
      ),
    );
  }
}

class _MapTileUrlEditor extends StatefulWidget {
  const _MapTileUrlEditor();

  @override
  State<_MapTileUrlEditor> createState() => _MapTileUrlEditorState();
}

class _MapTileUrlEditorState extends State<_MapTileUrlEditor> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: SettingsService.instance.mapTileUrl.value,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    if (!SettingsService.isValidMapTileUrl(value)) {
      setState(() {
        _error = 'Enter an http(s) URL containing {z}, {x} and {y}.';
      });
      return;
    }
    await SettingsService.instance.setMapTileUrl(value);
    if (!mounted) return;
    setState(() => _error = null);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Map tile source saved.')));
  }

  Future<void> _reset() async {
    await SettingsService.instance.setMapTileUrl(MapService.defaultTileUrl);
    if (!mounted) return;
    _controller.text = MapService.defaultTileUrl;
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Tile URL template',
            helperText: 'Default: OpenStreetMap.de',
            errorText: _error,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'OpenStreetMap tile usage policies apply. For heavy use, '
          'configure a tile source you are allowed to download from.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.tonal(
              onPressed: _save,
              child: const Text('Save tile source'),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: _reset, child: const Text('Reset to OSM.de')),
          ],
        ),
      ],
    );
  }
}
