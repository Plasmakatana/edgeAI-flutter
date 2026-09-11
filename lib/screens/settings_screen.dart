import 'package:flutter/material.dart';

import '../services/settings_service.dart';

/// App settings: choose the theme and toggle spoken (TTS) replies.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
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
                subtitle: const Text('Read the assistant\'s replies using the '
                    'on-device text-to-speech engine'),
                value: enabled,
                onChanged: settings.setTtsEnabled,
              );
            },
          ),
        ],
      ),
    );
  }
}
