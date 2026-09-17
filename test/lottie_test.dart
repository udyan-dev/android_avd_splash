import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:android_avd_splash/android_avd_splash.dart';
import 'package:android_avd_splash/src/contour.dart' show signedArea;
import 'package:android_avd_splash/src/winding.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

void main() {
  final logo = File('test/fixtures/flutter_logo.json').readAsBytesSync();
  final matte = File('test/fixtures/matte.json').readAsBytesSync();

  test('keeps the author\'s structure instead of tracing it', () {
    final converted = convertLottie(logo, options: const Options(name: 'logo'));
    expect(converted.qualityDp, 0, reason: 'nothing was approximated');
    expect(converted.unsupported, isEmpty);
    expect(converted.drawable.paths.length, 8);
    expect(converted.drawable.groups.length, greaterThan(8), reason: 'groups stay nested');
    expect(converted.bytes, lessThan(300 * 1024));
  });

  test('reproduces the animation exactly', () {
    for (final source in [logo, matte]) {
      final report = checkLottie(convertLottie(source, options: const Options(name: 'exact')));
      expect(report.ceiling, 1, reason: 'vector against vector has no pixel ceiling');
      expect(report.meanExact, greaterThan(0.999));
      expect(report.meanTolerant, greaterThan(0.999));
      expect(report.meanDeviationDp, lessThan(0.05));
      expect(report.morphable, isTrue);
      expect(report.insideSafeArea, isTrue);
    }
  });

  test('writes easing as path interpolators, one per distinct curve', () {
    final files = convertLottie(logo, options: const Options(name: 'logo')).files;
    final interpolators = files.keys.where((f) => f.startsWith('interpolator/'));
    expect(interpolators, isNotEmpty);
    for (final name in interpolators) {
      final node = XmlDocument.parse(files[name]!).rootElement;
      expect(node.name.local, 'pathInterpolator');
      expect(node.getAttribute('android:controlX1'), isNotNull);
    }
    final animators = files.entries.where((e) => e.key.startsWith('animator/'));
    expect(
      animators.any((e) => e.value.contains('@interpolator/')),
      isTrue,
      reason: 'the easing has to reach the animator that needs it',
    );
  });

  test('turns a track matte into a clip path', () {
    final converted = convertLottie(matte, options: const Options(name: 'matte'));
    final vector = converted.files['drawable/matte_vector.xml']!;
    expect(vector, contains('<clip-path'));
    expect(
      converted.files.keys.any((f) => f.contains('_clip_shape')),
      isTrue,
      reason: 'the matte moves, so its clip has to move with it',
    );
  });

  test('winds an inverted matte so the hole survives the non-zero rule', () {
    final converted = convertLottie(matte, options: const Options(name: 'matte'));
    final clips = [
      for (final group in converted.drawable.groups)
        if (group.clip != null) group.clip!,
    ];
    expect(clips, isNotEmpty);
    for (final clip in clips) {
      for (final key in clip.keys) {
        final areas = [for (final loop in key.value) signedArea(flattenLoop(loop))];
        final outer = areas.first;
        expect(outer.abs(), greaterThan(0));
        // A loop the animation has collapsed covers nothing, and the sign of
        // nothing does not matter.
        for (final hole in areas.skip(1).where((a) => a.abs() > outer.abs() * 1e-3)) {
          // A clip has no fillType on Android, so a hole is only a hole when it
          // turns against the loop around it.
          expect(hole * outer, isNegative);
        }
      }
    }
  });

  test('paints a fill and a stroke over one outline with one path', () {
    final converted = convertLottie(matte, options: const Options(name: 'matte'));
    final vector = converted.files['drawable/matte_vector.xml']!;
    final paths = XmlDocument.parse(vector).findAllElements('path').toList();
    expect(paths, hasLength(2), reason: 'two drawn layers, each fill and stroke in one path');
    for (final path in paths) {
      expect(path.getAttribute('android:fillColor'), isNotNull);
      expect(path.getAttribute('android:strokeColor'), isNotNull);
    }
  });

  test('animates paint properties Android owns natively', () {
    final files = convertLottie(logo, options: const Options(name: 'logo')).files;
    final paint = files.entries.firstWhere((e) => e.key.endsWith('_paint.xml')).value;
    expect(paint, contains('fillAlpha'));
    expect(files['drawable/logo_vector.xml'], contains('android:strokeColor'));
  });

  test('says what it could not convert', () {
    final unsupported = Uint8List.fromList(utf8.encode('{"v":"5.5.7","fr":30,"ip":0,"op":30,'
        '"w":100,"h":100,"layers":[{"ty":2,"ind":1,"ip":0,"op":30,"ks":{}}]}'));
    expect(
      () => convertLottie(unsupported, options: const Options(name: 'x')),
      throwsA(isA<StateError>()),
    );
  });

  test('rejects data that is not Lottie', () {
    expect(
      () => convertLottie(File('pubspec.yaml').readAsBytesSync()),
      throwsA(isA<FormatException>()),
    );
  });
}
