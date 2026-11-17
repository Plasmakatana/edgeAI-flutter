import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

import 'screens/home_screen.dart';
import 'services/content_pack_service.dart';
import 'services/map_service.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterGemma.initialize(
    inferenceEngines: [LiteRtLmEngine()],
    // Opt-in: needed for the library's semantic (embedding) retrieval layer.
    embeddingBackends: [LiteRtEmbeddingBackend()],
  );
  await SettingsService.instance.load();
  // Seed bundled knowledge packs on first launch (local assets only; optional
  // packs are user-initiated downloads from the Offline content screen).
  try {
    await ContentPackService.instance.seedBundled();
  } catch (e) {
    debugPrint('Bundled content seeding failed: $e');
  }
  runApp(const MyApp());
  // Map cache maintenance (TTL + 1 GB LRU cap) runs off the UI isolate.
  unawaited(_initializeMapCache());
}

Future<void> _initializeMapCache() async {
  try {
    await MapService.instance.initialize();
  } catch (e) {
    debugPrint('Map cache initialization failed: $e');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: SettingsService.instance.themeMode,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'Gemma E2B Chat',
          debugShowCheckedModeBanner: false,
          theme: _buildTheme(Brightness.light),
          darkTheme: _buildTheme(Brightness.dark),
          themeMode: themeMode,
          home: const HomeScreen(),
        );
      },
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.deepPurple,
        brightness: brightness,
      ),
    );
  }
}
