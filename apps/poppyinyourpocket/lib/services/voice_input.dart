/// Hearing what you say, on the device.
///
/// This is the platform recogniser — Android's `SpeechRecognizer`, iOS's
/// `Speech` framework — not Whisper. It is a weaker transcriber on hard audio,
/// and in exchange it is free, immediate, and nothing leaves the phone. For an
/// assistant you talk to in a kitchen that is the right trade; the dashboard's
/// Whisper button is there when accuracy matters more than privacy.
///
/// Two things shape the design:
///
///  * **Partial results are shown, not hidden.** Recognition takes a second or
///    two to settle, and a box that stays empty while you talk reads as a
///    microphone that is not working.
///  * **Never silently drop what was heard.** If recognition ends without a
///    final result, whatever partial text existed is still what you said.
library;

import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart';

/// What the listener is doing.
enum Hearing {
  /// Not listening.
  idle,

  /// Microphone open.
  listening,

  /// Asked to stop; waiting for the recogniser's last word.
  settling,
}

/// The platform recogniser, behind a seam so a test needs no binding.
abstract class Recogniser {
  Future<bool> initialise();
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String error) onError,
  });
  Future<void> stop();
  Future<void> cancel();
}

class _PlatformRecogniser implements Recogniser {
  final SpeechToText _speech = SpeechToText();

  @override
  Future<bool> initialise() => _speech.initialize(
        onError: (_) {},
        onStatus: (_) {},
      );

  @override
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String error) onError,
  }) =>
      _speech.listen(
        onResult: (r) => onResult(r.recognizedWords, r.finalResult),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          // Long enough for a sentence with a pause in it. The defaults cut
          // people off mid-thought.
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 4),
        ),
      );

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();
}

/// Listens on request and reports what it heard.
class VoiceInput {
  final Recogniser _recogniser;

  /// Called as recognition improves, and once more when it settles.
  final void Function(String text, bool isFinal)? onHeard;

  /// Called when the listener's state changes, so the UI can follow.
  final void Function(Hearing state)? onState;

  /// Called when something went wrong, in words a person can act on.
  final void Function(String message)? onError;

  Hearing _state = Hearing.idle;
  bool? _usable;
  String _heard = '';

  VoiceInput({
    Recogniser? recogniser,
    this.onHeard,
    this.onState,
    this.onError,
  }) : _recogniser = recogniser ?? _PlatformRecogniser();

  Hearing get state => _state;
  bool get isListening => _state != Hearing.idle;

  /// Whatever has been recognised so far in the current utterance.
  String get heard => _heard;

  /// Is there a usable recogniser on this device?
  ///
  /// Cached: initialising prompts for permission the first time, and asking
  /// repeatedly is both slow and rude.
  Future<bool> isAvailable() async {
    if (_usable != null) return _usable!;
    try {
      return _usable = await _recogniser.initialise();
    } on Object {
      return _usable = false;
    }
  }

  /// Start listening. Does nothing if already listening.
  Future<void> start() async {
    if (_state != Hearing.idle) return;

    if (!await isAvailable()) {
      onError?.call('This device has no speech recognition available, '
          'or microphone permission was refused.');
      return;
    }

    _heard = '';
    _setState(Hearing.listening);
    try {
      await _recogniser.listen(onResult: _onResult, onError: _onPlatformError);
    } on Object catch (err) {
      _setState(Hearing.idle);
      onError?.call('Could not start listening: $err');
    }
  }

  /// Stop, and settle on what was heard.
  ///
  /// Returns the final text, which may be what the recogniser had settled on
  /// already — it often finishes before the stop lands.
  Future<String> stop() async {
    if (_state == Hearing.idle) return _heard;
    _setState(Hearing.settling);
    try {
      await _recogniser.stop();
    } on Object {
      // Stopping is advisory. What was heard still counts.
    }
    _setState(Hearing.idle);
    return _heard;
  }

  /// Give up on this utterance and throw away what was heard.
  Future<void> cancel() async {
    if (_state == Hearing.idle) return;
    try {
      await _recogniser.cancel();
    } on Object {
      // Same: the point is to stop, not to report on stopping.
    }
    _heard = '';
    _setState(Hearing.idle);
  }

  void _onResult(String text, bool isFinal) {
    // A final result that is empty does not erase a partial one: the
    // recogniser sometimes settles on nothing after hearing something.
    if (text.isNotEmpty) _heard = text;
    onHeard?.call(_heard, isFinal);
    if (isFinal && _state == Hearing.listening) _setState(Hearing.idle);
  }

  void _onPlatformError(String error) {
    final friendly = error.contains('permission')
        ? 'Microphone permission was refused, so Poppy cannot hear you.'
        : error.contains('no_match') || error.contains('speech_timeout')
            ? "Didn't catch that."
            : 'Speech recognition failed: $error';
    _setState(Hearing.idle);
    onError?.call(friendly);
  }

  void _setState(Hearing next) {
    if (_state == next) return;
    _state = next;
    onState?.call(next);
  }
}
