import 'dart:io';

import 'package:android_avd_splash/android_avd_splash.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

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
}
