import 'dart:io';
import 'dart:typed_data';

import 'package:android_avd_splash/android_avd_splash.dart';
import 'package:android_avd_splash/src/build.dart' show analyse;
import 'package:android_avd_splash/src/contour.dart' show Point;
import 'package:android_avd_splash/src/paint.dart' show fitFill;
import 'package:test/test.dart';
import 'package:xml/xml.dart';

/// A GIF of flat rectangles, built in memory: the colours are the subject, so
/// the geometry is kept as plain as it can be.
Gif _painted(List<(int, int, int, int, int)> rectangles, {int size = 96}) {
  final rgba = Uint8List(size * size * 4);
  for (final (x0, y0, x1, y1, colour) in rectangles) {
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final i = (y * size + x) * 4;
        rgba[i] = (colour >> 16) & 0xFF;
        rgba[i + 1] = (colour >> 8) & 0xFF;
        rgba[i + 2] = colour & 0xFF;
        rgba[i + 3] = 0xFF;
      }
    }
  }
  return Gif(size, size, [GifFrame(rgba, 100), GifFrame(Uint8List.fromList(rgba), 100)]);
}

void main() {
  final bytes = File('test/fixtures/shapes.gif').readAsBytesSync();
  final generated = generate(bytes, options: const Options(name: 'shapes'));
  final avd = generated.avd;
  final drawable = generated.drawable;

  test('trims the blank lead-in', () {
    expect(avd!.frameIndices.first, 1);
    expect(avd.frameTimes.first, 0);
    expect(avd.durationMs, 350);
  });

  test('separates the artwork colours, most used first', () {
    expect([for (final l in avd!.separation.layers) l.hex], ['#FF2850DC', '#FFDC2828']);
  });

  test('follows the square as one rigid path and keeps the ring hole', () {
    final ring = drawable.paths.firstWhere((p) => p.paint.color == 0xFF2850DC);
    expect(ring.data.first.length, 2, reason: 'outline plus hole');
    final square = drawable.paths.firstWhere((p) => p.paint.color == 0xFFDC2828);
    expect(square.data.isConstant, isTrue, reason: 'it only translates');
    expect(drawable.groups.where((g) => g.isAnimated), isNotEmpty);
    expect(drawable.paths.length, 2);
  });

  test('reproduces every frame of the GIF', () {
    final report = check(generated);
    expect(report.frames, avd!.frameTimes.length);
    expect(report.meanTolerant, greaterThan(0.99));
    expect(report.worstTolerant, greaterThan(0.95));
    expect(report.morphable, isTrue);
    expect(report.insideSafeArea, isTrue);
  });

  test('writes well-formed resources', () {
    expect(
        generated.files.keys, containsAll(['drawable/shapes.xml', 'drawable/shapes_vector.xml']));
    for (final entry in generated.files.entries) {
      expect(() => XmlDocument.parse(entry.value), returnsNormally, reason: entry.key);
    }
    final animated = XmlDocument.parse(generated.files['drawable/shapes.xml']!).rootElement;
    for (final target in animated.findElements('target')) {
      final animation = target.getAttribute('android:animation')!.replaceFirst('@animator/', '');
      expect(generated.files, contains('animator/$animation.xml'));
    }
    final vector = XmlDocument.parse(generated.files['drawable/shapes_vector.xml']!).rootElement;
    expect(vector.getAttribute('android:width'), '288dp');
    expect(vector.getAttribute('android:viewportWidth'), '288');
  });

  test('spends its accuracy up to the morph budget and no further', () {
    final budgeted = generate(bytes, options: const Options(name: 'shapes', maxMorphSegments: 8));
    expect(budgeted.drawable.morphLoad, lessThanOrEqualTo(8));
    final free = generate(bytes, options: const Options(name: 'shapes', maxMorphSegments: 0));
    expect(free.qualityDp, const Options().curveTolerance);
    expect(check(budgeted).meanTolerant, greaterThan(0.99));
  });

  test('reaches the accuracy a vector can reach against whole pixels', () {
    final report = check(generated);
    expect(report.ofCeiling, greaterThan(0.99));
    expect(report.meanDeviationDp, lessThan(1.0));
    expect(report.typicalDeviationDp, lessThan(2.0));
  });

  test('drops what cannot be seen and says how much', () {
    // The ring covers far more than the square, so a threshold between them
    // keeps one and drops the other.
    final coarse = generate(bytes, options: const Options(name: 'shapes', minAreaDp: 5000));
    expect(coarse.avd!.droppedRegions, 1);
    expect(coarse.drawable.paths.length, 1);
  });

  test('every animator lasts exactly as long as the drawable', () {
    for (final entry in generated.files.entries.where((e) => e.key.startsWith('animator/'))) {
      final root = XmlDocument.parse(entry.value).rootElement;
      final durations = [
        for (final a in root.findAllElements('objectAnimator'))
          int.parse(a.getAttribute('android:duration')!),
      ];
      final total = root.name.local == 'set'
          ? durations.reduce((a, b) => a + b)
          : int.parse(root.getAttribute('android:duration')!);
      expect(total, drawable.durationMs, reason: entry.key);
    }
  });

  test('holds GIF frames instead of inventing geometry between them', () {
    final morphs = generated.files.entries
        .where((entry) => entry.key.startsWith('animator/') && entry.value.contains('pathType'));
    expect(morphs, isNotEmpty);
    for (final entry in morphs) {
      final animators =
          XmlDocument.parse(entry.value).rootElement.findAllElements('objectAnimator');
      for (final animator in animators) {
        expect(
          animator.getAttribute('android:valueTo'),
          animator.getAttribute('android:valueFrom'),
          reason: '${entry.key}: a GIF frame must remain unchanged for its delay',
        );
      }
    }

    final floats = generated.files.entries
        .where((entry) => entry.key.startsWith('animator/') && entry.value.contains('floatType'));
    expect(floats, isNotEmpty);
    for (final entry in floats) {
      final animator = XmlDocument.parse(entry.value).rootElement;
      final durationMs = int.parse(animator.getAttribute('android:duration')!);
      for (final holder in animator.findAllElements('propertyValuesHolder')) {
        final keys = [
          for (final key in holder.findElements('keyframe'))
            (
              double.parse(key.getAttribute('android:fraction')!),
              double.parse(key.getAttribute('android:value')!),
            ),
        ];
        for (var i = 1; i < keys.length; i++) {
          expect(keys[i].$1, greaterThan(keys[i - 1].$1),
              reason: '${entry.key}: two keyframes at one fraction are a zero to divide by');
          if (keys[i].$2 == keys[i - 1].$2) continue;
          expect(
            (keys[i].$1 - keys[i - 1].$1) * durationMs,
            lessThanOrEqualTo(1.5),
            reason: '${entry.key}: a GIF frame must hold, then change in under a rendered frame',
          );
        }
      }
    }
  });

  test('keyframe tracks span the whole timeline', () {
    for (final entry in generated.files.entries.where((e) => e.key.startsWith('animator/'))) {
      for (final holder
          in XmlDocument.parse(entry.value).rootElement.findAllElements('propertyValuesHolder')) {
        final fractions = [
          for (final k in holder.findElements('keyframe'))
            double.parse(k.getAttribute('android:fraction')!),
        ];
        // A track that stops short of 1 keeps drifting: the native animator
        // extrapolates past its last keyframe instead of holding it.
        expect(fractions.first, 0);
        expect(fractions.last, 1);
      }
    }
  });

  test('honours colour overrides', () {
    final plain = generate(bytes,
        options: const Options(name: 'shapes', colors: [0xFF2850DC], background: 0));
    expect(plain.avd!.separation.layers.length, 1);
    expect(plain.files['drawable/shapes_vector.xml'], contains('#FF2850DC'));
    expect(plain.files['drawable/shapes_vector.xml'], isNot(contains('#FFDC2828')));
  });

  test('paints everything in one colour when told to', () {
    final single = generate(bytes, options: const Options(name: 'shapes', colors: [0xFF00FF00]));
    expect(single.avd!.separation.layers.length, 1);
    expect(single.drawable.paths.every((p) => p.paint.color == 0xFF00FF00), isTrue);
    expect(check(single).meanTolerant, greaterThan(0.99));
  });

  test('reads a gradient off the pixels and writes it as a fill', () {
    final generated = generate(
      File('test/fixtures/gradient.gif').readAsBytesSync(),
      options: const Options(name: 'grad'),
    );
    expect(generated.avd!.separation.layers.length, 1, reason: 'one piece of artwork, not bands');
    expect(generated.drawable.paths.every((p) => p.paint.gradient != null), isTrue);
    final vector = generated.files['drawable/grad_vector.xml']!;
    expect(vector, contains('xmlns:aapt="http://schemas.android.com/aapt"'));
    expect(vector, contains('<gradient android:type="linear"'));
    expect(check(generated).meanTolerant, greaterThan(0.99));

    final flat = generate(
      File('test/fixtures/gradient.gif').readAsBytesSync(),
      options: const Options(name: 'grad', gradients: false),
    );
    expect(flat.drawable.paths.every((p) => p.paint.gradient == null), isTrue);
    expect(flat.files['drawable/grad_vector.xml'], isNot(contains('<gradient')));
  });

  test('writes a fold as the step it is, not a ramp across it', () {
    // Two flat reds meeting down the middle: near enough in colour to be one
    // paint, far enough apart to see, and nothing in between.
    final folded = analyse(
      _painted([(18, 18, 48, 78, 0xC82020), (48, 18, 78, 78, 0xF03030)]),
      const Options(name: 'fold'),
    );
    final gradients = folded.drawable.paths.where((p) => p.paint.gradient != null).toList();
    expect(gradients, hasLength(1), reason: 'one piece of artwork, two tones');
    final stops = gradients.single.paint.gradient!.stops;
    expect(stops, hasLength(4), reason: 'a step is two stops held either side of the edge');
    expect(stops[0].$2, stops[1].$2);
    expect(stops[2].$2, stops[3].$2);
    expect(stops[2].$1 - stops[1].$1, lessThan(0.02), reason: 'the edge is an edge');
    int red(int argb) => (argb >> 16) & 0xFF;
    expect(red(stops[0].$2), closeTo(0xC8, 8));
    expect(red(stops[3].$2), closeTo(0xF0, 8));
  });

  test('a ramp is still written as a ramp', () {
    final ramp = generate(
      File('test/fixtures/gradient.gif').readAsBytesSync(),
      options: const Options(name: 'ramp'),
    );
    final stops = ramp.drawable.paths.single.paint.gradient!.stops;
    expect(stops, hasLength(2), reason: 'two ends, and every colour between them painted');
  });

  test('a region painted in another colour is not this layer\'s artwork', () {
    // Green bled over light grey reads as green, and the separation hands the
    // region to grey because that is the layer it was cut from.
    final blend = _painted([(18, 18, 78, 78, 0x6FA878)]);
    final square = [
      for (final corner in [
        const Point(20, 20),
        const Point(76, 20),
        const Point(76, 76),
        const Point(20, 76),
      ])
        corner,
    ];
    final loop = [
      square[0],
      for (var i = 0; i < 4; i++) ...[square[i], square[i], square[(i + 1) % 4]]
    ];
    expect(
      fitFill(blend, 0, [loop], 1, const Point(0, 0), 0xFFDBDBDB,
          palette: const [0xFFDBDBDB, 0xFF47AB61], gradients: true),
      isNull,
      reason: 'the pixels are the green, not a shade of the grey they were cut from',
    );
    expect(
      fitFill(blend, 0, [loop], 1, const Point(0, 0), 0xFF6FA878,
          palette: const [0xFF6FA878, 0xFF47AB61], gradients: true),
      isNotNull,
      reason: 'the same pixels are that paint\'s own artwork',
    );
  });
}
