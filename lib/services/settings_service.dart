import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'map_service.dart';

/// Holds app-wide settings (currently the app theme) and persists them so the
/// choice survives app restarts.
class SettingsService {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  static const String _themeKey = 'theme_mode';
  static const String _ttsKey = 'tts_enabled';
  static const String _semanticKey = 'semantic_search';
  static const String _mapTileUrlKey = 'map_tile_url';

  /// In-memory theme that the UI listens to for live updates.
  final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.system);

  /// Whether audio (text-to-speech) responses are enabled.
  final ValueNotifier<bool> ttsEnabled = ValueNotifier(true);

  /// Whether the optional semantic retrieval layer is enabled.
  final ValueNotifier<bool> semanticSearch = ValueNotifier(false);

  /// Tile URL template used by the offline map (defaults to openstreetmap.de).
  final ValueNotifier<String> mapTileUrl = ValueNotifier(
    MapService.defaultTileUrl,
  );

  /// Loads persisted settings from disk.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    themeMode.value = _themeModeFromName(prefs.getString(_themeKey));
    ttsEnabled.value = prefs.getBool(_ttsKey) ?? true;
    semanticSearch.value = prefs.getBool(_semanticKey) ?? false;
    final tileUrl = prefs.getString(_mapTileUrlKey)?.trim();
    // The main OSM tile server now answers apps with a blocked image; migrate
    // anyone who saved that legacy default to the community tile server.
    if (tileUrl == MapService.legacyOsmTileUrl) {
      mapTileUrl.value = MapService.defaultTileUrl;
    } else {
      mapTileUrl.value = isValidMapTileUrl(tileUrl)
          ? tileUrl!
          : MapService.defaultTileUrl;
    }
  }

  /// A usable tile template must contain the x/y/zoom placeholders.
  static bool isValidMapTileUrl(String? value) {
    if (value == null) return false;
    return value.contains('{z}') &&
        value.contains('{x}') &&
        value.contains('{y}') &&
        (value.startsWith('https://') || value.startsWith('http://'));
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

  /// Enables/disables the optional semantic retrieval layer and persists it.
  Future<void> setSemanticSearch(bool enabled) async {
    semanticSearch.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_semanticKey, enabled);
  }

  /// Persists the map tile URL template.
  Future<void> setMapTileUrl(String template) async {
    final trimmed = template.trim();
    if (!isValidMapTileUrl(trimmed)) {
      throw ArgumentError.value(template, 'template', 'invalid tile URL');
    }
    mapTileUrl.value = trimmed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mapTileUrlKey, trimmed);
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
