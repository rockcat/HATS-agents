import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:poppy/services/device_tools.dart';
import 'package:poppy/services/embodiment_client.dart';

/// Records what the device told the runner.
class _RecordingClient extends EmbodimentClient {
  final List<Map<String, dynamic>> results = [];
  List<Map<String, dynamic>>? declared;
  String? declaredLabel;
  Map<String, dynamic>? declaredCapabilities;
  int withdrawals = 0;
  bool reachable = true;

  _RecordingClient() : super(baseUrl: 'http://test', apiKey: 'k', httpClient: http.Client());

  @override
  Future<Map<String, dynamic>> declareDevice(String deviceId, List<Map<String, dynamic>> tools,
      {String? label, Map<String, dynamic>? capabilities}) async {
    if (!reachable) throw EmbodimentException('unreachable');
    declared = tools;
    declaredLabel = label;
    declaredCapabilities = capabilities;
    return const {};
  }

  @override
  Future<void> withdrawDevice(String deviceId) async {
    if (!reachable) throw EmbodimentException('unreachable');
    withdrawals++;
  }

  @override
  Future<void> sendDeviceResult(String requestId,
      {required bool ok,
      String? result,
      String? error,
      String? imageBase64,
      String imageMediaType = 'image/jpeg'}) async {
    if (!reachable) throw EmbodimentException('unreachable');
    results.add({
      'id': requestId, 'ok': ok, 'result': result, 'error': error,
      if (imageBase64 != null) 'image': imageBase64,
      if (imageBase64 != null) 'mediaType': imageMediaType,
    });
  }
}

void main() {
  late _RecordingClient client;

  DeviceToolHost hostWith(List<DeviceTool> tools) =>
      DeviceToolHost(client: client, deviceId: 'dev-1', label: 'test phone', tools: tools);

  Map<String, dynamic> request(String tool, {String id = 'r1', Map<String, dynamic>? args}) =>
      {'id': id, 'tool': tool, 'arguments': args ?? <String, dynamic>{}};

  setUp(() => client = _RecordingClient());

  group('declaring', () {
    test('tells the runner what this device offers', () async {
      await hostWith(defaultDeviceTools()).declare();
      expect(client.declared?.map((t) => t['name']), contains('get_device_time'));
      expect(client.declaredLabel, 'test phone');
    });

    test('survives the runner being unreachable', () async {
      // Device tools are an extra. Losing them must not break the app.
      client.reachable = false;
      expect(await hostWith(defaultDeviceTools()).declare(), isFalse);
    });

    test('a withdrawn tool is no longer declared', () async {
      final host = hostWith(defaultDeviceTools());
      host.remove('get_device_time');
      await host.declare();
      expect(client.declared, isEmpty);
    });

    test('an added tool is declared alongside the rest', () async {
      final host = hostWith(defaultDeviceTools())
        ..add(DeviceTool(name: 'ping', description: 'Say pong.', run: (_) async => const DeviceToolResult('pong')));
      await host.declare();
      expect(client.declared?.map((t) => t['name']), containsAll(['get_device_time', 'ping']));
    });
  });

  group('answering a request', () {
    test('runs the tool and sends the result back', () async {
      final host = hostWith([
        DeviceTool(name: 'ping', description: 'Say pong.', run: (_) async => const DeviceToolResult('pong')),
      ]);
      await host.handle(request('ping'));

      expect(client.results.single['ok'], isTrue);
      expect(client.results.single['result'], 'pong');
      expect(client.results.single['id'], 'r1');
    });

    test('passes the arguments through', () async {
      String? seen;
      final host = hostWith([
        DeviceTool(
          name: 'echo',
          description: 'Echo.',
          run: (args) async { seen = args['text'] as String?; return const DeviceToolResult('ok'); },
        ),
      ]);
      await host.handle(request('echo', args: {'text': 'hello'}));
      expect(seen, 'hello');
    });

    test('answers even when the tool throws', () async {
      // Silence costs the agent the full timeout and teaches it nothing.
      final host = hostWith([
        DeviceTool(name: 'boom', description: 'Fails.', run: (_) async => throw StateError('no camera')),
      ]);
      await host.handle(request('boom'));

      expect(client.results.single['ok'], isFalse);
      expect(client.results.single['error'], contains('no camera'));
    });

    test('answers for a tool it does not have', () async {
      await hostWith(const []).handle(request('take_photo'));
      expect(client.results.single['ok'], isFalse);
      expect(client.results.single['error'], contains('take_photo'));
    });

    test('runs a repeated request only once', () async {
      // A retransmitted frame taking a second photo would be a poor surprise.
      var runs = 0;
      final host = hostWith([
        DeviceTool(
          name: 'slow',
          description: 'Slow.',
          run: (_) async {
            runs++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return const DeviceToolResult('done');
          },
        ),
      ]);

      await Future.wait([host.handle(request('slow')), host.handle(request('slow'))]);
      expect(runs, 1);
    });

    test('handles the same tool again once the first has finished', () async {
      var runs = 0;
      final host = hostWith([
        DeviceTool(name: 'ping', description: 'Pong.', run: (_) async { runs++; return const DeviceToolResult('pong'); }),
      ]);
      await host.handle(request('ping', id: 'r1'));
      await host.handle(request('ping', id: 'r2'));
      expect(runs, 2);
    });

    test('ignores a malformed frame rather than throwing', () async {
      final host = hostWith(defaultDeviceTools());
      await host.handle({'tool': 'get_device_time'}); // no id
      await host.handle({'id': 'r1'}); // no tool
      expect(client.results, isEmpty);
    });

    test('does not break when the answer cannot be delivered', () async {
      client.reachable = false;
      final host = hostWith([
        DeviceTool(name: 'ping', description: 'Pong.', run: (_) async => const DeviceToolResult('pong')),
      ]);
      await host.handle(request('ping'));
      expect(client.results, isEmpty); // the runner times it out instead
    });
  });

  group('get_device_time', () {
    test('reports a time the agent can act on', () async {
      final host = hostWith(defaultDeviceTools());
      await host.handle(request('get_device_time'));

      final answer = client.results.single['result'] as String;
      // Needs the zone: "this morning" means the user's morning, not the server's.
      expect(answer, contains('UTC'));
      expect(DateTime.tryParse(answer.split(' ').first), isNotNull);
    });
  });

  group('withdrawing', () {
    test('tells the runner to stop offering the tools', () async {
      await hostWith(defaultDeviceTools()).withdraw();
      expect(client.withdrawals, 1);
    });

    test('does not throw when the runner has already gone', () async {
      client.reachable = false;
      await expectLater(hostWith(defaultDeviceTools()).withdraw(), completes);
    });
  });
}
