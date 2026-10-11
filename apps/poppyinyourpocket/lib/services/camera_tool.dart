/// Poppy looking at something.
///
/// The camera is the reason device tools exist: it is attached to this phone
/// and a server-side process has no route to it. The agent asks, this takes a
/// frame, and the picture goes back up the same channel every other device
/// result uses.
///
/// Three things shape the design:
///
///  * **Declare only what works.** The tool is offered only when there is a
///    camera and permission has actually been granted. Offering it otherwise
///    gives the agent something it will call repeatedly and never get.
///  * **Capture small.** The controller runs at a modest resolution rather
///    than taking a full-size frame and shrinking it — decoding and
///    re-encoding a 12-megapixel JPEG on a phone costs seconds and produces
///    something the model did not want anyway.
///  * **Do not hold the camera open.** An idle controller keeps the hardware
///    indicator lit and drains the battery, which is both a cost and a
///    reasonable thing for someone to be suspicious of.
library;

import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart';

import 'device_tools.dart';

/// How long the camera stays warm after a photo.
///
/// Long enough that "take another" does not pay the start-up cost again,
/// short enough that the indicator does not stay lit while nothing is
/// happening.
const kCameraIdleTimeout = Duration(seconds: 20);

/// Which way the phone is pointing.
enum Lens { back, front }

Lens _lensFrom(Object? value) =>
    '$value'.toLowerCase().startsWith('front') ? Lens.front : Lens.back;

CameraLensDirection _directionOf(Lens lens) =>
    lens == Lens.front ? CameraLensDirection.front : CameraLensDirection.back;

/// The platform bits, behind a seam so the tool can be tested without one.
abstract class CameraBackend {
  /// Cameras this device has. Empty when it has none.
  Future<List<CameraDescription>> cameras();

  /// Open one and return a controller that has finished initialising.
  Future<CameraController> open(CameraDescription camera);
}

class _RealCameraBackend implements CameraBackend {
  @override
  Future<List<CameraDescription>> cameras() => availableCameras();

  @override
  Future<CameraController> open(CameraDescription camera) async {
    // Medium is roughly 720p: enough for "what am I holding?", and a fraction
    // of the bytes and the latency of a full-resolution frame.
    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await controller.initialize();
    return controller;
  }
}

/// Takes photographs on request, and gets out of the way in between.
class CameraCapture {
  final CameraBackend _backend;
  final Duration idleTimeout;

  /// Called after a picture is taken, so the UI can say so.
  ///
  /// A camera that fires with no indication is the kind of thing that erodes
  /// trust in the whole app, however well-intentioned the caller.
  final void Function(Lens lens)? onCapture;

  CameraController? _controller;
  Lens? _openLens;
  Timer? _idle;

  /// One capture at a time. Two overlapping requests would fight over the
  /// controller and the second would usually lose with an opaque platform
  /// error.
  Future<DeviceToolResult>? _inFlight;

  CameraCapture({CameraBackend? backend, this.onCapture, Duration? idleTimeout})
      : _backend = backend ?? _RealCameraBackend(),
        idleTimeout = idleTimeout ?? kCameraIdleTimeout;

  /// Does this device have a camera at all?
  Future<bool> isAvailable() async {
    try {
      return (await _backend.cameras()).isNotEmpty;
    } on Object {
      return false;
    }
  }

  /// Take one photo. Never throws: the agent is told what went wrong instead.
  Future<DeviceToolResult> take({Lens lens = Lens.back}) {
    final running = _inFlight;
    if (running != null) return running;
    final attempt = _take(lens).whenComplete(() => _inFlight = null);
    _inFlight = attempt;
    return attempt;
  }

  Future<DeviceToolResult> _take(Lens lens) async {
    final CameraController controller;
    try {
      controller = await _controllerFor(lens);
    } on CameraException catch (err) {
      return DeviceToolResult(_explain(err));
    } on Object catch (err) {
      return DeviceToolResult('The camera could not be started: $err');
    }

    try {
      final shot = await controller.takePicture();
      final bytes = await shot.readAsBytes();
      onCapture?.call(lens);
      _restartIdleTimer();

      if (bytes.isEmpty) {
        return const DeviceToolResult('The camera returned an empty frame.');
      }
      return DeviceToolResult(
        'A photo from the ${lens == Lens.front ? 'front' : 'back'} camera of '
        "the user's device.",
        imageBase64: base64Encode(bytes),
      );
    } on CameraException catch (err) {
      await _close();
      return DeviceToolResult(_explain(err));
    } on Object catch (err) {
      await _close();
      return DeviceToolResult('The photo could not be taken: $err');
    }
  }

  /// Say what a platform error means, in terms the agent can act on.
  String _explain(CameraException err) {
    final code = err.code.toLowerCase();
    if (code.contains('permission') || code.contains('denied')) {
      return 'The user has not given this app permission to use the camera. '
          'Ask them to grant it in the app, then try again.';
    }
    if (code.contains('inuse') || code.contains('busy')) {
      return 'The camera is in use by something else on the device.';
    }
    return 'The camera failed: ${err.description ?? err.code}';
  }

  Future<CameraController> _controllerFor(Lens lens) async {
    final existing = _controller;
    if (existing != null && _openLens == lens && existing.value.isInitialized) {
      return existing;
    }
    await _close();

    final cameras = await _backend.cameras();
    if (cameras.isEmpty) throw CameraException('no_camera', 'This device has no camera.');

    final wanted = _directionOf(lens);
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == wanted,
      // Asking for the front camera on a device that has only one is a reason
      // to use the one it has, not to refuse.
      orElse: () => cameras.first,
    );

    final controller = await _backend.open(camera);
    _controller = controller;
    _openLens = lens;
    return controller;
  }

  void _restartIdleTimer() {
    _idle?.cancel();
    _idle = Timer(idleTimeout, () => _close());
  }

  Future<void> _close() async {
    _idle?.cancel();
    _idle = null;
    final controller = _controller;
    _controller = null;
    _openLens = null;
    if (controller == null) return;
    try {
      await controller.dispose();
    } on Object {
      // Already gone. Nothing useful to do, and nothing depends on it.
    }
  }

  /// Release the camera — the app is closing or going to the background.
  Future<void> dispose() => _close();
}

/// The `take_photo` tool, as the agent sees it.
///
/// The description says what it is *for*. An agent reads this and nothing
/// else when deciding whether to use it, and "takes a photo" alone leaves it
/// guessing whether it may.
DeviceTool takePhotoTool(CameraCapture camera) => DeviceTool(
      name: 'take_photo',
      description:
          "Take a photo with the camera on the user's device and look at it. "
          'Use this when the user asks you to look at something, refers to '
          "something in front of them, or when seeing would answer a question "
          'better than asking. The photo is shown to you directly and is also '
          "saved to the project, so you can refer back to it later.",
      parameters: const {
        'type': 'object',
        'properties': {
          'lens': {
            'type': 'string',
            'enum': ['back', 'front'],
            'description':
                'Which camera. "back" to see what the user is looking at, '
                    '"front" to see the user. Defaults to back.',
          },
        },
      },
      run: (args) => camera.take(lens: _lensFrom(args['lens'] ?? 'back')),
    );
