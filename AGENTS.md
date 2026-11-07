# AGENTS.md

## Project

Flutter app (Dart SDK ^3.13.1). Single-package structure, no monorepo.
On-device LLM chat app powered by Gemma 4 E2B via `flutter_gemma` + `flutter_gemma_litertlm`.

## Commands

```bash
flutter pub get          # install dependencies
flutter analyze          # lint (uses flutter_lints)
flutter test             # run all tests
flutter test <path>      # run single test file
flutter run               # launch app on connected device
flutter run -d <device>  # run on a specific device (e.g. -d R5CT61HDK8L)
flutter build apk        # build Android release APK
flutter build ios        # build iOS
```

## Structure

- `lib/main.dart` — app entrypoint; initializes FlutterGemma, applies persisted theme
- `lib/services/model_service.dart` — Gemma model lifecycle (download, locate, load, chat); `generateResponse` accepts retrieved context
- `lib/services/settings_service.dart` — persisted theme + TTS + semantic-search preferences (shared_preferences)
- `lib/services/text_extractor.dart` — file → text (txt/md/csv/json/log, html, pdf, docx; rejects legacy .doc)
- `lib/services/chunker.dart` — text → retrieval chunks (~700 chars, overlap)
- `lib/services/retrieval.dart` — BM25 keyword layer + optional semantic layer (model embeddings, else n-gram fallback), top-5 ranking
- `lib/services/knowledge_library.dart` — persisted document library (JSON) + retrieval entry point
- `lib/services/embedder_service.dart` — optional Gecko-110M embedder install/index/query
- `lib/services/prompt_builder.dart` — grounded-prompt assembly with context caps
- `lib/screens/home_screen.dart` — root landing screen (Start talking / Add document / library / download / locate)
- `lib/screens/library_screen.dart` — document library management + semantic-search enable flow
- `lib/screens/download_screen.dart` — download/progress screen
- `lib/screens/chat_screen.dart` — streaming chat UI + mic input (speech_to_text) + TTS replies + library grounding
- `lib/widgets/task_progress_dialog.dart` — modal progress-dialog helper for background tasks
- `test/` — widget tests + unit tests (chunker, retrieval, prompt builder, extractor)
- `integration_test/library_pipeline_test.dart` — on-device add/retrieve/remove pipeline test
- `analysis_options.yaml` — lints (flutter_lints)
- `pubspec.yaml` — dependencies
- `PROGRESS.md` — running log of changes for future context

## Dependencies

Runtime:
- `flutter_gemma` + `flutter_gemma_litertlm` — model runtime
- `file_picker`, `path_provider`, `path` — model location/copy
- `  speech_to_text` — mic / voice input
- `flutter_tts` — on-device text-to-speech replies
- `shared_preferences` — persisted settings (theme, tts)
- `syncfusion_flutter_pdf` — PDF text extraction (pure Dart)
- `archive`, `xml` — docx unzip + parse

## Notes

- No CI, codegen, or migrations configured
- No env files or secrets required

## Platform / architecture constraints (IMPORTANT)

- The app model is Gemma 4 E2B in LiteRT-LM (`.litertlm`) format.
- `.litertlm` models ONLY run on **arm64-v8a** Android devices. The
  `android/app/build.gradle.kts` restricts ABIs to `arm64-v8a`.
- The Android Emulator on this Windows PC is **x86_64 only**; arm64 system
  images do not run at usable speed on x86 hosts. To actually run the model you
  MUST use a physical arm64 Android phone (e.g. Samsung SM-A736B, serial
  `R5CT61HDK8L`) connected via USB debugging.
- Run against the phone with: `flutter run -d R5CT61HDK8L`
- Android 16 (API 36), arm64-v8a, Gradle 9.3.1, JDK 25 (F:\AndroidStudio\jbr).

## Known build quirks

- `android/gradle.properties` was tweaked to work around a Kotlin
  "Storage ... is already registered" incremental-cache compile failure:
  - `kotlin.incremental=false`
  - `kotlin.compiler.execution.strategy=in-process`
  - `org.gradle.daemon=false`
  A `gradle.properties.bak` backup exists alongside. If the build error
  reappears, also run `flutter clean` and stop Gradle daemons.
