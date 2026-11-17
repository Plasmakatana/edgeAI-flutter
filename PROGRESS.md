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

## Session — Document library + two-layer retrieval (RAG-lite)

Added an on-device document library: users pick text/PDF/Word files, the app
extracts text, splits it into chunks, and the chat retrieves the top 5 chunks
as LLM context.

### New services (`lib/services/`)

- `text_extractor.dart` — file → text. Plain formats (txt/md/csv/json/log)
  via UTF-8 with Latin-1 fallback; html/htm with tag stripping + entity
  decoding; PDF via `syncfusion_flutter_pdf` (`PdfTextExtractor`, rejects
  scanned/image-only PDFs); docx via `archive` (unzip) + `xml`
  (`w:p`/`w:t` paragraphs, tabs/breaks preserved). Legacy binary `.doc` is
  rejected with a "re-save as .docx" message.
- `chunker.dart` — text → paragraphs → chunks (~700 chars, greedy packing;
  oversized paragraphs are windowed at word boundaries with overlap and a
  clean word-boundary window start).
- `retrieval.dart` — pure scoring. Layer 1: BM25 keyword search (stopwords,
  light stemmer, prefix matching, whole-phrase bonus). Layer 2 (optional):
  cosine over model embeddings when available, else a no-download fallback =
  IDF-weighted character 3-gram query coverage × per-word breadth. Blended
  top-K with a silence rule (no keyword overlap and below the semantic floor
  → no context, chat stays plain).
- `knowledge_library.dart` — singleton + JSON persistence
  (`documents/knowledge/library.json`, atomic write, corrupt-file tolerant).
  `addDocumentFromFile`, `removeDocument`, `reindexAll`, `retrieve`.
- `embedder_service.dart` — optional Gecko-110M embedder (~115MB one-time
  download) via `FlutterGemma.installEmbedder()`; instance cached while
  semantic search is on, released via `close()`. NOTE: the
  `EmbeddingModel.gecko110M` URLs baked into flutter_gemma 1.6.5 are stale
  (`gecko.tflite` 404s); explicit working URLs are used
  (`Gecko_512_quant.tflite` + `sentencepiece.model`, verified downloadable).
- `prompt_builder.dart` — grounded prompt assembly, capped (~380 chars per
  excerpt, ~2200 total) for the 1024-token on-device context window.

### Wiring

- `main.dart` — registers `LiteRtEmbeddingBackend()` in
  `FlutterGemma.initialize` (opt-in; keyword path works without it).
- `settings_service.dart` — persisted `semanticSearch` toggle (default off).
- `model_service.dart` — `generateResponse(query, {context})` wraps the query
  in the grounded prompt when excerpts exist.
- `home_screen.dart` — with a model installed: **Start talking** +
  **Add document** (picker → extract/chunk/save with progress + snackbar) +
  **Document library (N)** entry.
- `chat_screen.dart` — retrieves top-5 excerpts per message (never throws;
  degrades to plain chat), shows an "Answering from N library excerpts"
  hint above the input bar.
- `lib/screens/library_screen.dart` (new) — doc list with chunk counts +
  delete, Add-file FAB, semantic-search card (enable flow with embedder
  download + re-index progress dialogs, offline-reranker notice, re-index
  button). `lib/widgets/task_progress_dialog.dart` (new) backs the dialogs.

### Dependencies

- `syncfusion_flutter_pdf: ^35.1.39` (pure Dart, no native code),
  `archive: ^4.3.0`, `xml: ^7.1.0` (direct now), `integration_test`
  (dev, SDK).

### Tests

- `test/chunker_test.dart`, `test/retrieval_test.dart`,
  `test/prompt_builder_test.dart`, `test/text_extractor_test.dart` (incl. a
  syncfusion PDF write→read round-trip and a minimal-docx fixture).
  `flutter analyze` clean, `flutter test` all passing (28 tests).
- `integration_test/library_pipeline_test.dart` — txt+pdf+docx
  add/retrieve/remove on-device.

### On-device validation (SM-A736B, R5CT61HDK8L, 2026-10-08)

- `flutter build apk --debug` OK, `flutter install -d R5CT61HDK8L` OK.
- App launched via adb: resumed in foreground, **zero** `E/flutter`,
  `FATAL EXCEPTION` or assertion errors in logcat.
- `flutter test integration_test/library_pipeline_test.dart -d R5CT61HDK8L`
  → **all passed**: keyword retrieval picks the right file, heuristic
  semantic layer answers a paraphrased query, unrelated query stays silent.

### Known limitations / future work

- Real-embedding semantic path (Gecko download + FFI inference) is
  implemented but NOT yet exercised on-device (needs ~115MB download on the
  phone); the heuristic fallback is what ran in the device test.
- Legacy binary `.doc` unsupported (by design — message shown).
- Chat history still accumulates grounded prompts per turn; with a large
  library context this can press against the 1024-token window over long
  conversations (history truncation is a follow-up).

## Session — Stream-error recovery + LaTeX rendering (2026-10-08)

Symptoms from manual testing on the phone: second query failed with
`FAILED_PRECONDITION: Chosen prefill work group size exceeds available state
entries`, a later query failed with `INTERNAL: Task failed state:7`, and
assistant replies showed raw LaTeX (`\exp`, `\left`) instead of equations.

### Root causes

- The chat ran with `maxTokens: 1024` (default `tokenBuffer: 256`), so a
  single 5-excerpt grounded prompt (~550 tokens) plus reply plus the SDK's
  history trim/replay churn starved prefill → native prefill error. Once the
  native session wedged, every later query failed (state:7) until it was
  recreated.
- Assistant bubbles used plain `SelectableText` — no math rendering.

### Fixes

- `model_service.dart`: context window 1024 → **2048**, `tokenBuffer: 512`
  on `createChat`; new `resetConversation()` (`clearHistory()` with a
  close-and-rebuild fallback, never throws).
- `chat_screen.dart`: new **New-chat AppBar button** (clears messages +
  resets the native conversation); any stream error now triggers a silent
  `resetConversation()` so the next send starts from a fresh session.
- `prompt_builder.dart`: caps tightened (320 chars/excerpt, 1800 total ≈
  ~450 tokens for a full 5-excerpt prompt).
- LaTeX: new `flutter_math_fork: 0.7.4` dep; new
  `lib/services/math_segments.dart` parser (`$…$`, `$$…$$`, `\(…\)`,
  `\[…\]`; lone `$` and unclosed delimiters stay plain); assistant bubbles
  render `Math.tex` with a plain-text fallback; TTS substitutes "formula"
  instead of reading raw commands.
- Dep conflict note: `flutter_math_fork` → `flutter_svg` →
  `vector_graphics_compiler` caps `xml <= 7.0.1`, while
  `syncfusion_flutter_pdf` needs `xml >= 7.0.1`. Relaxed our pin to
  `xml: ">=7.0.1 <8.0.0"` (resolves to exactly 7.0.1); docx/PDF extraction
  unaffected (extractor tests still pass).
- Tests: new `test/math_segments_test.dart` (6 tests). `flutter analyze`
  clean, full suite **34/34 passing**.

### Device re-validation (R5CT61HDK8L)

- Rebuilt, reinstalled, launched: app resumed in foreground, no
  `E/flutter` / `FATAL` / assertion errors in logcat.
- **IMPORTANT reinstall note:** `flutter install` uninstalls the old APK
  first, which **wipes app-private data** — the previously downloaded 2.4GB
  model and any library documents were deleted. The model must be
  re-downloaded on the phone. For future updates use
  `adb install -r app-debug.apk` to preserve data (confirmed working —
  model + library survive).

## Session — Keyword-priority ranking (2026-10-08)

Per user requirement: exact word matches must take priority over
semantically similar results.

- `retrieval.dart` (`rankChunks`): two-tier ordering — every chunk with
  keyword overlap ranks above every semantic-only match; the blended score
  now only orders *within* each tier. Weights rebalanced to
  keyword-dominant (0.65/0.35 embeddings, heuristic capped at 0.3).
  Semantic-only matches still surface when nothing shares keywords
  (paraphrase rescue unchanged).
- New test `exact keyword matches outrank stronger semantic matches`
  (would fail under the old blend). Full suite **35/35 passing**,
  `flutter analyze` clean.
- Rebuilt + `adb install -r` (data preserved), launched clean on
  R5CT61HDK8L, no errors in logcat.

## Session — Slot-fusion ranking: keyword + semantic combined (2026-10-08)

Follow-up to the keyword-priority change: exact matching alone misses
paraphrased context, so both layers now contribute to the top-5.

- `retrieval.dart` (`rankChunks`): replaced two-tier ordering with
  slot-fusion — roughly half the slots go to the best keyword matches, half
  to the best semantic matches (a layer with no candidates yields its slots
  to the other; semantic off = all keyword). Final prompt order is by
  50/50 blended score with exact matches winning ties, so literal context
  still leads without starving semantic matches.
- Tests: reworked the priority test into `combines keyword and semantic
  hits, keyword first on ties`; added `semantic star is included even when
  keyword hits fill slots` (fails under the old tiered code). Full suite
  **36/36 passing**, `flutter analyze` clean.
- Rebuilt + `adb install -r` (model + library preserved), launched clean on
  R5CT61HDK8L, no errors in logcat.

## Session — Fresh prefill per question (2026-10-08)

The prefill-length error returned despite the 2048-token window: accumulated
conversation history in the native KV-cache kept exhausting prefill state.
Per user suggestion, every question now gets a fresh native session.

- `model_service.dart` (`generateResponse`): `clearHistory()` before every
  query, so prefill input is always just the current prompt (~450 tokens
  max for a full 5-excerpt grounded prompt). Tradeoff: the model answers
  each question standalone — no follow-up memory (visible chat history is
  unaffected). Optional follow-up: prepend a bounded recap (e.g. last
  exchange, truncated) to restore single-step memory without unbounded
  growth.
- Full suite **36/36 passing**, `flutter analyze` clean. Rebuilt +
  `adb install -r`, launched clean on R5CT61HDK8L, no errors in logcat.
  Real validation needs manual multi-turn testing on the phone.

## Session — Visible reply sources (2026-10-08)

Manual testing showed wrong answers when switching questions to another
document. Cause unknown (retrieval miss vs. generation miss), so replies now
expose their evidence: each assistant message stores its `RetrievedChunk`s
and shows an expandable **Sources (N)** section with filename + excerpt
text. Full suite **36/36 passing**, `flutter analyze` clean. Rebuilt +
`adb install -r`, launched clean on R5CT61HDK8L, no errors in logcat.
Next: get the failing query + shown sources from the user to pinpoint the
layer at fault.

## Session — Offline content packs, Wikipedia knowledge, offline maps (2026-11-07)

Approved multi-phase feature:
- Small curated "core" content pack bundled in the APK and seeded on first
  launch; larger packs downloaded on demand (user-initiated, with progress).
- Wikipedia/Wikibooks/Wikivoyage pages fetched on demand via the MediaWiki API
  into the existing chunk/embed library; curated original summaries + public
  domain sources for practical/medical/emergency content, with citations and
  disclaimers.
- `flutter_map` offline map viewer with OSM tiles, region downloads, TTL +
  size-capped LRU cleanup (14-day transient TTL, 180-day region TTL, 1 GB cap,
  optional per-region pins).

### Phase 1 — library foundation

- NEW `lib/services/embedding_codec.dart`: little-endian float32
  encode/decode for chunk embeddings; rejects ragged/truncated data.
- `lib/services/knowledge_library.dart`:
  - `LibraryDocument` gains `packId`, `packDocId`, `license`, `sourceUrl`,
    `attribution`, `isBuiltIn`, plus `embeddingFile`/`embeddingDim`/
    `embeddingCount`. All persisted as optional JSON fields (old files load
    unchanged).
  - Embeddings moved out of `library.json` into per-document float32 sidecars
    under `documents/knowledge/embeddings/<id>.f32`; legacy inline
    `embeddings` arrays still parse and migrate on the next save.
  - Embeddings hydrate lazily on the first semantic retrieval, not at startup.
  - NEW `LibraryEntry` + `addDocumentsFromEntries(...)`: batch chunk/embed/
    upsert with progress callbacks and a single library write. Document IDs
    can be stable (`pack:<packId>:<docId>`); same-ID entries replace old ones.
  - NEW `replacePackDocuments(...)` (upserts and drops docs removed from an
    upgraded pack) and `removePack(packId)` (never touches user docs).
  - `addDocumentFromFile(...)` now delegates to the batch path.
  - Sidecars are deleted on document/pack removal and `clear()`.
  - NEW per-revision retrieval index cache: flattened chunks, chunk owners,
    and pre-tokenized chunks are reused until the library revision changes.
  - Semantic retrieval no longer requires *every* document to have
    embeddings: missing vectors contribute an empty vector (cosine 0) so the
    layer still works with partially indexed libraries.
- `lib/services/retrieval.dart`: `keywordScores`/`rankChunks` accept optional
  `tokenizedChunks` so callers can reuse the cached tokenization.
- NEW tests:
  - `test/embedding_codec_test.dart` (4) — round-trip, empty, ragged,
    truncated.
  - `test/library_document_test.dart` (3) — metadata JSON round-trip, legacy
    inline embeddings, user-doc defaults.
  - `test/retrieval_test.dart` +2 — cached tokenization matches fresh scoring;
    partial embeddings disable only the missing chunk.
- Fixed analyzer warning for an unnecessary `!` in the new partial-embedding
  path.
- `flutter analyze` clean; 24 targeted tests passing.

### Phase 2 — bundled + downloadable content packs

- `pubspec.yaml`:
  - Added direct dependencies `http: ^1.5.0` and `crypto: ^3.0.7` (Wikipedia
    downloads and optional SHA-256 verification).
  - Registered `assets: - assets/packs/` so bundled packs ship in the APK.
- NEW `assets/packs/catalog.json`: pack catalog (`core` bundled asset pack,
  `wikipedia-essentials` Wikimedia API pack with size/license/attribution).
- NEW `assets/packs/core_v1.json`: 19 curated core documents (medical
  disclaimer, first aid basics, CPR/AED, choking, severe bleeding, burns,
  heat/cold, water purification, food safety, fire safety, shelter/warmth,
  navigation without GPS, emergency signals, emergency kit,
  hygiene/sanitation, poisoning, severe allergic reaction, weather hazards,
  emergency plan), each with source URL/license/attribution.
- NEW `assets/packs/wikipedia_essentials_titles.json`: ~84 categorized article
  titles (health, science, geography, practical skills, general knowledge).
- NEW `lib/services/wikimedia_client.dart`: MediaWiki Action API
  `prop=extracts&explaintext=1` client; deduplicates titles, fetches one full
  extract per request (the API caps full `exlimit` at 1; multi-title batching
  remains supported and now backfills titles the API omitted), retries
  5xx/429 with backoff, fails fast on other 4xx, strips `missing`/empty
  pages, truncates >20k-char articles at a paragraph boundary, decodes UTF-8
  explicitly, sends a custom User-Agent, dedupes pages across requests.
- NEW `lib/services/content_pack_service.dart`:
  - Models `ContentPack`, `ContentPackDocument`, `ContentPackFile`,
    `ContentPackInstallResult`, `ContentPackSource {asset, wikimedia, url}`.
  - `loadCatalog()` (cached), `seedBundled()` (installs bundled packs once per
    version on launch; remembers explicit removal), `installPack()` (asset,
    Wikipedia, or URL source; optional SHA-256 check; progress mapping),
    `removePack()`, `installedVersion()`.
  - Pack text is ingested through `replacePackDocuments` →
    chunk/embed pipeline with stable IDs `pack:<packId>:<docId>`; metadata
    (license, source URL, attribution, `isBuiltIn`) is preserved.
- `lib/services/knowledge_library.dart`:
  - Batch embedding progress is now chunk-level (`doneChunks`/`totalChunks`)
    so the pack install dialog can show real progress.
  - Added `@visibleForTesting` `debugDocumentsDirectory` and `resetForTest()`
    so pack/seed tests run without the path_provider plugin.
  - `RetrievedChunk` gains optional `sourceUrl` / `license`, populated from the
    owning document, so chat can show citations.
- `lib/screens/offline_content_screen.dart` (NEW):
  - Catalog cards with bundled/installed/update status, size, license and
    chunk counts.
  - Install/reinstall/remove flows with modal progress; optional embedder
    download prompt when semantic search is on; "Install text only" fallback.
  - Per-pack sources/license dialog; global health/emergency disclaimer;
    library totals + "Index now" re-index action.
- `lib/screens/home_screen.dart`: added "Offline content" entry point (also
  available before the model is downloaded); body is now
  `LayoutBuilder` + `SingleChildScrollView` to avoid overflow with the extra
  action.
- `lib/screens/library_screen.dart`: app-bar shortcut to the offline content
  catalog.
- `lib/main.dart`: after FlutterGemma + settings init, calls
  `ContentPackService.instance.seedBundled()` (failure-tolerant) so the
  bundled core pack exists on first launch.
- `lib/screens/chat_screen.dart`: source excerpts now include the original
  URL when known.
- NEW tests:
  - `test/wikimedia_client_test.dart` (7) — parsing/URLs, dedupe, 5xx retry,
    no retry on 403, per-title fallback, incomplete-batch backfill,
    truncation.
  - `test/content_pack_service_test.dart` (8) — catalog parsing, actual
    catalog contents, bundled title asset, first-launch seeding, removal
    remembered across seeds, explicit reinstall, user docs untouched by pack
    removal.
- `flutter analyze` clean; 15 new tests passing (Phase 2 targeted run).

### Phase 3 — offline map viewer + tile cache lifecycle

- `pubspec.yaml`: added `flutter_map: ^8.3.2` and `latlong2: ^0.10.1`
  (`flutter pub add flutter_map latlong2`; pulls dart_earcut, proj4dart,
  uuid, etc. transitively).
- NEW `lib/services/tile_math.dart`: Web-Mercator helpers — lon/lat ↔ tile
  x/y (clamped to valid range/±85.0511°), `TileCoord`/`TileRange`,
  `tileRangeForBounds`, `tileCountForBounds`, cache-key parsing, tile URL
  template substitution, and a ~15 KB/tile size estimate.
- NEW `lib/services/map_service.dart`:
  - `MapRegion` (name, N/S/E/W bounds, zoom range, tile source template,
    downloaded date, tile/byte/failed counts, `keepOffline` pin) with JSON
    round-trip; `formatBytes` helper.
  - Cache root `<appSupport>/map_cache` with `tiles/<sourceId>/<z>/<x>/<y>.tile`,
    `regions.json`, and `tile_access.json`. Source id = first 12 hex chars of
    SHA-1 of the URL template, so switching providers does not mix tiles.
  - `cachedTile`/`fetchTile`/`tileBytes`: cache-first reads, disk writes,
    debounced access-timestamp flushes, shared HTTP client, 20 s timeout,
    identifiable User-Agent, `Accept: image/*`.
  - Downloaded-region flow: enumerates tiles across the zoom range (20k tile
    safety limit), resumes by skipping existing files, 2 workers with an
    80 ms delay, 429-abort handling, progress callback, persists region
    metadata, then triggers cleanup.
  - `setRegionKeepOffline`, `deleteRegion` (drops the region id from shared
    tile access entries; deletes files only when no region still references
    them), `clearCache`.
  - Lifecycle: transient tiles expire after 14 days, downloaded-region tiles
    after 180 days; pinned regions exempt; 1 GB cap with oldest-first
    eviction down to 800 MB; any tile accessed in the last hour is spared.
  - Cleanup scans/deletes in `Isolate.run` via `runMapCacheCleanup`, rewrites
    the access index, and merges access timestamps recorded during the scan.
  - Cleanup hooks: app start (from `main`), map screen resume, after region
    download/pin changes, and every 300 tile writes when over the cap.
  - `@visibleForTesting` root override/reset for tests.
- NEW `lib/services/offline_tile_provider.dart`: flutter_map
  `TileProvider`/`ImageProvider` bridge that loads from `MapService` (cache
  first, then network) and decodes with `ImmutableBuffer`/`decode`.
- NEW `lib/screens/map_screen.dart`:
  - `FlutterMap` viewer (zoom 2–19, world start) with the disk-cached tile
    provider, OSM attribution/policy banner, and current tile-source updates.
  - "Download this area": dialog with region name, live zoom `RangeSlider`,
    tile count/size estimate, 20k-tile guard, and "Keep offline" pin.
  - Downloaded-regions bottom sheet: pin/unpin, delete with confirmation,
    tap to fit camera to bounds, cache size summary, clear-cache action.
  - App lifecycle observer flushes access timestamps on pause and runs
    cleanup on resume.
- `lib/services/settings_service.dart`: persisted `mapTileUrl` notifier
  (default OSM `https://tile.openstreetmap.org/{z}/{x}/{y}.png`), URL
  validation (`{z}`/`{x}`/`{y}` + http(s)) and setter.
- `lib/screens/settings_screen.dart`: "Offline map" section with an editable
  tile URL template, Save/Reset actions, validation, and a policy note.
- `lib/screens/home_screen.dart`: added "Offline map" entry point.
- `lib/main.dart`: after `runApp`, initializes `MapService` (startup TTL/cap
  cleanup) without blocking the first frame; failures are logged.
- `lib/services/content_pack_service.dart`: bundled seeding now only embeds
  when semantic search is enabled *and* the embedder is installed, keeping
  first launch fast.
- `lib/services/knowledge_library.dart`: (Phase 2 support) test directory
  override/reset hook; `RetrievedChunk` source URL/license fields.
- Follow-up hardening:
  - `WikimediaClient` now fetches one full extract per request (the API caps
    full `exlimit` at 1) and backfills any titles a multi-title batch omitted,
    deduping pages across requests; this fixes silently missing articles in
    downloaded Wikipedia packs.
  - `MapService.initialize()` clears its in-flight future on failure so the
    map screen's Retry button can recover; background cap cleanup/access
    flushes are error-guarded (no unhandled async errors).
  - Region-sheet/download paths refresh pack versions after install/remove,
    and pack action rows use `Wrap` to avoid overflow on narrow screens.
- NEW tests:
  - `test/tile_math_test.dart` (8) — world/center/edge mappings, center
    round-trips, ranges/counts, invalid bounds, cache keys, URL substitution.
  - `test/map_cleanup_test.dart` (5) — TTL expiry vs pinned/recent/grace,
    LRU eviction to target, pinned exempt from cap, stale index entries,
    missing directory.
  - `test/map_service_test.dart` (3) — stable source ids, isolate cleanup on
    initialize, region JSON round-trip.
  - `test/content_pack_service_test.dart` +1 — Wikipedia title asset is
    bundled and categorized.
- Ran `dart format` on all touched Dart files.
- Validation: `flutter analyze` clean; full suite **76/76 passing**;
  `flutter build apk` succeeded (`build/app/outputs/flutter-apk/
  app-release.apk`, 168.2 MB).
- On-device smoke test not possible this session: `R5CT61HDK8L` reported
  "not authorized" (USB debugging prompt pending on the phone). Next: accept
  the prompt and verify map browsing, region download, pin/delete, and
  startup cleanup on the device.
- Caveats: default OSM tiles are subject to the OSM tile usage policy (UI
  notes this; template is configurable). Tile templates support `{z}/{x}/{y}`
  only. Region metadata is kept until manually deleted; only its tiles are
  TTL-expired. Overlapping regions share tile references; deleting one keeps
  tiles another region still uses.

### Session - OSM block diagnosis, final hardening, device checks, report

- Device `R5CT61HDK8L` became authorized. Installed an earlier build and
  verified: app launch, local model chat, core pack seeding (`Document
  library (23)`), chat grounding (`Answering from 5 library excerpts`), map
  rendering with OpenStreetMap.de (Bhopal), and a 312-tile region download
  (progress observed; region-list completion not conclusively confirmed).
- Diagnosed map tile failure: `tile.openstreetmap.org` returned HTTP 200 with
  an `x-blocked` header and an "Access blocked" PNG. The app had been caching
  it as a tile. Root cause and fixes:
  - `MapService.defaultTileUrl` now
    `https://tile.openstreetmap.de/{z}/{x}/{y}.png`; added
    `legacyOsmTileUrl` for migration.
  - `SettingsService.load` migrates the exact legacy URL to the new default.
  - `MapService.fetchTile` rejects non-image content types and any non-empty
    `x-blocked` header; empty bodies are rejected.
  - `MapService._requestTile` retries network errors, HTTP 429, and HTTP 5xx
    once after 400 ms (2 attempts, 20 s timeout each); permanent 4xx fails
    immediately.
  - `MapService.userAgent` now includes the public project URL; Wikimedia UA
    updated similarly.
  - `MapScreen` bottom controls use
    `bottom: 16 + MediaQuery.paddingOf(context).bottom` so they clear the
    Android navigation bar.
  - Settings UI text now says OSM.de and "Reset to OSM.de"; map attribution
    identifies `tile.openstreetmap.de`.
- Wikimedia fix retained: full extracts are fetched one title per request,
  omitted titles are backfilled individually, and pages are deduped across
  requests (MediaWiki full `exlimit` is 1).
- Added test seams: `MapService.debugHttpClient`. New tests:
  - `test/map_service_test.dart` +2 - retries 503 then caches image; rejects
    `x-blocked` responses without caching (now 5 tests).
  - `test/settings_service_test.dart` (5) - default OSM.de, legacy migration,
    custom URL preserved, invalid URL falls back, setter persists.
  - Extended `integration_test/library_pipeline_test.dart` with a second test
    for bundled catalog loading and map-cache initialization.
- Validation: `flutter analyze` clean; full suite **83/83 passing**;
  `flutter build apk` succeeded (168.2 MB, 176,379,232 bytes).
- Final install attempt failed because ADB reported no attached device
  (`adb devices` empty). Therefore safe-area controls, downloaded-regions
  sheet, region persistence, airplane mode, Wikipedia pack install, and
  embedder indexing remain unverified on device.
- Added `REPORT.md` using the exact `SAMPLE_REPORT.md` headings, with project
  subheadings, 55 references, 14 tables, 6 Mermaid figures, test/build/device
  results, and an attribution matrix. `SAMPLE_REPORT.md` remains untracked.
- Updated `AGENTS.md` map default and test/report structure. All changes remain
  uncommitted. Security follow-up: rotate the GitHub credential currently
  embedded in the git remote URL; do not commit it.



