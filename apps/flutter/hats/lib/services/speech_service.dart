import 'dart:convert';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'api_service.dart';

class SpeechService {
  final ApiService _api;
  final AudioPlayer _player = AudioPlayer();
  final FlutterTts _tts = FlutterTts();
  bool _serverAvailable = false;
  bool _cancelled = false;

  /// Called after audio playback starts for each chunk.
  /// Receives (agentName, rawVisemeList) so the caller can drive lip sync.
  void Function(String agentName, List<dynamic> visemes)? onLipSync;

  SpeechService(this._api);

  bool get available => true;

  Future<void> init() async {
    try {
      final voices = await _api.getVoices();
      _serverAvailable = voices.isNotEmpty;
    } catch (_) {
      _serverAvailable = false;
    }
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
  }

  Future<void> speak(
    String text, {
    required String agentName,
    String? voice,
    String? speakerName,
  }) async {
    _cancelled = true;
    await _player.stop();
    await _tts.stop();
    _cancelled = false;

    if (_serverAvailable) {
      await _speakServer(text, agentName: agentName, voice: voice, speakerName: speakerName);
    } else {
      await _tts.speak(text);
    }
  }

  Future<void> _speakServer(
    String text, {
    required String agentName,
    String? voice,
    String? speakerName,
  }) async {
    // (bytes, durationSeconds, visemes) queued from the stream
    final queue = <(Uint8List, double, List<dynamic>)>[];
    bool streamDone = false;

    final fillFuture = () async {
      try {
        await for (final chunk in _api.synthesiseSpeech(
          text,
          voice: voice,
          speakerName: speakerName,
        )) {
          if (_cancelled) return;
          final audio = chunk['audioBase64'] as String?;
          if (audio != null && audio.isNotEmpty) {
            final dur = (chunk['duration'] as num?)?.toDouble() ?? 0.0;
            final vis = (chunk['visemes'] as List<dynamic>?) ?? [];
            queue.add((Uint8List.fromList(base64Decode(audio)), dur, vis));
          }
        }
      } finally {
        streamDone = true;
      }
    }();

    while (!_cancelled) {
      if (queue.isNotEmpty) {
        final (bytes, duration, visemes) = queue.removeAt(0);
        await _player.play(BytesSource(bytes));
        // Always fire — empty list triggers fallback animation in the WebView.
        onLipSync?.call(agentName, visemes);
        if (duration > 0) {
          await Future.delayed(Duration(milliseconds: (duration * 1000).toInt()));
        }
      } else if (streamDone) {
        break;
      } else {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }

    if (_cancelled) await _player.stop();
    await fillFuture;
  }

  Future<void> stop() async {
    _cancelled = true;
    await _player.stop();
    await _tts.stop();
  }

  Future<void> dispose() async {
    _cancelled = true;
    await _player.dispose();
    await _tts.stop();
  }
}
