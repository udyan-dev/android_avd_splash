import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:android_avd_splash/android_avd_splash.dart';
import 'package:android_avd_splash/src/svg.dart' show parsePathData;
import 'package:test/test.dart';
import 'package:xml/xml.dart';

Uint8List _svg(String body, {String attributes = ''}) =>
    Uint8List.fromList(utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" '
        'viewBox="0 0 100 100" $attributes>$body</svg>'));

void main() {
  final logo = File('test/fixtures/logo.svg').readAsBytesSync();

  test('rebuilds an animated SVG structurally', () {
    final converted = convertSvg(logo, options: const Options(name: 'logo'));
    expect(converted.unsupported, isEmpty);
    expect(converted.qualityDp, 0, reason: 'nothing was approximated');
    expect(converted.drawable.source, 'SVG');
    expect(converted.drawable.durationMs, 1000, reason: 'as long as the longest animation runs');
    expect(converted.drawable.paths.length, 4);
    final vector = converted.files['drawable/logo_vector.xml']!;
    expect(vector, contains('<clip-path'), reason: 'a clipPath is a clip path');
    expect(vector, contains('android:strokeColor="#FF212121"'));
    expect(vector, contains('<gradient'));
    expect(converted.files.keys.where((f) => f.startsWith('animator/')), isNotEmpty);
    expect(converted.files.keys.where((f) => f.startsWith('interpolator/')), isNotEmpty,
        reason: 'keySplines is a pathInterpolator');
  });

  test('replays exactly, because both sides are vector', () {
    final report = checkVector(convertSvg(logo, options: const Options(name: 'exact')));
    expect(report.ceiling, 1);
    expect(report.meanExact, greaterThan(0.999));
    expect(report.morphable, isTrue);
    expect(report.insideSafeArea, isTrue);
  });

  test('reads a rotation, a translation and a scale as group transforms', () {
    final converted = convertSvg(
      _svg('<g transform="translate(10,10)">'
          '<animateTransform attributeName="transform" type="rotate" dur="2s"'
          ' values="0;90" keyTimes="0;1"/>'
          '<rect width="20" height="20" fill="#000000"/></g>'),
      options: const Options(name: 'spin'),
    );
    expect(converted.drawable.durationMs, 2000);
    final spinning = converted.drawable.groups.where((g) => !g.rotation.isConstant);
    expect(spinning, hasLength(1));
    expect(spinning.single.rotation.keys.map((k) => k.value), [0, 90]);
    // `additive="replace"` is the default, so the animation replaces the
    // static transform rather than adding to it.
    expect(converted.drawable.groups.any((g) => g.translateX.first == 10), isFalse);
  });

  test('adds to the static transform when the animation says to', () {
    final converted = convertSvg(
      _svg('<g transform="translate(10,10)">'
          '<animateTransform attributeName="transform" type="scale" dur="1s" additive="sum"'
          ' values="1;2" keyTimes="0;1"/>'
          '<rect width="20" height="20" fill="#000000"/></g>'),
      options: const Options(name: 'grow'),
    );
    expect(converted.drawable.groups.any((g) => g.translateX.first == 10), isTrue);
    expect(converted.drawable.groups.any((g) => !g.scaleX.isConstant), isTrue);
  });

  test('inherits paint down the tree and honours fill="none"', () {
    final converted = convertSvg(
      _svg('<g fill="#112233"><rect width="10" height="10"/>'
          '<rect x="20" width="10" height="10" fill="none"/></g>'),
      options: const Options(name: 'inherit'),
    );
    final paths = XmlDocument.parse(converted.files['drawable/inherit_vector.xml']!)
        .findAllElements('path')
        .toList();
    expect(paths, hasLength(1), reason: 'a shape with no paint draws nothing');
    expect(paths.single.getAttribute('android:fillColor'), '#FF112233');
  });

  test('folds a group opacity into the paints below it', () {
    final converted = convertSvg(
      _svg('<g opacity="0.5"><rect width="10" height="10" fill="#000000" fill-opacity="0.5"/></g>'),
      options: const Options(name: 'faded'),
    );
    expect(converted.drawable.paths.single.paint.alpha.first, closeTo(0.25, 1e-9));
  });

  test('reads every colour form an SVG may use', () {
    int fill(String colour) => convertSvg(
          _svg('<rect width="10" height="10" fill="$colour"/>'),
          options: const Options(name: 'c'),
        ).drawable.paths.single.paint.color!;
    expect(fill('#f00'), 0xFFFF0000);
    expect(fill('#00ff00'), 0xFF00FF00);
    expect(fill('rgb(0,0,255)'), 0xFF0000FF);
    expect(fill('rgba(255,255,255,0.5)'), 0x80FFFFFF);
    expect(fill('rebeccapurple'), 0xFF663399);
    expect(fill('currentColor'), 0xFF000000);
  });

  test('turns every path command into the cubics a vector can morph', () {
    final unsupported = <String>{};
    // A line, a horizontal and vertical line, a shorthand cubic, a quadratic
    // and its shorthand, an arc, and a close - in relative and absolute form.
    final loops = parsePathData(
        'M10,10 H30 V30 L10,30 Z M40,10 c5,0 10,5 10,10 s-5,10 -10,10 '
        'q-10,0 -10,-10 t10,-10 a5,5 0 1 1 10,0 z',
        unsupported);
    expect(unsupported, isEmpty);
    expect(loops, hasLength(2));
    for (final loop in loops) {
      expect((loop.length - 1) % 3, 0, reason: 'a loop is a start point and whole cubics');
    }
    expect(loops.first.first.x, 10);
    expect(loops.first.first.y, 10);
  });

  test('says what it could not convert', () {
    final text = convertSvg(
      _svg('<rect width="10" height="10" fill="#000000"/><text x="0" y="0">hi</text>'),
      options: const Options(name: 't'),
    );
    expect(text.unsupported, contains('text elements'));

    final skewed = convertSvg(
      _svg('<g transform="skewX(20)"><rect width="10" height="10" fill="#000000"/></g>'),
      options: const Options(name: 's'),
    );
    expect(skewed.unsupported, contains('skewed transforms'));

    final colours = convertSvg(
      _svg('<rect width="10" height="10" fill="#000000">'
          '<animate attributeName="fill" dur="1s" values="#000000;#ffffff"/></rect>'),
      options: const Options(name: 'a'),
    );
    expect(colours.unsupported, contains('animated colours'));
  });

  test('rejects data that is not an SVG', () {
    expect(
        () => convertSvg(File('pubspec.yaml').readAsBytesSync()), throwsA(isA<FormatException>()));
    expect(() => convertSvg(Uint8List.fromList(utf8.encode('<html><body/></html>'))),
        throwsA(isA<FormatException>()));
  });

  test('keeps every path inside the resource string limit', () {
    // A compiled resource string holds fifteen bits of length, and a path that
    // overruns it comes back broken: the drawable fails to inflate and the
    // platform shows the launcher icon instead of the animation.
    final many = StringBuffer();
    for (var i = 0; i < 500; i++) {
      final x = 10.125 + i % 25, y = 10.375 + i ~/ 25;
      many.write('M$x,$y L${x + 1.25},$y L${x + 1.25},${y + 1.5} L$x,${y + 1.5} Z ');
    }
    final converted = convertSvg(
      _svg('<path d="$many" fill="#123456"/>'),
      options: const Options(name: 'long'),
    );
    expect(converted.unsupported, isEmpty);
    expect(converted.drawable.paths.length, greaterThan(1), reason: 'the path was split');
    for (final file in converted.files.values) {
      for (final match in RegExp('"([^"]*)"').allMatches(file)) {
        expect(match[1]!.length, lessThan(resourceStringLimit));
      }
    }
    for (final path in converted.drawable.paths) {
      expect(path.paint.color, 0xFF123456, reason: 'every part keeps the paint');
    }
  });

  test('reports the one shape that cannot be split', () {
    // Outlines nested inside each other are one shape under any fill rule, so
    // they cannot go to different paths; a single shape that overruns the
    // limit on its own is said out loud rather than written broken.
    final winding = StringBuffer('M0,0');
    for (var i = 0; i < 1500; i++) {
      winding.write(' C${i % 90}.123,${i % 70}.456 ${i % 80}.789,${i % 60}.321 '
          '${i % 95}.654,${i % 75}.987');
    }
    final converted = convertSvg(
      _svg('<path d="$winding Z" fill="#000000"/>'),
      options: const Options(name: 'huge'),
    );
    expect(converted.unsupported, contains('a shape too long for one Android resource string'));
  });

  test('writes a gradient as the fill and nothing else', () {
    final vector =
        convertSvg(logo, options: const Options(name: 'grad')).files['drawable/grad_vector.xml']!;
    for (final path in XmlDocument.parse(vector).findAllElements('path')) {
      final inline = path.childElements.any((child) => child.name.local == 'attr');
      // Both forms of the same attribute made the Android Gradle plugin fail
      // the build with `Cannot find attribute fillColor`.
      expect(inline && path.getAttribute('android:fillColor') != null, isFalse);
    }
  });
}
