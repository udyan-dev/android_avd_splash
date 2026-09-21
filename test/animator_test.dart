import 'dart:io';

import 'package:android_avd_splash/android_avd_splash.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

/// The rules that decide whether the platform plays the animation that was
/// converted, rather than one of its own. Every one of them is something
/// `AnimatorInflater` or `KeyframeSet` does silently.
void main() {
  final sources = {
    'lottie': convertLottie(File('test/fixtures/flutter_logo.json').readAsBytesSync(),
        options: const Options(name: 'a')),
    'matte': convertLottie(File('test/fixtures/matte.json').readAsBytesSync(),
        options: const Options(name: 'b')),
    'svg': convertSvg(File('test/fixtures/logo.svg').readAsBytesSync(),
        options: const Options(name: 'c')),
    'gif': generate(File('test/fixtures/shapes.gif').readAsBytesSync(),
        options: const Options(name: 'd')),
    'reverse trim': convertLottie(File('test/fixtures/reverse_trim.json').readAsBytesSync(),
        options: const Options(name: 'e')),
  };

  sources.forEach((kind, generated) {
    test('$kind: every animator says its own timeline is not bent', () {
      final animators = generated.files.entries.where((e) => e.key.startsWith('animator/'));
      expect(animators, isNotEmpty);
      for (final entry in animators) {
        for (final animator
            in XmlDocument.parse(entry.value).rootElement.findAllElements('objectAnimator')) {
          // Left out, `android:interpolator` is accelerate-decelerate, which
          // warps the whole track before a keyframe is ever consulted. A step
          // that ends where it began has nothing for it to warp.
          if (animator.getAttribute('android:valueFrom') ==
              animator.getAttribute('android:valueTo')) {
            continue;
          }
          expect(animator.getAttribute('android:interpolator'), isNotNull,
              reason: '${entry.key}: an animator with no interpolator is eased by the platform');
        }
        final root = XmlDocument.parse(entry.value).rootElement;
        if (root.name.local == 'objectAnimator') {
          expect(root.getAttribute('android:interpolator'), '@android:anim/linear_interpolator');
        }
      }
    });

    test('$kind: no two keyframes share a fraction', () {
      for (final entry in generated.files.entries.where((e) => e.key.startsWith('animator/'))) {
        for (final holder
            in XmlDocument.parse(entry.value).rootElement.findAllElements('propertyValuesHolder')) {
          final fractions = [
            for (final key in holder.findElements('keyframe'))
              double.parse(key.getAttribute('android:fraction')!),
          ];
          // `KeyframeSet` divides by the gap between the keyframes around a
          // fraction, so two at one fraction are a zero to divide by.
          expect(fractions.toSet().length, fractions.length, reason: entry.key);
          for (var i = 1; i < fractions.length; i++) {
            expect(fractions[i], greaterThan(fractions[i - 1]), reason: entry.key);
          }
        }
      }
    });

    test('$kind: one interpolator resource per distinct curve', () {
      final interpolators = {
        for (final entry in generated.files.entries)
          if (entry.key.startsWith('interpolator/')) entry.key: entry.value,
      };
      expect(interpolators.values.toSet().length, interpolators.length,
          reason: 'the same curve was written to more than one file');
    });

    test('$kind: what a target starts on is what the drawable already holds', () {
      final name = generated.files.keys
          .firstWhere((f) => f.startsWith('drawable/') && !f.endsWith('_vector.xml'))
          .replaceFirst('drawable/', '')
          .replaceFirst('.xml', '');
      final vector = XmlDocument.parse(generated.files['drawable/${name}_vector.xml']!).rootElement;
      final nodes = {
        for (final node in vector.descendantElements)
          if (node.getAttribute('android:name') != null) node.getAttribute('android:name')!: node,
      };
      for (final target in XmlDocument.parse(generated.files['drawable/$name.xml']!)
          .rootElement
          .findElements('target')) {
        final node = nodes[target.getAttribute('android:name')!]!;
        final animator = XmlDocument.parse(generated
                .files['animator/${target.getAttribute('android:animation')!.substring(10)}.xml']!)
            .rootElement;
        for (final holder in animator.findAllElements('propertyValuesHolder')) {
          final property = holder.getAttribute('android:propertyName')!;
          final first = holder.findElements('keyframe').first;
          expect(double.parse(first.getAttribute('android:fraction')!), 0);
          final declared = node.getAttribute('android:$property');
          if (declared == null) continue;
          expect(double.parse(declared),
              closeTo(double.parse(first.getAttribute('android:value')!), 1e-4),
              reason: '${target.getAttribute('android:name')}.$property jumps when the '
                  'animation starts');
        }
        final steps = animator.findElements('objectAnimator').toList();
        if (steps.isEmpty || animator.name.local != 'set') continue;
        final declared = node.getAttribute('android:pathData');
        if (declared != null) {
          expect(declared, steps.first.getAttribute('android:valueFrom'),
              reason: 'the shape jumps when the animation starts');
        }
      }
    });
  });

  test('a morph set runs for exactly as long as the drawable', () {
    sources.forEach((kind, generated) {
      final length = generated.drawable.durationMs;
      for (final entry in generated.files.entries.where((e) => e.key.startsWith('animator/'))) {
        final root = XmlDocument.parse(entry.value).rootElement;
        if (root.name.local != 'set') continue;
        final total = root
            .findElements('objectAnimator')
            .fold(0, (sum, step) => sum + int.parse(step.getAttribute('android:duration')!));
        expect(total, length, reason: '$kind ${entry.key}');
      }
    });
  });

  test('a cut keyframe interval keeps the curve it was drawn with', () {
    const easing = Easing(0.42, 0, 0.58, 1);
    for (final at in [0.17, 0.5, 0.83]) {
      final (before, after) = easing.split(at);
      for (var i = 0; i <= 20; i++) {
        final x = i / 20;
        expect(before(x) * easing(at), closeTo(easing(x * at), 1e-3),
            reason: 'the first part read on its own');
        expect(easing(at) + after(x) * (1 - easing(at)), closeTo(easing(at + x * (1 - at)), 1e-3),
            reason: 'the second part read on its own');
      }
    }
    expect(Easing.linear.split(0.4).$1.isLinear, isTrue);
    expect(Easing.hold.split(0.4).$2.isHold, isTrue);
  });

  test('a trim never asks the platform to draw the wrong side of the path', () {
    // `VectorDrawable` reads a start past its end as a window across the seam
    // and draws the rest of the outline; Lottie draws the piece between the
    // two. Whatever the source says, what is written has to be in order.
    sources.forEach((kind, generated) {
      for (final entry in generated.files.entries.where((e) => e.key.startsWith('animator/'))) {
        final root = XmlDocument.parse(entry.value).rootElement;
        final holders = {
          for (final holder in root.findAllElements('propertyValuesHolder'))
            holder.getAttribute('android:propertyName')!: [
              for (final key in holder.findElements('keyframe'))
                (
                  double.parse(key.getAttribute('android:fraction')!),
                  double.parse(key.getAttribute('android:value')!),
                ),
            ],
        };
        final starts = holders['trimPathStart'], ends = holders['trimPathEnd'];
        if (starts == null && ends == null) continue;
        final name = entry.key.replaceFirst('animator/', '').replaceFirst('_paint.xml', '');
        final vector = XmlDocument.parse(
                generated.files.entries.firstWhere((e) => e.key.endsWith('_vector.xml')).value)
            .rootElement;
        final node = vector.descendantElements
            .firstWhere((element) => element.getAttribute('android:name') == name);
        double held(String attribute, double fallback) =>
            double.parse(node.getAttribute('android:$attribute') ?? '$fallback');
        double read(List<(double, double)>? keys, String attribute, double fallback, double at) {
          if (keys == null) return held(attribute, fallback);
          for (var i = 1; i < keys.length; i++) {
            if (at <= keys[i].$1) {
              final (a, b) = (keys[i - 1], keys[i]);
              final length = b.$1 - a.$1;
              return length <= 0 ? b.$2 : a.$2 + (b.$2 - a.$2) * (at - a.$1) / length;
            }
          }
          return keys.last.$2;
        }

        for (var step = 0; step <= 200; step++) {
          final at = step / 200;
          final from = read(starts, 'trimPathStart', 0, at);
          final to = read(ends, 'trimPathEnd', 1, at);
          expect(from, lessThanOrEqualTo(to + 1e-6),
              reason: '$kind ${entry.key}: the platform would draw the complement at $at');
        }
      }
    });
  });

  test('only a contour that comes back to its start is closed', () {
    sources.forEach((kind, generated) {
      final vector = XmlDocument.parse(
              generated.files.entries.firstWhere((e) => e.key.endsWith('_vector.xml')).value)
          .rootElement;
      for (final node in vector.descendantElements) {
        final data = node.getAttribute('android:pathData');
        if (data == null) continue;
        for (final contour in data.split('m').skip(1)) {
          if (!contour.contains('z')) continue;
          var x = 0.0, y = 0.0;
          for (final segment in contour.split('z').first.split('c').skip(1)) {
            final numbers = [
              for (final match in RegExp(r'-?\d+(?:\.\d+)?').allMatches(segment))
                double.parse(match.group(0)!),
            ];
            // A cubic is two handles and an end point; only the end moves the
            // pen.
            if (numbers.length < 6) continue;
            x += numbers[4];
            y += numbers[5];
          }
          expect(x.abs() + y.abs(), lessThan(0.01),
              reason: '$kind: a closed contour ends where it started, or the '
                  'stroke draws a chord and a spike across it');
        }
      }
    });
  });

  test('a vector animation does not open or close on an empty screen', () {
    final blank = convertLottie(File('test/fixtures/matte.json').readAsBytesSync(),
        options: const Options(name: 'e'));
    final whole = convertLottie(File('test/fixtures/matte.json').readAsBytesSync(),
        options: const Options(name: 'e', trim: false));
    expect(blank.drawable.durationMs, lessThan(whole.drawable.durationMs));
    expect(checkVector(blank).meanExact, greaterThan(0.999));
  });
}
