import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:android_avd_splash/android_avd_splash.dart';
import 'package:android_avd_splash/src/contour.dart' show signedArea;
import 'package:android_avd_splash/src/model.dart' show OutlineTrack;
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

  test('walks a curved motion path instead of cutting across it', () {
    // `to` and `ti` bend the path the position travels along. Android moves in
    // a straight line between keys, so the curve has to become keys.
    final curved = _lottie([
      _layer(_box(10), position: {
        'a': 1,
        'k': [
          {
            't': 0,
            's': [10, 50, 0],
            'e': [90, 50, 0],
            'to': [0, -60, 0],
            'ti': [0, -60, 0],
          },
          {'t': 30},
        ],
      }),
    ]);
    final group = convertLottie(curved, options: const Options(name: 'arc'))
        .drawable
        .groups
        .firstWhere((g) => g.translateY.keys.length > 2);
    final keys = group.translateY.keys;
    final middle = keys[keys.length ~/ 2];
    final straight = keys.first.value +
        (keys.last.value - keys.first.value) *
            ((middle.timeMs - keys.first.timeMs) / (keys.last.timeMs - keys.first.timeMs));
    expect((middle.value - straight).abs(), greaterThan(5),
        reason: 'the arc rises well away from the straight line between its ends');
    expect(group.translateX.keys.length, keys.length, reason: 'both axes walk together');
  });

  test('covers a matte layer\'s stroke as well as its fill', () {
    Generated matted(double strokeWidth) => convertLottie(
          _lottie([
            _layer(_box(20), index: 1, matteSource: true, strokeWidth: strokeWidth),
            _layer(_box(30), index: 2, matteType: 1),
          ]),
          options: const Options(name: 'm'),
        );
    // A stroke paints half its width outside the outline, and a matte is
    // coverage: without it the clip comes out a stroke-width thin.
    expect(_clipArea(matted(10)), greaterThan(_clipArea(matted(0)) * 1.2));
  });

  test('cuts a subtractive mask out of the layer it masks', () {
    final converted = convertLottie(
      _lottie([
        _layer(_box(30), masks: [_mask('a', inverted: true)]),
      ]),
      options: const Options(name: 'masked'),
    );
    expect(converted.unsupported, isEmpty, reason: 'keeping a layer out of a shape is a clip');
    expect(converted.files['drawable/masked_vector.xml'], contains('<clip-path'));
    expect(_clipArea(converted), greaterThan(0));
  });

  test('clips additive masks and reports a mask on a matte', () {
    final inside = convertLottie(
      _lottie([
        _layer(_box(30), masks: [_mask('a', inverted: false)]),
      ]),
      options: const Options(name: 'x'),
    );
    expect(inside.unsupported, isEmpty);
    expect(inside.files['drawable/x_vector.xml'], contains('<clip-path'));
    expect(_clipArea(inside), greaterThan(0));

    final onMatte = convertLottie(
      _lottie([
        _layer(_box(20), index: 1, matteSource: true, masks: [_mask('a', inverted: true)]),
        _layer(_box(30), index: 2, matteType: 1),
      ]),
      options: const Options(name: 'y'),
    );
    expect(onMatte.unsupported, contains('a mask on a matte'));
  });

  test('takes the plate the artwork sits on out of the icon', () {
    // The platform masks the icon to a circle, so a square behind the artwork
    // can never be drawn as its author meant it - and it would spend the whole
    // icon on colour.
    Uint8List plated({required bool full}) => Uint8List.fromList(utf8.encode(jsonEncode({
          'v': '5.5.7',
          'fr': 30,
          'ip': 0,
          'op': 30,
          'w': 100,
          'h': 100,
          'layers': [
            _layer(_box(20), index: 2, position: _still([70, 50, 0])),
            _layer(_box(full ? 50 : 20), index: 1, position: _still([50, 50, 0])),
          ],
        })));
    final onPlate = convertLottie(plated(full: true), options: const Options(name: 'p'));
    expect(onPlate.plate, 0xFF000000);
    expect(onPlate.drawable.paths, hasLength(1), reason: 'the plate is not drawn');

    final loose = convertLottie(plated(full: false), options: const Options(name: 'q'));
    expect(loose.plate, isNull, reason: 'a shape that is not a background stays artwork');
    expect(loose.drawable.paths, hasLength(2));
  });

  test('animates a rectangle or an ellipse the file animates', () {
    // Lottie can animate the size, centre and corner radius of a primitive;
    // freezing them at the first keyframe is how a bar that grows never grows.
    final growing = Uint8List.fromList(utf8.encode(jsonEncode({
      'v': '5.5.7',
      'fr': 30,
      'ip': 0,
      'op': 30,
      'w': 100,
      'h': 100,
      'layers': [
        {
          'ty': 4,
          'ind': 1,
          'ip': 0,
          'op': 30,
          'st': 0,
          'ks': {
            'o': _still(100),
            'r': _still(0),
            'p': _still([50, 50, 0]),
            'a': _still([0, 0, 0]),
            's': _still([100, 100, 100]),
          },
          'shapes': [
            {
              'ty': 'gr',
              'it': [
                {
                  'ty': 'rc',
                  'p': _still([0, 0]),
                  'r': _still(0),
                  's': {
                    'a': 1,
                    'k': [
                      {
                        't': 0,
                        's': [0, 20],
                        'e': [60, 20],
                      },
                      {'t': 30},
                    ],
                  },
                },
                {
                  'ty': 'fl',
                  'c': _still([0, 0, 0, 1]),
                  'o': _still(100)
                },
                {
                  'ty': 'tr',
                  'p': _still([0, 0]),
                  'a': _still([0, 0]),
                  's': _still([100, 100]),
                  'r': _still(0),
                  'o': _still(100),
                },
              ],
            },
          ],
        },
      ],
    })));
    final path = convertLottie(growing, options: const Options(name: 'bar')).drawable.paths.single;
    expect(path.data.isConstant, isFalse, reason: 'the size is a track, not a first value');
    double width(int timeMs) {
      final loop = path.data.at(timeMs).single;
      final xs = loop.map((p) => p.x);
      return xs.reduce(math.max) - xs.reduce(math.min);
    }

    expect(width(0), lessThan(1));
    expect(width(1000), greaterThan(width(500)));
  });
}

/// A Lottie file built by hand: the smallest one that carries the feature
/// under test, so a test reads as the feature rather than as a fixture.
Uint8List _lottie(List<Map<String, Object?>> layers) => Uint8List.fromList(utf8.encode(
    jsonEncode({'v': '5.5.7', 'fr': 30, 'ip': 0, 'op': 30, 'w': 100, 'h': 100, 'layers': layers})));

Map<String, Object?> _still(Object? value) => {'a': 0, 'k': value};

Map<String, Object?> _path(List<List<double>> points) => {
      'ty': 'sh',
      'ks': _still({
        'v': points,
        'i': [
          for (var i = 0; i < points.length; i++) const [0.0, 0.0]
        ],
        'o': [
          for (var i = 0; i < points.length; i++) const [0.0, 0.0]
        ],
        'c': true,
      }),
    };

Map<String, Object?> _box(double half) => _path([
      [-half, -half],
      [half, -half],
      [half, half],
      [-half, half],
    ]);

Map<String, Object?> _layer(
  Map<String, Object?> shape, {
  int index = 1,
  Object? position,
  double strokeWidth = 0,
  int? matteType,
  bool matteSource = false,
  List<Map<String, Object?>> masks = const [],
}) =>
    {
      'ty': 4,
      'ind': index,
      'ip': 0,
      'op': 30,
      'st': 0,
      if (matteType != null) 'tt': matteType,
      if (matteSource) 'td': 1,
      if (masks.isNotEmpty) 'masksProperties': masks,
      'ks': {
        'o': _still(100),
        'r': _still(0),
        'p': position ?? _still([50, 50, 0]),
        'a': _still([0, 0, 0]),
        's': _still([100, 100, 100]),
      },
      'shapes': [
        {
          'ty': 'gr',
          'it': [
            shape,
            if (strokeWidth > 0)
              {
                'ty': 'st',
                'c': _still([0, 0, 0, 1]),
                'o': _still(100),
                'w': _still(strokeWidth),
              },
            {
              'ty': 'fl',
              'c': _still([0, 0, 0, 1]),
              'o': _still(100),
              'r': 1
            },
            {
              'ty': 'tr',
              'p': _still([0, 0]),
              'a': _still([0, 0]),
              's': _still([100, 100]),
              'r': _still(0),
              'o': _still(100),
            },
          ],
        },
      ],
    };

Map<String, Object?> _mask(String mode, {required bool inverted}) => {
      'mode': mode,
      'inv': inverted,
      'o': _still(100),
      'pt': _still({
        'v': const [
          [0.0, 0.0],
          [20.0, 0.0],
          [20.0, 20.0],
          [0.0, 20.0],
        ],
        'i': const [
          [0.0, 0.0],
          [0.0, 0.0],
          [0.0, 0.0],
          [0.0, 0.0]
        ],
        'o': const [
          [0.0, 0.0],
          [0.0, 0.0],
          [0.0, 0.0],
          [0.0, 0.0]
        ],
        'c': true,
      }),
    };

/// The tightest clip a converted drawable carries, by the area of its widest
/// loop at its first key: every drawable is clipped to its own composition
/// box, so the one that says something is the one inside that.
double _clipArea(Generated converted) {
  var tightest = double.infinity;
  for (final group in converted.drawable.groups) {
    final clip = group.clip;
    if (clip == null) continue;
    var widest = 0.0;
    for (final loop in clip.keys.first.value) {
      final area = signedArea(flattenLoop(loop)).abs();
      if (area > widest) widest = area;
    }
    if (widest > 0 && widest < tightest) tightest = widest;
  }
  return tightest.isFinite ? tightest : 0;
}
