// The arithmetic that decides whether a face is recognised or quietly never
// matched. The browser has the same tests; the two have to agree, because
// both write into one register on the runner.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:poppy/services/face_embedding.dart';

/// An inputSize x inputSize RGBA buffer, every pixel the same colour.
Uint8List flat(int r, int g, int b, {int size = 112}) {
  final out = Uint8List(size * size * 4);
  for (var p = 0; p < size * size; p++) {
    out[p * 4] = r;
    out[p * 4 + 1] = g;
    out[p * 4 + 2] = b;
    out[p * 4 + 3] = 255;
  }
  return out;
}

void main() {
  group('framing the face', () {
    const width = 640;
    const height = 480;

    test('is always square', () {
      final crop = faceCropBox(const CropBox(100, 100, 80, 120), width, height);
      expect(crop.width, closeTo(crop.height, 1e-9));
    });

    test('takes the longer edge, so the sides of a face are not cut off', () {
      const tight = FaceProfile(
          model: 'm', dimensions: 192, inputSize: 112, margin: 0);
      final crop = faceCropBox(const CropBox(100, 100, 80, 120), width, height,
          profile: tight);
      expect(crop.width, closeTo(120, 1e-9));
    });

    test('opens the detector box out', () {
      // Detectors give a tight box; recognition models are trained on a looser
      // crop. Using the box as given loses accuracy invisibly.
      const none =
          FaceProfile(model: 'm', dimensions: 192, inputSize: 112, margin: 0);
      final tight =
          faceCropBox(const CropBox(100, 100, 100, 100), width, height, profile: none);
      final loose =
          faceCropBox(const CropBox(100, 100, 100, 100), width, height);
      expect(loose.width, greaterThan(tight.width));
      expect(loose.width, closeTo(150, 1e-9));
    });

    test('stays centred on the face', () {
      final crop = faceCropBox(const CropBox(200, 150, 100, 100), width, height);
      expect(crop.x + crop.width / 2, closeTo(250, 1e-9));
      expect(crop.y + crop.height / 2, closeTo(200, 1e-9));
    });

    test('never runs off the edge', () {
      // A crop hanging over the edge means black bars the model never saw in
      // training, so it is slid back inside instead.
      const boxes = [
        CropBox(0, 0, 100, 100),
        CropBox(590, 430, 100, 100),
        CropBox(-20, -20, 80, 80),
      ];
      for (final box in boxes) {
        final crop = faceCropBox(box, width, height);
        expect(crop.x, greaterThanOrEqualTo(0), reason: '$box');
        expect(crop.y, greaterThanOrEqualTo(0), reason: '$box');
        expect(crop.x + crop.width, lessThanOrEqualTo(width + 1e-9));
        expect(crop.y + crop.height, lessThanOrEqualTo(height + 1e-9));
      }
    });

    test('shrinks rather than overflow a face that fills the frame', () {
      final crop = faceCropBox(const CropBox(0, 0, 640, 480), width, height);
      expect(crop.width, lessThanOrEqualTo(480));
    });

    test('copes with a picture narrower than the face box', () {
      final crop = faceCropBox(const CropBox(0, 0, 200, 200), 100, 100);
      expect(crop, const CropBox(0, 0, 100, 100));
    });
  });

  group('the shape of the input', () {
    test('is NHWC for a LiteRT model', () {
      expect(mobileFaceNet.inputShape, [1, 112, 112, 3]);
    });

    test('is NCHW when the profile says so', () {
      const planar = FaceProfile(
          model: 'm', dimensions: 192, inputSize: 112, layout: 'nchw');
      expect(planar.inputShape, [1, 3, 112, 112]);
    });
  });

  group('turning pixels into model input', () {
    test('drops the alpha channel', () {
      expect(normalisePixels(flat(0, 0, 0)).length, 112 * 112 * 3);
    });

    test('maps black and white to the ends of the range', () {
      expect(normalisePixels(flat(0, 0, 0))[0], closeTo((0 - 127.5) / 128, 1e-6));
      expect(
          normalisePixels(flat(255, 255, 255))[0], closeTo((255 - 127.5) / 128, 1e-6));
    });

    test('keeps the channels in order for an RGB model', () {
      final out = normalisePixels(flat(255, 0, 0));
      expect(out[0], greaterThan(0)); // red
      expect(out[1], lessThan(0)); // green
      expect(out[2], lessThan(0)); // blue
    });

    test('swaps red and blue for a BGR model', () {
      // Silently the wrong way round is how a model that works in a demo
      // matches nobody in production.
      const bgr = FaceProfile(
          model: 'm', dimensions: 192, inputSize: 112, channels: 'bgr');
      final out = normalisePixels(flat(255, 0, 0), profile: bgr);
      expect(out[0], lessThan(0)); // blue first
      expect(out[2], greaterThan(0)); // red last
    });

    test('writes planar data for an NCHW model', () {
      const planar =
          FaceProfile(model: 'm', dimensions: 192, inputSize: 2, layout: 'nchw');
      final rgba = Uint8List.fromList([
        255, 0, 0, 255, 255, 0, 0, 255, //
        255, 0, 0, 255, 255, 0, 0, 255,
      ]);
      final out = normalisePixels(rgba, profile: planar);
      // All four reds first, then all four greens, then all four blues.
      expect(out.sublist(0, 4).every((v) => v > 0), isTrue);
      expect(out.sublist(4, 12).every((v) => v < 0), isTrue);
    });

    test('says so when the crop was drawn at the wrong size', () {
      expect(() => normalisePixels(flat(0, 0, 0, size: 64)),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('finishing the vector', () {
    test('comes out unit length', () {
      final unit = l2normalise([3, 4])!;
      expect(unit[0] * unit[0] + unit[1] * unit[1], closeTo(1, 1e-9));
    });

    test('keeps the direction', () {
      expect(l2normalise([3, 4]), [closeTo(0.6, 1e-9), closeTo(0.8, 1e-9)]);
    });

    test('refuses a vector with no direction', () {
      // A zero vector is equally similar to everybody, so storing one would
      // have the agent greet strangers by name.
      expect(l2normalise([0, 0, 0]), isNull);
    });

    test('refuses rubbish rather than propagating NaN', () {
      expect(l2normalise([double.nan, 1]), isNull);
    });
  });

  group('checking a vector before it is sent', () {
    final good = List<double>.filled(mobileFaceNet.dimensions, 0.1);

    test('passes one of the right size', () {
      expect(whyUnusable(good), isNull);
    });

    test('names the model when the size is wrong', () {
      // The runner would reject this too, but only after it crossed the
      // network, and its complaint would not say which model was expected.
      final why = whyUnusable(List<double>.filled(512, 0.1))!;
      expect(why, contains('512'));
      expect(why, contains(mobileFaceNet.model));
    });

    test('catches NaN', () {
      final bad = [...good.sublist(1), double.nan];
      expect(whyUnusable(bad), contains('not numbers'));
    });

    test('catches a missing vector', () {
      expect(whyUnusable(null), contains('not a vector'));
    });
  });

  group('agreeing with the browser', () {
    test('uses the same model id and size the runner defaults to', () {
      // The runner names mobilefacenet-v1 at 192 dimensions. A phone
      // declaring anything else is told to embed nowhere, and face
      // recognition silently does not happen.
      expect(mobileFaceNet.model, 'mobilefacenet-v1');
      expect(mobileFaceNet.dimensions, 192);
      expect(mobileFaceNet.inputSize, 112);
      expect(mobileFaceNet.mean, 127.5);
      expect(mobileFaceNet.scale, 128);
      expect(mobileFaceNet.margin, 0.25);
    });
  });
}
