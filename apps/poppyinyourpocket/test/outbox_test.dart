import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:poppy/models/embodied_agent.dart';
import 'package:poppy/providers/poppy_state.dart';
import 'package:poppy/services/embodiment_client.dart';
import 'package:poppy/services/pairing_service.dart';
import 'package:poppy/services/speaker.dart';

/// Records what was sent, and can be made to fail like an unreachable runner.
class _RecordingClient extends EmbodimentClient {
  final List<String> sent = [];
  bool reachable = true;

  _RecordingClient() : super(baseUrl: 'http://test', apiKey: 'k', httpClient: http.Client());

  @override
  Future<void> send(String id, String content, {String thread = 'general'}) async {
    if (!reachable) throw EmbodimentException('unreachable');
    sent.add(content);
  }

  @override
  Future<List<EmbodiedAgent>> agents() async => [];
}

/// Pairing that never touches the keychain.
class _MemoryPairing extends PairingService {
  Pairing? stored;
  @override
  Future<Pairing?> load() async => stored;
  @override
  Future<void> save(Pairing p) async => stored = p;
  @override
  Future<void> saveAgentId(String id) async {}
  @override
  Future<String> deviceId() async => 'test-device';
  @override
  Future<void> forget() async => stored = null;
}

void main() {
  late _RecordingClient client;
  late PoppyState state;

  setUp(() async {
    client = _RecordingClient();
    state = PoppyState(
          pairing: _MemoryPairing(),
          clientFactory: (_) => client,
          speakerFactory: (_, __) => const SilentSpeaker(),
        );
    await state.completePairing(
      const Pairing(serverUrl: 'http://test', apiKey: 'k', username: 'paul'),
    );
    await state.chooseAgent(const EmbodiedAgent(id: 'a1', name: 'Poppy'));
  });

  group('saying something while offline', () {
    test('holds it rather than losing it', () async {
      state.setConnectionForTest(Connection.offline);
      await state.say('remind me to buy milk');

      expect(client.sent, isEmpty);
      expect(state.unsentCount, 1);
    });

    test('shows it in the transcript, marked as not yet delivered', () async {
      state.setConnectionForTest(Connection.offline);
      await state.say('remind me to buy milk');

      // Silence would be the wrong failure: you said it, so you should see it.
      expect(state.transcript.last.content, 'remind me to buy milk');
      expect(state.transcript.last.pending, isTrue);
    });

    test('sends it on reconnect and marks it delivered', () async {
      state.setConnectionForTest(Connection.offline);
      await state.say('remind me to buy milk');

      state.setConnectionForTest(Connection.online);
      await Future<void>.delayed(Duration.zero);

      expect(client.sent, ['remind me to buy milk']);
      expect(state.unsentCount, 0);
      expect(state.transcript.last.pending, isFalse);
    });

    test('keeps the order it was said in', () async {
      state.setConnectionForTest(Connection.offline);
      await state.say('first');
      await state.say('second');
      await state.say('third');

      state.setConnectionForTest(Connection.online);
      await Future<void>.delayed(Duration.zero);

      expect(client.sent, ['first', 'second', 'third']);
    });

    test('stops at the first failure rather than sending out of order', () async {
      state.setConnectionForTest(Connection.offline);
      await state.say('first');
      await state.say('second');

      client.reachable = false;
      state.setConnectionForTest(Connection.online);
      await Future<void>.delayed(Duration.zero);

      expect(client.sent, isEmpty);
      expect(state.unsentCount, 2);
    });
  });

  group('saying something while online', () {
    test('goes straight out and is not marked pending', () async {
      state.setConnectionForTest(Connection.online);
      await state.say('hello');

      expect(client.sent, ['hello']);
      expect(state.transcript.last.pending, isFalse);
      expect(state.unsentCount, 0);
    });

    test('falls back to the outbox when the runner turns out to be gone', () async {
      state.setConnectionForTest(Connection.online);
      client.reachable = false;
      await state.say('hello');

      // Believing we were online is not the same as being online.
      expect(state.unsentCount, 1);
      expect(state.connection, Connection.offline);
    });

    test('ignores an empty message', () async {
      state.setConnectionForTest(Connection.online);
      await state.say('   ');

      expect(client.sent, isEmpty);
      expect(state.transcript, isEmpty);
    });
  });

  group('the runner echoing your own message back', () {
    // The runner broadcasts the human's message to every listener, so what you
    // type arrives twice: once because the app showed it straight away, and
    // again off the stream.
    Map<String, dynamic> echo(String content) => {
          'agentId': 'a1',
          'role': 'user',
          'content': content,
          'timestamp': DateTime.now().toIso8601String(),
        };

    test('shows it once, not twice', () async {
      state.setConnectionForTest(Connection.online);
      await state.say('hello');
      state.handleEventForTest('agent_message', echo('hello'));

      expect(state.transcript.where((m) => m.content == 'hello'), hasLength(1));
    });

    test('takes the echo as confirmation that it was heard', () async {
      // A better signal than the POST returning: the runner has it, rather
      // than merely having accepted it.
      state.setConnectionForTest(Connection.offline);
      await state.say('hello');
      expect(state.transcript.last.pending, isTrue);

      state.setConnectionForTest(Connection.online);
      await Future<void>.delayed(Duration.zero);
      state.handleEventForTest('agent_message', echo('hello'));

      expect(state.transcript.last.pending, isFalse);
    });

    test('still shows a message sent from somewhere else', () async {
      // From the dashboard, say. That one really is news.
      state.setConnectionForTest(Connection.online);
      state.handleEventForTest('agent_message', echo('sent from the dashboard'));

      expect(state.transcript.single.content, 'sent from the dashboard');
    });

    test('absorbs one echo per identical message, not all of them', () async {
      state.setConnectionForTest(Connection.online);
      await state.say('again');
      await state.say('again');

      state.handleEventForTest('agent_message', echo('again'));
      state.handleEventForTest('agent_message', echo('again'));

      expect(state.transcript.where((m) => m.content == 'again'), hasLength(2));
    });

    test('shows a second echo, which cannot have been ours', () async {
      state.setConnectionForTest(Connection.online);
      await state.say('again');
      state.handleEventForTest('agent_message', echo('again'));
      state.handleEventForTest('agent_message', echo('again'));

      expect(state.transcript.where((m) => m.content == 'again'), hasLength(2));
    });

    test('leaves an assistant reply alone', () async {
      state.setConnectionForTest(Connection.online);
      await state.say('hello');
      state.handleEventForTest('agent_message', {
        'agentId': 'a1', 'role': 'assistant', 'content': 'hello',
        'timestamp': DateTime.now().toIso8601String(),
      });

      // Same text, but Poppy saying it is a different thing entirely.
      expect(state.transcript.where((m) => m.content == 'hello'), hasLength(2));
    });
  });
}
