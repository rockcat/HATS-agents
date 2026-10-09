import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:poppy/models/embodied_agent.dart';
import 'package:poppy/providers/poppy_state.dart';
import 'package:poppy/services/embodiment_client.dart';
import 'package:poppy/services/pairing_service.dart';
import 'package:poppy/services/speaker.dart';

/// Stands in for whichever voice is selected, recording what it was asked to say.
class _RecordingSpeaker implements Speaker {
  final List<String> spoken = [];
  int stops = 0;
  bool throws = false;

  @override
  Future<void> speak(String text) async {
    if (throws) throw Exception('no voice');
    spoken.add(text);
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async {}
}

class _QuietClient extends EmbodimentClient {
  _QuietClient() : super(baseUrl: 'http://test', apiKey: 'k', httpClient: http.Client());
  @override
  Future<void> send(String id, String content, {String thread = 'general'}) async {}
  @override
  Future<List<EmbodiedAgent>> agents() async => [];
}

class _MemoryPairing extends PairingService {
  @override
  Future<Pairing?> load() async => null;
  @override
  Future<void> save(Pairing p) async {}
  @override
  Future<void> saveAgentId(String id) async {}
  @override
  Future<String> deviceId() async => 'test-device';
  @override
  Future<void> forget() async {}
}

void main() {
  late _RecordingSpeaker speaker;
  late PoppyState state;
  late List<SpeechMode> built;

  setUp(() async {
    speaker = _RecordingSpeaker();
    built = [];
    state = PoppyState(
      pairing: _MemoryPairing(),
      clientFactory: (_) => _QuietClient(),
      speakerFactory: (mode, _) {
        built.add(mode);
        return mode == SpeechMode.off ? const SilentSpeaker() : speaker;
      },
    );
    await state.completePairing(
      const Pairing(serverUrl: 'http://test', apiKey: 'k', username: 'paul'),
    );
    await state.chooseAgent(const EmbodiedAgent(id: 'a1', name: 'Poppy'));
  });

  group('choosing where the voice comes from', () {
    test('does not build a voice until one is asked for', () {
      // Constructing the platform TTS plugin reaches for a binding, so nothing
      // should touch it just because an agent was chosen.
      expect(built, isEmpty);
    });

    test('defaults to the device — instant, and works with no connection', () {
      expect(state.speechMode, SpeechMode.device);
    });

    test('rebuilds the voice when the mode changes', () async {
      await state.setSpeechMode(SpeechMode.server);
      expect(built, [SpeechMode.server]);
      await state.setSpeechMode(SpeechMode.device);
      expect(built, [SpeechMode.server, SpeechMode.device]);
    });
  });

  group('speaking a reply', () {
    Future<void> replyArrives(String content) async {
      // What the SSE stream delivers when Poppy answers.
      state.handleEventForTest('agent_message', {
        'agentId': 'a1',
        'role': 'assistant',
        'content': content,
        'timestamp': DateTime.now().toIso8601String(),
      });
      await Future<void>.delayed(Duration.zero);
    }

    test('says it out loud', () async {
      await state.setSpeechMode(SpeechMode.device);
      await replyArrives('Your mail is in.');
      expect(speaker.spoken, ['Your mail is in.']);
    });

    test('stays quiet when the voice is switched off', () async {
      await state.setSpeechMode(SpeechMode.off);
      await replyArrives('Your mail is in.');
      expect(speaker.spoken, isEmpty);
    });

    test('does not speak your own words back at you', () async {
      await state.setSpeechMode(SpeechMode.device);
      state.handleEventForTest('agent_message', {
        'agentId': 'a1', 'role': 'user', 'content': 'hello',
        'timestamp': DateTime.now().toIso8601String(),
      });
      await Future<void>.delayed(Duration.zero);
      expect(speaker.spoken, isEmpty);
    });

    test('keeps the reply on screen when the voice fails', () async {
      // A voice is an enhancement. Losing it must not lose the answer.
      await state.setSpeechMode(SpeechMode.device);
      speaker.throws = true;
      await replyArrives('Your mail is in.');
      expect(state.transcript.last.content, 'Your mail is in.');
    });

    test('can be cut off mid-sentence', () async {
      await state.setSpeechMode(SpeechMode.device);
      await state.hush();
      expect(speaker.stops, 1);
    });
  });
}
