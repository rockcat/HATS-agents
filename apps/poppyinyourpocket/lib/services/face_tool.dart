/// The device tool that recognises a face, on the phone.
///
/// What the runner asks this app for when an agent calls `identify_person`.
/// A photograph is taken, ML Kit finds the face in it, LiteRT turns the crop
/// into a vector, and the vector goes back on the `data` channel — not in the
/// sentence the agent reads, because 192 floats are no use to a language
/// model and would cost two kilobytes of its context to say nothing.
///
/// The face never leaves the phone. That is the whole reason for running the
/// model here rather than posting a photograph to the runner, and it is worth
/// not quietly giving up: if the model is missing, the tool is not declared,
/// so the capability exchange reports honestly that this device cannot embed
/// and the runner stops expecting vectors from it.
///
/// A still rather than a video frame, deliberately. Converting a CameraImage
/// means handling YUV420 on Android and BGRA8888 on iOS, with a plane layout
/// that varies by device — a large amount of fiddly code whose failure mode
/// is, once again, vectors that look fine and match nobody. "Who am I talking
/// to" is asked once in a conversation, not thirty times a second, so the
/// extra few hundred milliseconds of decoding a JPEG buys correctness cheaply.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_litert/flutter_litert.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import 'camera_tool.dart';
import 'device_tools.dart';
import 'face_embedding.dart';

/// Where the recognition model lives in the bundle.
///
/// An asset rather than a download: this one decides the embedding space
/// every stored face lives in, so it should be a file whose contents are
/// pinned with the build.
const faceModelAsset = 'assets/models/mobilefacenet.tflite';

/// Face recognition on this phone, or an honest refusal.
class FaceRecogniser {
  final FaceProfile profile;
  final String modelAsset;

  FaceDetector? _detector;
  Interpreter? _interpreter;

  /// Set once we know it cannot work, so we stop retrying on every request.
  String? _unavailable;

  FaceRecogniser({
    this.profile = mobileFaceNet,
    this.modelAsset = faceModelAsset,
  });

  bool get ready => _interpreter != null && _detector != null;

  /// Load both models.
  ///
  /// Returns false rather than throwing when something is missing — most
  /// often the recognition model, which is not committed to the repo. The
  /// caller's job is then to not declare the capability, not to show an error.
  Future<bool> load() async {
    if (ready) return true;
    if (_unavailable != null) return false;

    try {
      // Classic Interpreter rather than LiteRT Next's CompiledModel: it is the
      // path that works on every platform this app builds for, web included.
      _interpreter = await Interpreter.fromAsset(modelAsset);
      _detector = FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.fast,
          enableLandmarks: false,
          enableClassification: false,
        ),
      );
      return true;
    } on Object catch (err) {
      _unavailable = 'No face model on this device: $err';
      return false;
    }
  }

  /// Find a face in a photograph and return its vector.
  ///
  /// [jpeg] is the encoded still. Returns a vector, or why there is not one:
  /// not finding a face is an answer rather than a failure, and the agent has
  /// to be able to tell "nobody is there" from "this is broken".
  Future<FaceLook> embedJpeg(Uint8List jpeg) async {
    if (!await load()) return FaceLook.reason(_unavailable!);

    final decoded = img.decodeImage(jpeg);
    if (decoded == null) return FaceLook.reason('That photograph could not be read.');

    final faces = await _detect(jpeg);
    final face = _largest(faces);
    if (face == null) return FaceLook.reason('I cannot see a face.');

    final box = faceCropBox(
      CropBox(
        face.boundingBox.left,
        face.boundingBox.top,
        face.boundingBox.width,
        face.boundingBox.height,
      ),
      decoded.width,
      decoded.height,
      profile: profile,
    );

    final input = normalisePixels(_cropToSquare(decoded, box), profile: profile);
    final output = List<double>.filled(profile.dimensions, 0)
        .reshape([1, profile.dimensions]);

    _interpreter!.run(input.reshape(profile.inputShape), output);

    final vector = l2normalise((output[0] as List).cast<double>());
    final wrong = whyUnusable(vector, profile: profile);
    if (wrong != null) return FaceLook.reason(wrong);

    return FaceLook.found(vector!);
  }

  /// Run the detector over an encoded still.
  ///
  /// Through a file rather than a byte buffer: ML Kit's byte path wants raw
  /// planes in a platform-specific layout — NV21 on Android, BGRA on iOS —
  /// and feeding it anything else produces detections that are sometimes
  /// right, which is harder to notice than never working. The file path is
  /// the supported route for a still and handles decoding and orientation
  /// itself.
  Future<List<Face>> _detect(Uint8List jpeg) async {
    final directory = Directory.systemTemp.createTempSync('poppy-face');
    final file = File('${directory.path}/frame.jpg');
    try {
      await file.writeAsBytes(jpeg, flush: true);
      return await _detector!.processImage(InputImage.fromFilePath(file.path));
    } finally {
      // A face left on disk is exactly what this design is trying to avoid.
      try {
        directory.deleteSync(recursive: true);
      } on Object {
        // Nothing better to do; the OS clears its own temp eventually.
      }
    }
  }

  /// Crop to the box and scale to the model's square, as RGBA.
  Uint8List _cropToSquare(img.Image source, CropBox box) {
    final cropped = img.copyCrop(
      source,
      x: box.left,
      y: box.top,
      width: box.size,
      height: box.size,
    );
    final scaled = img.copyResize(
      cropped,
      width: profile.inputSize,
      height: profile.inputSize,
      interpolation: img.Interpolation.linear,
    );
    return scaled.convert(numChannels: 4).toUint8List();
  }

  /// The biggest face, which in a conversation is the person talking to you
  /// rather than somebody at the far end of the room.
  Face? _largest(List<Face> faces) {
    Face? best;
    var bestArea = 0.0;
    for (final face in faces) {
      final area = face.boundingBox.width * face.boundingBox.height;
      if (area > bestArea) {
        best = face;
        bestArea = area;
      }
    }
    return best;
  }

  Future<void> dispose() async {
    await _detector?.close();
    _interpreter?.close();
    _detector = null;
    _interpreter = null;
  }
}

/// What one look produced: a vector, or why there is not one.
class FaceLook {
  final List<double>? vector;
  final String? why;

  const FaceLook.found(List<double> this.vector) : why = null;
  const FaceLook.reason(String this.why) : vector = null;
}

/// Build the device tool, or null when this phone cannot run the model.
///
/// Checked by actually loading it rather than by probing the platform: the
/// usual reason it cannot is a missing model asset, which no amount of
/// probing would reveal.
Future<DeviceTool?> faceTool({
  required CameraCapture camera,
  FaceRecogniser? recogniser,
}) async {
  final engine = recogniser ?? FaceRecogniser();
  if (!await engine.load()) return null;

  return DeviceTool(
    name: 'embed_face',
    description:
        'Look through the camera and turn the face in front of it into a vector '
        'the runner can match. You do not normally call this yourself — '
        'identify_person and remember_person use it for you.',
    parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
    run: (_) async {
      // The front camera: this is for looking at whoever is talking, not at
      // what they are holding.
      final shot = await camera.take(lens: Lens.front);
      final base64Jpeg = shot.imageBase64;
      if (base64Jpeg == null) {
        // The capture already explains itself better than anything generic.
        throw StateError(shot.text);
      }

      final look = await engine.embedJpeg(base64Decode(base64Jpeg));
      if (look.vector == null) throw StateError(look.why!);

      return DeviceToolResult(
        'Had a look through the camera.',
        data: look.vector,
      );
    },
  );
}

/// What to tell the runner this device can do.
Map<String, dynamic> faceCapability({FaceProfile profile = mobileFaceNet}) => {
      'faceEmbedding': [
        {'model': profile.model, 'dimensions': profile.dimensions},
      ],
    };
