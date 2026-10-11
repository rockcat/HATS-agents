/// Asking for things the user has to agree to.
///
/// Kept apart from the tools that need them so the tools stay testable: a
/// permission check reaches a platform channel, which in a test means a
/// binding error rather than an answer.
library;

import 'package:permission_handler/permission_handler.dart';

/// Overridable for tests. Returns whether the camera may be used *now*,
/// without prompting.
Future<bool> Function() cameraPermission = () async =>
    await Permission.camera.isGranted;

/// Overridable for tests. Prompts if the user has not decided yet.
Future<bool> Function() requestCameraPermission = () async {
  if (await Permission.camera.isGranted) return true;
  return (await Permission.camera.request()).isGranted;
};
