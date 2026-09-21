import 'dart:math' as math;

import 'package:android_avd_splash/src/contour.dart';
import 'package:android_avd_splash/src/fit.dart';
import 'package:android_avd_splash/src/stroke.dart';
import 'package:android_avd_splash/src/trim.dart';
import 'package:test/test.dart';

/// A circle of [radius] as the four cubics every renderer draws one with,
/// starting at the top and turning clockwise - which is where a trim starts
/// measuring from.
Curve _circle(double radius) {
  const k = 0.55228;
  final h = radius * k;
  return [
    Point(0, -radius),
    Point(h, -radius),
    Point(radius, -h),
    Point(radius, 0),
    Point(radius, h),
    Point(h, radius),
    Point(0, radius),
    Point(-h, radius),
    Point(-radius, h),
    Point(-radius, 0),
    Point(-radius, -h),
    Point(-h, -radius),
    Point(0, -radius),
  ];
}

double _length(List<Point> line) {
  var total = 0.0;
  for (var i = 1; i < line.length; i++) {
    total += (line[i] - line[i - 1]).length;
  }
  return total;
}

List<Point> _live(List<Point> line) {
  final out = <Point>[];
  for (final point in line) {
    if (out.isEmpty || (point - out.last).length > 1e-6) out.add(point);
  }
  return out;
}

void main() {
  final circle = _circle(50);
  final circumference = 2 * math.pi * 50;

  group('trim', () {
    test('cuts the length the window asks for, wherever the window is', () {
      for (final window in [
        (0.0, 0.1, 0.0),
        (0.25, 0.5, 0.0),
        (0.0, 0.1, -0.7139),
        (0.4, 0.45, 0.35),
      ]) {
        final cut = trimPieces([circle], window.$1, window.$2, window.$3);
        final walked = cut.fold(0.0, (sum, curve) => sum + _length(_live(flatten(curve))));
        expect(walked, closeTo((window.$2 - window.$1) * circumference, circumference * 0.02),
            reason: 'trim ${window.$1}..${window.$2} offset ${window.$3}');
      }
    });

    test('keeps a command for every command, so the outline still morphs', () {
      final cut = trimCurves([circle], 0.2, 0.3, 0);
      expect(cut, hasLength(1));
      expect(cut.single.length, circle.length,
          reason: 'a cubic the window misses collapses to a point rather than going away');
    });

    test('hands back two arcs when the window wraps past the end', () {
      // A stroke draws two arcs with a gap, and one outline cannot hold that.
      expect(trimPieces([circle], 0.9, 1.1, 0), hasLength(2));
      expect(trimPieces([circle], 0.1, 0.4, 0), hasLength(1));
    });

    test('a window that covers everything is the path itself', () {
      expect(trimCurves([circle], 0, 1, 0).single, same(circle));
      expect(trimPieces([circle], 0, 1, 0.5).single, same(circle));
    });
  });

  group('stroke', () {
    test('covers half its width to either side of a closed outline', () {
      final bands = strokeBands(flatten(circle), 20, closed: true);
      expect(bands, hasLength(2), reason: 'a ring: the outline pushed out and pulled in');
      final radii = [
        for (final band in bands) band.fold(0.0, (worst, p) => math.max(worst, p.length)),
      ];
      expect(radii.reduce(math.max), closeTo(60, 0.5));
      expect(radii.reduce(math.min), closeTo(40, 0.5));
    });

    test('runs out and back along an open outline', () {
      final band = strokeBands([const Point(0, 0), const Point(100, 0)], 10, closed: false);
      expect(band, hasLength(1));
      final ys = band.single.map((p) => p.y);
      expect(ys.reduce(math.max), closeTo(5, 1e-9));
      expect(ys.reduce(math.min), closeTo(-5, 1e-9));
    });

    test('says nothing where there is nothing to draw', () {
      expect(strokeBands([const Point(0, 0), const Point(1, 0)], 0, closed: false), isEmpty);
      expect(strokeBands([const Point(2, 2), const Point(2, 2)], 4, closed: false), isEmpty,
          reason: 'a trim collapses what it cuts away onto a point');
    });
  });
}
