import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../services/model_service.dart';
import '../services/settings_service.dart';
import 'settings_screen.dart';

/// Chat interface that streams responses from the locally running Gemma 4 E2B.
/// Supports typed or voice (mic) input and optional text-to-speech replies.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<_Message> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isGenerating = false;
  String _bufferedReply = '';

  final SpeechToText _speech = SpeechToText();
  bool _isListening = false;
  bool _speechAvailable = false;

  final FlutterTts _tts = FlutterTts();

  @override
  void initState() {
    super.initState();
    _initModel();
    _initSpeech();
    _initTts();
  }

  Future<void> _initModel() => _ensureModelLoaded();

  /// Ensures the model is loaded into memory before we try to use it, guarding
  /// against the "Model is not loaded" state that happens when the chat screen
  /// is opened before the load completes (or after a hot restart).
  Future<void> _ensureModelLoaded() async {
    try {
      if (!ModelService.instance.isChatReady) {
        await ModelService.instance.loadModelForChat();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load model: $e')),
        );
      }
    }
  }

  Future<void> _initSpeech() async {
    _speechAvailable = await _speech.initialize();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
  }

  @override
  void dispose() {
    _speech.stop();
    _tts.stop();
    _controller.dispose();
    _scrollController.dispose();
    ModelService.instance.disposeModel();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  Future<void> _speak(String text) async {
    if (!SettingsService.instance.ttsEnabled.value) return;
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {
      // TTS is best-effort; ignore failures (e.g. no engine installed).
    }
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speech.stop();
      if (mounted) {
        setState(() => _isListening = false);
      }
      return;
    }
    if (!_speechAvailable) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Speech recognition is unavailable')),
        );
      }
      return;
    }
    setState(() => _isListening = true);
    await _speech.listen(
      onResult: _onSpeechResult,
      listenOptions: SpeechListenOptions(
        partialResults: false,
        cancelOnError: true,
        localeId: 'en_US',
      ),
    );
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    final localeResult = result.recognizedWords.trim();
    if (localeResult.isEmpty || !result.finalResult) return;
    if (!mounted) return;
    setState(() => _isListening = false);
    _sendText(localeResult);
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    _sendText(text);
  }

  Future<void> _sendText(String text) async {
    if (_isGenerating) return;

    try {
      await _ensureModelLoaded();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Model not ready: $e')),
        );
      }
      return;
    }

    setState(() {
      _messages.add(_Message(text: text, isUser: true));
      _bufferedReply = '';
      _isGenerating = true;
    });
    _scrollToBottom();

    try {
      final stream = ModelService.instance.generateResponse(text);
      await for (final chunk in stream) {
        if (!mounted) return;
        setState(() {
          _bufferedReply += chunk;
          if (_messages.isNotEmpty && !_messages.last.isUser) {
            _messages.last = _Message(text: _bufferedReply, isUser: false);
          } else {
            _messages.add(_Message(text: _bufferedReply, isUser: false));
          }
        });
        _scrollToBottom();
      }
      // Once the reply finishes streaming, read it aloud if audio is on.
      final reply = _bufferedReply.trim();
      if (reply.isNotEmpty) {
        unawaited(_speak(reply));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (_messages.isNotEmpty && !_messages.last.isUser) {
            _messages.last = _Message(text: 'Error: $e', isUser: false);
          } else {
            _messages.add(_Message(text: 'Error: $e', isUser: false));
          }
        });
      }
    }

    if (mounted) {
      setState(() => _isGenerating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final micColor = _isListening ? Colors.red : null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gemma 4 E2B Chat'),
        // Automatic back arrow appears because this screen is pushed onto the
        // navigation stack from the home screen.
        actions: [
          // Voice reply toggle indicator (shows whether audio is on).
          ValueListenableBuilder<bool>(
            valueListenable: SettingsService.instance.ttsEnabled,
            builder: (context, ttsOn, _) {
              return IconButton(
                icon: Icon(ttsOn ? Icons.volume_up : Icons.volume_off),
                tooltip: ttsOn ? 'Voice replies on' : 'Voice replies off',
                onPressed: () {
                  SettingsService.instance
                      .setTtsEnabled(!ttsOn)
                      .then((_) => _tts.stop());
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text(
                      'Ask me anything!\nModel runs 100% on-device.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) =>
                        _MessageBubble(message: _messages[index]),
                  ),
          ),
          _InputBar(
            controller: _controller,
            enabled: !_isGenerating,
            onSend: _send,
            onMic: _toggleListening,
            isListening: _isListening,
            micColor: micColor,
            speechAvailable: _speechAvailable,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

class _Message {
  const _Message({required this.text, required this.isUser});
  final String text;
  final bool isUser;
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});
  final _Message message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: SelectableText(
          message.text,
          style: TextStyle(
            color: isUser
                ? Theme.of(context).colorScheme.onPrimaryContainer
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.enabled,
    required this.onSend,
    required this.onMic,
    required this.isListening,
    required this.micColor,
    required this.speechAvailable,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onMic;
  final bool isListening;
  final Color? micColor;
  final bool speechAvailable;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            IconButton(
              onPressed: speechAvailable ? onMic : null,
              icon: Icon(isListening ? Icons.mic : Icons.mic_none),
              color: micColor,
              tooltip: 'Talk',
            ),
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: isListening ? 'Listening...' : 'Type a message...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: enabled ? onSend : null,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
