/// Poppy taking a photograph.
///
/// The platform camera is behind a seam, so these cover the parts that are
/// actually ours: what the agent is told, what happens when the camera is
/// missing or refused, and that the hardware is let go of afterwards.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poppy/services/camera_tool.dart';
import 'package:poppy/services/device_tools.dart';

const _back = CameraDescription(
    name: 'back', lensDirection: CameraLensDirection.back, sensorOrientation: 90);
const _front = CameraDescription(
    name: 'front', lensDirection: CameraLensDirection.front, sensorOrientation: 270);

/// A JPEG's worth of bytes. Contents are never inspected.
final _frame = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);

class _FakeController implements CameraController {
  final _FakeBackend backend;
  final CameraDescription camera;
  _FakeController(this.backend, this.camera);

  bool disposed = false;

  /// The capture code asks whether the controller is still usable before
  /// reusing it, so the fake has to have an answer.
  @override
  CameraValue get value => CameraValue.uninitialized(camera).copyWith(
        isInitialized: !disposed,
      );

  @override
  Future<XFile> takePicture() async {
    backend.shots++;
    if (backend.failOnShoot != null) throw backend.failOnShoot!;
    return XFile.fromData(backend.bytes, mimeType: 'image/jpeg');
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    backend.disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBackend implements CameraBackend {
  List<CameraDescription> available = const [_back, _front];
  CameraException? failOnOpen;
  CameraException? failOnShoot;
  Uint8List bytes = _frame;

  int opens = 0;
  int shots = 0;
  int disposals = 0;
  CameraDescription? opened;

  @override
  Future<List<CameraDescription>> cameras() async => available;

  @override
  Future<CameraController> open(CameraDescription camera) async {
    if (failOnOpen != null) throw failOnOpen!;
    opens++;
    opened = camera;
    return _FakeController(this, camera) as CameraController;
  }
}

void main() {
  late _FakeBackend backend;
  late CameraCapture camera;

  setUp(() {
    backend = _FakeBackend();
    camera = CameraCapture(backend: backend, idleTimeout: const Duration(milliseconds: 40));
  });

  group('taking a photo', () {
    test('gives the agent the picture, not a description of it', () async {
      final result = await camera.take();

      expect(result.imageBase64, base64Encode(_frame));
      expect(result.imageMediaType, 'image/jpeg');
    });

    test('says which camera it came from, for a model that only reads', () async {
      expect((await camera.take(lens: Lens.front)).text, contains('front'));
      expect((await camera.take(lens: Lens.back)).text, contains('back'));
    });

    test('uses the lens that was asked for', () async {
      await camera.take(lens: Lens.front);
      expect(backend.opened?.lensDirection, CameraLensDirection.front);
    });

    test('uses the only camera there is rather than refusing', () async {
      // Asking for the front camera on a device with one camera is a reason to
      // use the one it has.
      backend.available = const [_back];
      final result = await camera.take(lens: Lens.front);

      expect(result.imageBase64, isNotNull);
      expect(backend.opened?.lensDirection, CameraLensDirection.back);
    });
  });

  group('when it cannot', () {
    test('says so plainly when the device has no camera', () async {
      backend.available = const [];
      final result = await camera.take();

      expect(result.imageBase64, isNull);
      expect(result.text, contains('no camera'));
    });

    test('tells the agent what to do about a refused permission', () async {
      // "Failed" invites a retry; naming the fix does not.
      backend.failOnOpen = CameraException('CameraAccessDenied', 'denied');
      final result = await camera.take();

      expect(result.text, contains('permission'));
      expect(result.text, contains('Ask them'));
    });

    test('distinguishes a camera another app is holding', () async {
      backend.failOnOpen = CameraException('CameraInUse', 'busy');
      expect((await camera.take()).text, contains('in use'));
    });

    test('never throws, whatever the platform does', () async {
      backend.failOnOpen = CameraException('weird_code', 'something odd');
      final result = await camera.take();

      expect(result.text, contains('something odd'));
      expect(result.imageBase64, isNull);
    });

    test('reports an empty frame instead of sending nothing', () async {
      backend.bytes = Uint8List(0);
      final result = await camera.take();

      expect(result.imageBase64, isNull);
      expect(result.text, contains('empty'));
    });

    test('lets go of the camera when a shot fails', () async {
      // Otherwise a broken controller is reused for every later request.
      backend.failOnShoot = CameraException('CameraAccessDenied', 'denied');
      await camera.take();

      expect(backend.disposals, 1);
    });
  });

  group('holding the hardware', () {
    test('does not reopen the camera for a second photo', () async {
      await camera.take();
      await camera.take();

      expect(backend.shots, 2);
      expect(backend.opens, 1);
    });

    test('reopens when the other lens is asked for', () async {
      await camera.take(lens: Lens.back);
      await camera.take(lens: Lens.front);

      expect(backend.opens, 2);
      expect(backend.disposals, 1);
    });

    test('lets go once nothing has used it for a while', () async {
      // An idle controller keeps the hardware indicator lit, which is both a
      // battery cost and a fair thing to be suspicious of.
      await camera.take();
      expect(backend.disposals, 0);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(backend.disposals, 1);
    });

    test('releases it on dispose', () async {
      await camera.take();
      await camera.dispose();

      expect(backend.disposals, 1);
    });

    test('runs one capture at a time', () async {
      // Two overlapping requests would fight over the controller, and the
      // second would lose with an opaque platform error.
      final both = await Future.wait([camera.take(), camera.take()]);

      expect(backend.shots, 1);
      expect(both[0].imageBase64, both[1].imageBase64);
    });
  });

  group('telling the user', () {
    test('reports every capture, so the camera never fires silently', () async {
      final seen = <Lens>[];
      final watched = CameraCapture(backend: backend, onCapture: seen.add);

      await watched.take(lens: Lens.front);
      await watched.take(lens: Lens.back);

      expect(seen, [Lens.front, Lens.back]);
      await watched.dispose();
    });

    test('does not report a capture that failed', () async {
      final seen = <Lens>[];
      backend.failOnOpen = CameraException('CameraAccessDenied', 'denied');
      final watched = CameraCapture(backend: backend, onCapture: seen.add);

      await watched.take();

      expect(seen, isEmpty);
      await watched.dispose();
    });
  });

  group('how the agent sees the tool', () {
    test('says what it is for, not just what it does', () async {
      // The description is all an agent has when deciding whether it may look.
      final tool = takePhotoTool(camera);

      expect(tool.name, 'take_photo');
      expect(tool.description, contains('look at'));
      expect(tool.description, contains('saved to the project'));
    });

    test('offers the lens as a choice the model can make', () {
      final properties = takePhotoTool(camera).parameters?['properties'] as Map?;
      expect((properties?['lens'] as Map?)?['enum'], ['back', 'front']);
    });

    test('defaults to the back camera when none is named', () async {
      await takePhotoTool(camera).run(const {});
      expect(backend.opened?.lensDirection, CameraLensDirection.back);
    });

    test('passes the chosen lens through', () async {
      await takePhotoTool(camera).run(const {'lens': 'front'});
      expect(backend.opened?.lensDirection, CameraLensDirection.front);
    });

    test('returns something the host can answer with', () async {
      final result = await takePhotoTool(camera).run(const {});
      expect(result, isA<DeviceToolResult>());
      expect(result.imageBase64, isNotNull);
    });
  });
}
