/// Whether the camera is offered to the agent at all.
///
/// The runner hands the agent exactly what this device declares, so a tool
/// listed without the permission behind it becomes one the agent calls over
/// and over and never gets anything from.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:poppy/models/embodied_agent.dart';
import 'package:poppy/providers/poppy_state.dart';
import 'package:poppy/services/camera_tool.dart';
import 'package:poppy/services/embodiment_client.dart';
import 'package:poppy/services/pairing_service.dart';
import 'package:poppy/services/permissions.dart';
import 'package:poppy/services/speaker.dart';

class _QuietClient extends EmbodimentClient {
  _QuietClient() : super(baseUrl: 'http://test', apiKey: 'k', httpClient: http.Client());
  @override
  Future<List<EmbodiedAgent>> agents() async => [];
  @override
  Future<Map<String, dynamic>> declareDevice(String deviceId, List<Map<String, dynamic>> tools,
      {String? label, Map<String, dynamic>? capabilities}) async => const {};
}

class _MemoryPairing extends PairingService {
  Pairing? stored;
  @override
  Future<Pairing?> load() async => stored;
  @override
  Future<void> save(Pairing p) async => stored = p;
  @override
  Future<String> deviceId() async => 'test-device';
  @override
  Future<void> forget() async => stored = null;
}

/// A camera that is simply there, or simply not.
///
/// Keeps the callback it was handed so a test can fire it the way a real
/// capture would, without a platform camera.
class _StubCamera extends CameraCapture {
  final bool present;
  _StubCamera({required this.present, super.onCapture});
  @override
  Future<bool> isAvailable() async => present;

  void pretendToCapture(Lens lens) => onCapture?.call(lens);
}

const _paul = Pairing(serverUrl: 'http://test', apiKey: 'k', username: 'paul');

void main() {
  late bool granted;
  late bool promptAnswer;
  late int prompts;

  PoppyState build({bool hasCamera = true}) => PoppyState(
        pairing: _MemoryPairing(),
        clientFactory: (_) => _QuietClient(),
        speakerFactory: (_, __) => const SilentSpeaker(),
        cameraFactory: (onCapture) => _StubCamera(present: hasCamera, onCapture: onCapture),
      );

  setUp(() {
    granted = false;
    promptAnswer = true;
    prompts = 0;
    cameraPermission = () async => granted;
    requestCameraPermission = () async {
      prompts++;
      granted = promptAnswer;
      return granted;
    };
  });

  group('offering the camera', () {
    test('does not offer it before permission is given', () async {
      // Otherwise the agent is handed a tool that can only ever fail.
      final state = build();
      await state.completePairing(_paul);

      expect(state.offersCamera, isFalse);
    });

    test('offers it on launch when permission was granted before', () async {
      granted = true;
      final state = build();
      await state.completePairing(_paul);

      expect(state.offersCamera, isTrue);
    });

    test('does not offer it on a device with no camera, however permitted', () async {
      granted = true;
      final state = build(hasCamera: false);
      await state.completePairing(_paul);

      expect(state.offersCamera, isFalse);
    });

    test('starts offering it the moment permission is granted', () async {
      final state = build();
      await state.completePairing(_paul);
      expect(state.offersCamera, isFalse);

      expect(await state.requestCamera(), isTrue);
      expect(state.offersCamera, isTrue);
    });

    test('says no, and offers nothing, when the user declines', () async {
      promptAnswer = false;
      final state = build();
      await state.completePairing(_paul);

      expect(await state.requestCamera(), isFalse);
      expect(state.offersCamera, isFalse);
    });

    test('prompts rather than assuming the answer', () async {
      final state = build();
      await state.completePairing(_paul);
      await state.requestCamera();

      expect(prompts, 1);
    });

    test('declares get_device_time whatever the camera situation', () async {
      // The camera being refused must not cost the agent the rest of its tools.
      final state = build(hasCamera: false);
      await state.completePairing(_paul);

      expect(state.deviceTools?.has('get_device_time'), isTrue);
    });
  });

  capabilityDeclaration();

  group('noting that a photo was taken', () {
    test('puts it in the transcript, so the camera never fires silently', () async {
      granted = true;
      late _StubCamera camera;
      final state = PoppyState(
        pairing: _MemoryPairing(),
        clientFactory: (_) => _QuietClient(),
        speakerFactory: (_, __) => const SilentSpeaker(),
        cameraFactory: (onCapture) =>
            camera = _StubCamera(present: true, onCapture: onCapture),
      );
      await state.completePairing(_paul);

      camera.pretendToCapture(Lens.back);

      expect(state.transcript.last.toolName, 'take_photo');
      expect(state.transcript.last.content, contains('back'));
    });

    test('names the lens it used', () async {
      granted = true;
      late _StubCamera camera;
      final state = PoppyState(
        pairing: _MemoryPairing(),
        clientFactory: (_) => _QuietClient(),
        speakerFactory: (_, __) => const SilentSpeaker(),
        cameraFactory: (onCapture) =>
            camera = _StubCamera(present: true, onCapture: onCapture),
      );
      await state.completePairing(_paul);

      camera.pretendToCapture(Lens.front);

      expect(state.transcript.last.content, contains('front'));
    });
  });
}

// ── What this phone tells the runner it can do ───────────────────────────────
//
// Capabilities are not tools: the runner never calls them, it reads them to
// decide how to do its own work. Claiming one this app cannot deliver is worse
// than claiming nothing, because the runner then stops doing it itself.

/// A client that keeps what it was told, and answers with an agreement.
class _DeclaringClient extends EmbodimentClient {
  _DeclaringClient() : super(baseUrl: 'http://test', apiKey: 'k', httpClient: http.Client());
  Map<String, dynamic>? declared;

  @override
  Future<List<EmbodiedAgent>> agents() async => [];

  @override
  Future<Map<String, dynamic>> declareDevice(String deviceId, List<Map<String, dynamic>> tools,
      {String? label, Map<String, dynamic>? capabilities}) async {
    declared = capabilities;
    return const {'faceEmbedding': 'runner'};
  }
}

void capabilityDeclaration() {
  late _DeclaringClient client;
  late bool granted;

  PoppyState build({bool hasCamera = true}) => PoppyState(
        pairing: _MemoryPairing(),
        clientFactory: (_) => client,
        speakerFactory: (_, __) => const SilentSpeaker(),
        cameraFactory: (onCapture) => _StubCamera(present: hasCamera, onCapture: onCapture),
      );

  // Inside the group, not beside it: a setUp registered at file scope runs
  // for every test in the file, and would overwrite the other group's
  // permission stubs.
  group('declaring what this phone can do', () {
    setUp(() {
      client = _DeclaringClient();
      granted = true;
      cameraPermission = () async => granted;
      requestCameraPermission = () async => granted;
    });
    test('claims the camera when there is one and it may be used', () async {
      final state = build();
      await state.completePairing(_paul);
      await state.deviceTools!.declare();

      expect(client.declared?['camera'], {'lenses': ['back', 'front']});
    });

    test('does not claim a camera it cannot use', () async {
      // The runner would otherwise plan around a camera that always fails.
      granted = false;
      final state = build();
      await state.completePairing(_paul);
      await state.deviceTools!.declare();

      expect(client.declared?.containsKey('camera'), isFalse);
    });

    test('does not claim a camera on a device without one', () async {
      final state = build(hasCamera: false);
      await state.completePairing(_paul);
      await state.deviceTools!.declare();

      expect(client.declared?.containsKey('camera'), isFalse);
    });

    test('claims speech, which it really does handle here', () async {
      final state = build();
      await state.completePairing(_paul);
      await state.deviceTools!.declare();

      expect(client.declared?['speech'], {'recognition': true, 'synthesis': true});
    });

    test('does not claim face embedding, which nothing here can do', () async {
      // Claiming it would stop the runner sending pictures, and it would then
      // wait for vectors that never arrive.
      final state = build();
      await state.completePairing(_paul);
      await state.deviceTools!.declare();

      expect(client.declared?.containsKey('faceEmbedding'), isFalse);
    });

    test('remembers what the runner agreed to', () async {
      final state = build();
      await state.completePairing(_paul);
      await state.deviceTools!.declare();

      expect(state.deviceTools!.agreed['faceEmbedding'], 'runner');
    });
  });
}
