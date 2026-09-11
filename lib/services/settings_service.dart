import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds app-wide settings (currently the app theme) and persists them so the
/// choice survives app restarts.
class SettingsService {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  static const String _themeKey = 'theme_mode';
  static const String _ttsKey = 'tts_enabled';

  /// In-memory theme that the UI listens to for live updates.
  final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.system);

  /// Whether audio (text-to-speech) responses are enabled.
  final ValueNotifier<bool> ttsEnabled = ValueNotifier(true);

  /// Loads persisted settings from disk.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    themeMode.value = _themeModeFromName(prefs.getString(_themeKey));
    ttsEnabled.value = prefs.getBool(_ttsKey) ?? true;
  }

  /// Sets the app theme and persists the choice.
  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, mode.name);
  }

  /// Enables/disables spoken (TTS) replies and persists the choice.
  Future<void> setTtsEnabled(bool enabled) async {
    ttsEnabled.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ttsKey, enabled);
  }

  ThemeMode _themeModeFromName(String? name) {
    switch (name) {
      case 'dark':
        return ThemeMode.dark;
      case 'light':
        return ThemeMode.light;
      default:
        return ThemeMode.system;
    }
  }
}
