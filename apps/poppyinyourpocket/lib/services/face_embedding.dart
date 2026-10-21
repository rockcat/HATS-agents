/// Turning a face in a photograph into a vector — the arithmetic half.
///
/// The twin of `packages/ui-kit/face-embedding.js`, and it has to stay the
/// twin: a phone and a browser tab both write into the same register on the
/// runner, so a crop or a normalisation that differs by a little produces
/// vectors that are close to each other and to nobody else. The browser copy
/// is the reference; anything changed here changes there.
///
/// Kept apart from the runtime for the same reason as in the browser: this is
/// the part that fails silently. Get the crop, the channel order or the
/// normalisation wrong and the model still returns 192 plausible floats. They
/// simply match nobody, for ever, and nothing in the output says which of the
/// three was wrong.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// How one model wants its input, and what it gives back.
///
/// Written out rather than inferred, because every one of these has to match
/// the `.tflite` file actually loaded, and a mismatch is invisible.
class FaceProfile {
  /// The id stored against every template, and negotiated with the runner.
  final String model;
  final int dimensions;

  /// Square input, in pixels.
  final int inputSize;

  /// `nhwc` is the usual LiteRT layout; `nchw` is the usual ONNX one.
  final String layout;
  final String channels;
  final double mean;
  final double scale;

  /// How much to open the detector's box out before cropping.
  ///
  /// Detectors return a tight box around the features; recognition models are
  /// trained on a looser crop including some forehead and jaw. Cropping to the
  /// box as given is a common and invisible way to lose accuracy.
  final double margin;

  const FaceProfile({
    required this.model,
    required this.dimensions,
    required this.inputSize,
    this.layout = 'nhwc',
    this.channels = 'rgb',
    this.mean = 127.5,
    this.scale = 128,
    this.margin = 0.25,
  });

  /// The shape the model's input tensor wants.
  List<int> get inputShape => layout == 'nchw'
      ? [1, 3, inputSize, inputSize]
      : [1, inputSize, inputSize, 3];
}

/// The default, matching the browser's and the runner's.
///
/// Scaling by 128 rather than 127.5 is the InsightFace convention
/// MobileFaceNet is trained with, not a rounding slip.
const mobileFaceNet = FaceProfile(
  model: 'mobilefacenet-v1',
  dimensions: 192,
  inputSize: 112,
);

/// A rectangle in image pixels.
class CropBox {
  final double x;
  final double y;
  final double width;
  final double height;

  const CropBox(this.x, this.y, this.width, this.height);

  int get left => x.round();
  int get top => y.round();
  int get size => width.round();

  @override
  String toString() => 'CropBox($x, $y, $width, $height)';

  @override
  bool operator ==(Object other) =>
      other is CropBox &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);
}

/// Square the detector's box, pad it, and keep it inside the picture.
///
/// Always square and always in bounds, because both alternatives are worse:
/// hanging over the edge means black bars the model never saw in training, and
/// squashing a rectangle to fit distorts the face differently depending on how
/// close to the edge the person stood.
CropBox faceCropBox(
  CropBox box,
  int imageWidth,
  int imageHeight, {
  FaceProfile profile = mobileFaceNet,
}) {
  final centreX = box.x + box.width / 2;
  final centreY = box.y + box.height / 2;

  // The longer edge wins, so a box taller than it is wide does not crop the
  // sides of the face off.
  var side = math.max(box.width, box.height) * (1 + profile.margin * 2);
  side = [side, imageWidth.toDouble(), imageHeight.toDouble()].reduce(math.min);

  return CropBox(
    _clamp(centreX - side / 2, 0, imageWidth - side),
    _clamp(centreY - side / 2, 0, imageHeight - side),
    side,
    side,
  );
}

/// RGBA pixels into the floats the model wants.
///
/// Drops the alpha channel, puts the colours in the model's order and layout,
/// and shifts them into its range.
Float32List normalisePixels(
  Uint8List rgba, {
  FaceProfile profile = mobileFaceNet,
}) {
  final n = profile.inputSize;
  final pixels = n * n;
  if (rgba.length < pixels * 4) {
    throw ArgumentError(
      'Expected ${pixels * 4} bytes for a ${n}x$n RGBA image, got ${rgba.length}. '
      'The crop was drawn at the wrong size.',
    );
  }

  final planar = profile.layout == 'nchw';
  // Red and blue swapped for a BGR model. Alpha is dropped either way.
  final order = profile.channels == 'bgr' ? const [2, 1, 0] : const [0, 1, 2];

  final out = Float32List(pixels * 3);
  for (var p = 0; p < pixels; p++) {
    for (var c = 0; c < 3; c++) {
      final value = (rgba[p * 4 + order[c]] - profile.mean) / profile.scale;
      out[planar ? c * pixels + p : p * 3 + c] = value;
    }
  }
  return out;
}

/// Finish a raw model output into a comparable vector.
///
/// Unit length, because the runner compares by cosine similarity and a vector
/// of a different magnitude is not wrong so much as unanswerable.
///
/// Returns null rather than a zero vector: a zero vector has no direction, so
/// it is equally similar to everybody, and storing one would have the agent
/// greet strangers by name.
List<double>? l2normalise(List<double> vector) {
  var sum = 0.0;
  for (final value in vector) {
    sum += value * value;
  }
  final length = math.sqrt(sum);
  if (!length.isFinite || length == 0) return null;
  return [for (final value in vector) value / length];
}

/// Check a finished vector before it goes anywhere near the register.
///
/// The runner rejects a wrong-length vector too, but by then it has crossed
/// the network and the agent has been told something unhelpful about
/// dimensions. Catching it here says which model was expected.
///
/// Returns what is wrong, or null if nothing is.
String? whyUnusable(List<double>? vector, {FaceProfile profile = mobileFaceNet}) {
  if (vector == null) return 'That is not a vector.';
  if (vector.length != profile.dimensions) {
    return 'This is a ${vector.length}-dimension vector and ${profile.model} '
        'produces ${profile.dimensions}. The loaded model is not the one configured.';
  }
  if (vector.any((v) => !v.isFinite)) {
    return 'That vector contains values that are not numbers.';
  }
  return null;
}

double _clamp(double value, double low, double high) {
  // `high` can fall below `low` when the crop is as big as the picture.
  if (high < low) return low;
  return math.min(math.max(value, low), high);
}
