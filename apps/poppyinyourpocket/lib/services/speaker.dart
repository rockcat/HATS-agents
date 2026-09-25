/// Making Poppy speak, from the device or from the server.
///
/// Two ways, one interface, because the choice is a trade and neither side
/// wins outright:
///
/// **Device** — the platform voice. Instant, free, works with no connection,
/// and the phone already has it. But Android and iOS report only *which word*
/// they are speaking and when, so the mouth is driven from spelling
/// ([visemesForWord]) rather than from real phonemes.
///
/// **Server** — Piper, through the Embodiment API. Real phoneme timings from
/// Rhubarb, the same voice on every client, and a voice the operator chose.
/// But it needs the connection, a round trip per sentence, and the audio over
/// the wire.
///
/// Nothing on the server has to change to support either: speech over the
/// Embodiment API is something a client *asks* for, so a client that speaks
/// locally simply never calls `/speech`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'embodiment_client.dart';
import 'viseme_estimator.dart';

enum SpeechMode {
  /// The platform voice. No connection needed, approximate lip sync.
  device,

  /// Piper, through the runner. Accurate lip sync, needs the connection.
  server,

  /// Poppy has a face but stays quiet.
  off,
}

/// Called as each piece of speech starts, with the mouth shapes for it.
typedef LipSync = void Function(List<Map<String, dynamic>> visemes);

abstract class Speaker {
  /// Say one sentence, returning when it has been spoken.
  Future<void> speak(String text);

  /// Stop mid-sentence — Poppy talking over you is worse than silence.
  Future<void> stop();

  Future<void> dispose();
}

/// The platform's own voice.
class DeviceSpeaker implements Speaker {
  final FlutterTts _tts;
  final LipSync onLipSync;

  /// Filled in as the platform reports word boundaries, so the mouth follows
  /// the word actually being said rather than a guess at the pacing.
  DateTime? _utteranceStart;
  String? _spoken;

  DeviceSpeaker({required this.onLipSync, FlutterTts? tts}) : _tts = tts ?? FlutterTts() {
    _tts.setProgressHandler((text, start, end, word) {
      final began = _utteranceStart;
      if (began == null || word.trim().isEmpty) return;
      final elapsed = DateTime.now().difference(began).inMilliseconds / 1000.0;
      // The platform says a word has started but not how long it will take, so
      // estimate from its length at a typical speaking rate.
      final span = _estimateWordDuration(word);
      onLipSync(
        visemesForWord(word, start: elapsed, end: elapsed + span).map((v) => v.toJson()).toList(),
      );
    });
  }

  /// Roughly 13 characters a second, the middle of conversational English.
  static double _estimateWordDuration(String word) =>
      (word.length / 13.0).clamp(0.12, 1.2);

  Future<void> configure({String? language, double? rate, double? pitch}) async {
    if (language != null) await _tts.setLanguage(language);
    if (rate != null) await _tts.setSpeechRate(rate);
    if (pitch != null) await _tts.setPitch(pitch);
    await _tts.awaitSpeakCompletion(true);
  }

  /// The voices the device offers, for the settings screen.
  Future<List<String>> voices() async {
    final raw = await _tts.getVoices as List<dynamic>? ?? [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map((v) => v['name']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
  }

  Future<void> useVoice(String name, String locale) =>
      _tts.setVoice({'name': name, 'locale': locale});

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    _spoken = text;
    _utteranceStart = DateTime.now();
    // If the platform never reports a word, the mouth still moves: the whole
    // sentence is estimated up front and refined by any progress that arrives.
    onLipSync(visemesForSentence(text, duration: _estimateSentenceDuration(text))
        .map((v) => v.toJson())
        .toList());
    await _tts.speak(text);
    _utteranceStart = null;
  }

  static double _estimateSentenceDuration(String text) => (text.length / 13.0).clamp(0.4, 30.0);

  /// What was last said, for a retry after a voice change.
  String? get lastSpoken => _spoken;

  @override
  Future<void> stop() async {
    _utteranceStart = null;
    await _tts.stop();
  }

  @override
  Future<void> dispose() => _tts.stop();
}

/// Piper, by way of the runner.
class ServerSpeaker implements Speaker {
  final EmbodimentClient client;
  final String agentId;
  final LipSync onLipSync;
  final AudioPlayer _player;

  ServerSpeaker({
    required this.client,
    required this.agentId,
    required this.onLipSync,
    AudioPlayer? player,
  }) : _player = player ?? AudioPlayer();

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    final chunks = await client.speech(agentId, text);
    // Sentence at a time, in order: the server renders them as it goes, and
    // waiting for the whole utterance would throw that away.
    for (final chunk in chunks) {
      final audio = chunk['audioBase64'] as String?;
      if (audio == null) continue;
      final visemes = (chunk['visemes'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      onLipSync(visemes);
      await _player.play(BytesSource(base64Decode(audio)));
      await _player.onPlayerComplete.first;
    }
  }

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}

/// Speaks nothing, so the rest of the app need not care.
class SilentSpeaker implements Speaker {
  const SilentSpeaker();
  @override
  Future<void> speak(String text) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}
