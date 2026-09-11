# PROGRESS.md

Running log of development changes. All dates listed as of the session in which
they were made.

## Session — Gemma E2B on-device chat app

### Fix: "Bad State: Model is not loaded. Call loadModelForChat() first"

**Problem:** After the model downloads (or on relaunch when the model is already
installed, where `AppRouter` goes straight to the `ChatScreen`), sending a
message could throw `BadState: Model is not loaded. Call loadModelForChat()
first`. Root cause: `ChatScreen.initState` kicks off `loadModelForChat()`
asynchronously, but the user could send a message before the load completes, so
`ModelService._chat` was still `null` when `generateResponse()` ran.

**Fix** (`lib/screens/chat_screen.dart`):
- Extracted model-loading into `_ensureModelLoaded()` (used by both `_initModel`
  and the send path).
- `_send()` now `await`s `_ensureModelLoaded()` before calling
  `generateResponse()`, so the model is guaranteed loaded (or an error snackbar
  is shown) before any inference happens.

### Behavior: auto-open chat when the model is already installed

The `AppRouter` in `lib/main.dart` already routes to `ChatScreen` when
`ModelService.instance.isModelInstalled()` returns true, so once the model is
downloaded the app boots directly into chat — no extra taps needed. Confirmed
working as intended; no code change required for this.

### Build workaround: Kotlin "Storage ... is already registered" failure

**Problem:** `flutter run` failed on the `:android_file_picker:compileDebugKotlin`
task with `java.lang.IllegalStateException: Storage for [.../class-fq-name-to-source.tab]
is already registered`, even after `flutter clean`. This is a known Kotlin
compiler-daemon issue on Gradle 9.3.1 + JDK 25 on Windows.

**Fix** (`android/gradle.properties`, backup at `android/gradle.properties.bak`):
- `kotlin.incremental=false`
- `kotlin.compiler.execution.strategy=in-process`
- `org.gradle.daemon=false`

Also stopped Gradle/Kotlin daemons (`gradlew --stop`) and removed the stale
`build/` dirs. If the error returns, repeat `flutter clean` + kill daemons.

### Environment / device notes (2026-08-28)

- Physical ARM phone connected: Samsung SM-A736B, serial `R5CT61HDK8L`,
  arm64-v8a, Android 16 (API 36). This is the ONLY device that can run the
  `.litertlm` model.
- x86_64 Android emulator (`test_phone` AVD, API 37) boots but CANNOT run the
  model (LiteRT-LM has no x86_64 build). Emulator is for UI-only dev.
- Model runs with `flutter run -d R5CT61HDK8L`.

## Open questions / future work

- Model download/install flow on the physical phone still to be validated end
  to end after the `_send` guard fix.

## Session — Mic input, settings/theme, audio replies, navigation flow

Added voice + audio + theming features to the chat app.

### Voice input (mic) — `speech_to_text`

- `pubspec.yaml`: added `speech_to_text: ^7.0.0`.
- `ChatScreen` now has a mic button (`Icons.mic_none` / `Icons.mic`). Tapping it
  toggles speech recognition; recognized speech is sent like typed text.
- `_initSpeech()` checks availability; if unsupported the mic button is disabled.
- Added `android.permission.RECORD_AUDIO` to the main AndroidManifest (runtime
  permission is requested by the plugin during `initialize()`).

### Audio (TTS) replies — `flutter_tts`

- `pubspec.yaml`: added `flutter_tts: ^4.2.0`.
- On-device text-to-speech reads the assistant's reply aloud after it finishes
  streaming (text still shown in the chat bubble).
- Uses the device's built-in TTS engine (lightweight, low RAM/CPU) — no large
  neural TTS model bundled. Speech rate/pitch tuned in `_initTts()`.
- Added a `queries` entry for `android.intent.action.TTS_SERVICE` in the manifest
  so the engine is discoverable on Android 11+.
- TTS can be toggled from Settings or via the speaker icon in the chat AppBar.

### Settings + theme — `shared_preferences`

- New `lib/services/settings_service.dart`: persists `theme_mode` (system/light/
  dark) and `tts_enabled` using `shared_preferences`; exposes `ValueNotifier`s so
  the UI updates live.
- New `lib/screens/settings_screen.dart`: `SegmentedButton` theme picker + a
  `SwitchListTile` to toggle spoken replies. Reachable from the gear icon in the
  Home and Chat app bars.
- `main.dart`: `MyApp` now wraps the app in a `ValueListenableBuilder` on the
  theme so theme changes apply instantly and persist across restarts. Replaced the
  old `AppRouter` with `HomeScreen` as the root.

### Navigation / home flow

- `HomeScreen` is now the single root screen.
  - If no model: shows **Download model** + **Locate model** buttons.
  - If a model is installed: shows a **Start talking** button instead.
- `ChatScreen` is pushed from Home, so the AppBar shows an automatic **back
  button** to return home.
- `DownloadScreen` now pops back to Home on success instead of navigating to chat
  itself (fixes a double-navigation bug where both it and Home pushed ChatScreen).

### Tests

- `test/widget_test.dart` updated for the new HomeScreen (checks Welcome text,
  AppBar title, settings icon). `flutter analyze` clean, `flutter test` passing.

### Files changed this session

- `pubspec.yaml`, `lib/main.dart`, `lib/services/settings_service.dart` (new),
  `lib/screens/settings_screen.dart` (new), `lib/screens/home_screen.dart`,
  `lib/screens/chat_screen.dart`, `lib/screens/download_screen.dart`,
  `android/app/src/main/AndroidManifest.xml`, `test/widget_test.dart`.
