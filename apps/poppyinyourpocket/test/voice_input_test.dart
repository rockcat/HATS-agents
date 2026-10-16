/// Talking to Poppy instead of typing.
///
/// The platform recogniser is behind a seam, so these cover what is ours: that
/// nothing heard is silently dropped, that a refusal is explained rather than
/// looking like a dead button, and that the state the UI follows is honest.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:poppy/services/voice_input.dart';

/// A recogniser that does what the test tells it to.
class _FakeRecogniser implements Recogniser {
  bool usable = true;
  bool throwOnInit = false;
  bool throwOnListen = false;

  int listens = 0;
  int stops = 0;
  int cancels = 0;
  int initialisations = 0;

  void Function(String, bool)? _onResult;
  void Function(String)? _onError;

  @override
  Future<bool> initialise() async {
    initialisations++;
    if (throwOnInit) throw Exception('no recogniser');
    return usable;
  }

  @override
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    required void Function(String error) onError,
  }) async {
    if (throwOnListen) throw Exception('mic busy');
    listens++;
    _onResult = onResult;
    _onError = onError;
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> cancel() async => cancels++;

  /// Pretend the platform heard something.
  void hear(String text, {bool isFinal = false}) => _onResult?.call(text, isFinal);
  void fail(String error) => _onError?.call(error);
}

void main() {
  late _FakeRecogniser recogniser;
  late List<String> heard;
  late List<Hearing> states;
  late List<String> errors;
  late VoiceInput voice;

  setUp(() {
    recogniser = _FakeRecogniser();
    heard = [];
    states = [];
    errors = [];
    voice = VoiceInput(
      recogniser: recogniser,
      onHeard: (text, _) => heard.add(text),
      onState: states.add,
      onError: errors.add,
    );
  });

  group('listening', () {
    test('opens the microphone when asked', () async {
      await voice.start();

      expect(recogniser.listens, 1);
      expect(voice.isListening, isTrue);
      expect(states, [Hearing.listening]);
    });

    test('shows what it heard before it is sure', () async {
      // A box that stays empty while you talk reads as a microphone that is
      // not working.
      await voice.start();
      recogniser.hear('what is');
      recogniser.hear('what is the');
      recogniser.hear('what is the time', isFinal: true);

      expect(heard, ['what is', 'what is the', 'what is the time']);
    });

    test('settles by itself when the recogniser finishes', () async {
      await voice.start();
      recogniser.hear('done', isFinal: true);

      expect(voice.isListening, isFalse);
      expect(voice.heard, 'done');
    });

    test('keeps what it heard when stopped mid-sentence', () async {
      await voice.start();
      recogniser.hear('half a thought');

      expect(await voice.stop(), 'half a thought');
    });

    test('does not let an empty final result erase what was heard', () async {
      // The recogniser sometimes settles on nothing after hearing something,
      // and throwing the sentence away at that point is the worst outcome.
      await voice.start();
      recogniser.hear('something real');
      recogniser.hear('', isFinal: true);

      expect(voice.heard, 'something real');
    });

    test('ignores a second start while already listening', () async {
      await voice.start();
      await voice.start();

      expect(recogniser.listens, 1);
    });

    test('forgets the last utterance when a new one starts', () async {
      await voice.start();
      recogniser.hear('first', isFinal: true);
      await voice.start();

      expect(voice.heard, isEmpty);
    });
  });

  group('giving up on an utterance', () {
    test('throws away what was heard', () async {
      await voice.start();
      recogniser.hear('never mind');
      await voice.cancel();

      expect(voice.heard, isEmpty);
      expect(recogniser.cancels, 1);
      expect(voice.isListening, isFalse);
    });

    test('does nothing when not listening', () async {
      await voice.cancel();
      expect(recogniser.cancels, 0);
    });

    test('survives a recogniser that throws on the way down', () async {
      await voice.start();
      await expectLater(voice.cancel(), completes);
    });
  });

  group('when it cannot hear', () {
    test('says so rather than failing silently', () async {
      // Silence here is what makes a mic button look broken.
      recogniser.usable = false;
      await voice.start();

      expect(errors.single, contains('no speech recognition'));
      expect(voice.isListening, isFalse);
    });

    test('explains a refused permission in terms of the fix', () async {
      await voice.start();
      recogniser.fail('error_permission denied');

      expect(errors.single, contains('permission'));
      expect(voice.isListening, isFalse);
    });

    test('does not dress up not having caught something as a failure', () async {
      await voice.start();
      recogniser.fail('error_no_match');

      expect(errors.single, "Didn't catch that.");
    });

    test('reports a recogniser that will not start', () async {
      recogniser.throwOnListen = true;
      await voice.start();

      expect(errors.single, contains('Could not start listening'));
      expect(voice.isListening, isFalse);
    });

    test('treats a throwing initialise as simply unavailable', () async {
      recogniser.throwOnInit = true;

      expect(await voice.isAvailable(), isFalse);
    });

    test('asks the platform once, not on every press', () async {
      // Initialising prompts for permission the first time.
      await voice.isAvailable();
      await voice.isAvailable();
      await voice.start();

      expect(recogniser.initialisations, 1);
    });
  });

  lateResults();

  group('the state the button follows', () {
    test('passes through settling on the way down', () async {
      await voice.start();
      states.clear();
      await voice.stop();

      expect(states, [Hearing.settling, Hearing.idle]);
    });

    test('does not repeat a state it is already in', () async {
      await voice.start();
      await voice.start();

      expect(states, [Hearing.listening]);
    });

    test('is idle before anything happens', () {
      expect(voice.state, Hearing.idle);
      expect(voice.isListening, isFalse);
    });
  });
}

// ── After the utterance is over ──────────────────────────────────────────────
//
// The platform recogniser usually delivers its final result a beat after stop()
// returns. Anything still listening to it then will act on words the user has
// already sent — in the app, by writing them back into a box that was just
// cleared.

void lateResults() {
  late _FakeRecogniser recogniser;
  late List<String> heard;
  late VoiceInput voice;

  // Inside the group, not beside it: a setUp registered at file scope runs
  // for every test in the file, including the other groups' own.
  group('a result that arrives after we stopped', () {
    setUp(() {
      recogniser = _FakeRecogniser();
      heard = [];
      voice = VoiceInput(recogniser: recogniser, onHeard: (text, _) => heard.add(text));
    });
    test('is ignored, so it cannot undo what the caller did next', () async {
      await voice.start();
      recogniser.hear('send this');
      await voice.stop();
      heard.clear();

      // The platform catching up, after the caller has sent and cleared.
      recogniser.hear('send this', isFinal: true);

      expect(heard, isEmpty);
    });

    test('still counts while the stop is settling', () async {
      // The last word genuinely does land after stop() is called, and losing
      // it would mean losing the end of every sentence.
      final slow = _SlowStopRecogniser();
      final settling = <String>[];
      final v = VoiceInput(recogniser: slow, onHeard: (text, _) => settling.add(text));

      await v.start();
      final stopping = v.stop();
      slow.hear('the last word', isFinal: true);
      await stopping;

      expect(settling, contains('the last word'));
      expect(v.heard, 'the last word');
    });

    test('is ignored after a cancel too', () async {
      await voice.start();
      await voice.cancel();
      heard.clear();

      recogniser.hear('too late', isFinal: true);

      expect(heard, isEmpty);
      expect(voice.heard, isEmpty);
    });

    test('does not resurrect text for the next utterance', () async {
      await voice.start();
      recogniser.hear('first thing');
      await voice.stop();
      recogniser.hear('first thing', isFinal: true); // late

      await voice.start();

      expect(voice.heard, isEmpty);
    });
  });
}

/// A recogniser whose stop takes a moment, like the real one.
class _SlowStopRecogniser extends _FakeRecogniser {
  @override
  Future<void> stop() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return super.stop();
  }
}
