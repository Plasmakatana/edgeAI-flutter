import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Gemma 4 E2B model (4-bit quantized `litertlm` bundle, ~2.4GB).
///
/// Hosted on HuggingFace by the litert-community org. This is the officially
/// supported on-device format: 4-bit quantization is baked in, and it runs on
/// CPU/GPU/NPU. The file is NOT gated.
const String kGemma4E2BModelUrl =
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';

const String kGemma4E2BModelFileName = 'gemma-4-E2B-it.litertlm';

/// Manages the lifecycle of the Gemma 4 E2B model in the app: downloading it,
/// locating an existing model on device, storing it in app-private storage,
/// and loading it for chat.
class ModelService {
  ModelService._();

  /// Global singleton.
  static final ModelService instance = ModelService._();

  /// The loaded chat, reusable across the chat screen's lifetime.
  InferenceChat? _chat;

  /// The loaded model, cached so we don't reload weights each turn.
  InferenceModel? _model;

  bool get isChatReady => _chat != null;

  /// Whether a Gemma E2B model is already installed (downloaded or located).
  Future<bool> isModelInstalled() async {
    final installed = await FlutterGemma.listInstalledModels();
    return installed.contains(kGemma4E2BModelFileName);
  }

  /// Installs the Gemma 4 E2B model from the network, reporting download
  /// progress (0-100) via [onProgress].
  ///
  /// Idempotent: if the model is already installed the download is skipped and
  /// this returns immediately (after null progress of 100).
  Future<void> downloadAndInstallModel({
    required void Function(int progress) onProgress,
  }) async {
    await FlutterGemma.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    )
        .fromNetwork(
          kGemma4E2BModelUrl,
          foreground: true, // Android foreground service -> no 9-min timeout
        )
        .withProgress(onProgress)
        .install();
  }

  /// Prompts the user to pick a Gemma 4 E2B model file from the device, then
  /// copies it into app-private storage and registers it so it can be used.
  ///
  /// Returns the chosen file name, or null if the user cancelled.
  Future<String?> locateAndInstallModel() async {
    final result = await FilePicker.pickFile(
      dialogTitle: 'Locate Gemma 4 E2B model (.litertlm)',
      type: FileType.custom,
      allowedExtensions: ['litertlm', 'bin', 'task'],
    );
    if (result == null) {
      return null; // user cancelled
    }

    // Copy the picked file into app-private storage. On Android the picker
    // returns a content:// URI cache file whose path is not guaranteed to be
    // stable or durable, so we always copy into the app's documents dir.
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docsDir.path, 'models'));
    await dir.create(recursive: true);

    final targetName =
        result.name.endsWith('.litertlm') ? result.name : kGemma4E2BModelFileName;
    final targetPath = p.join(dir.path, targetName);
    final target = File(targetPath);
    if (!await target.exists()) {
      await result.xFile.saveTo(targetPath);
    }

    await FlutterGemma.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    )
        .fromFile(targetPath)
        .install();

    return targetName;
  }

  /// Loads the configured active model and prepares a chat session.
  ///
  /// Must be called after either [downloadAndInstallModel] or
  /// [locateAndInstallModel] has registered an active model.
  Future<void> loadModelForChat() async {
    if (_chat != null) {
      return;
    }

    // maxTokens is the CONTEXT WINDOW (KV-cache budget), not the reply length.
    // We cap output via maxOutputTokens on the session instead. For a 2B
    // model on 4-5GB RAM a 1024-token context is a safe, memory-friendly
    // default.
    _model = await FlutterGemma.getActiveModel(
      maxTokens: 1024,
      preferredBackend: PreferredBackend.gpu, // falls back to CPU gracefully
      maxConcurrentSessions: 1,
    );

    _chat = await _model!.createChat(
      maxOutputTokens: 512, // cap reply length to keep generation bounded
      supportsFunctionCalls: true,
      toolChoice: ToolChoice.none,
      systemInstruction:
          'You are a helpful, concise AI assistant running fully on-device. '
          'Answer the user\'s questions directly and to the point.',
    );
  }

  /// Streams the model's reply to [query], token by token.
  Stream<String> generateResponse(String query) async* {
    if (_chat == null) {
      throw StateError('Model is not loaded. Call loadModelForChat() first.');
    }
    await _chat!.addQueryChunk(Message.text(text: query, isUser: true));
    await for (final response in _chat!.generateChatResponseAsync()) {
      if (response is TextResponse) {
        yield response.token;
      } else if (response is ThinkingResponse) {
        // Ignore thinking tokens for a plain chat UI.
        continue;
      }
    }
  }

  /// Clears the in-memory model/chat so the app can reload a new model.
  Future<void> disposeModel() async {
    await _chat?.close();
    await _model?.close();
    _chat = null;
    _model = null;
  }
}
