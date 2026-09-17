import 'dart:math' as math;

import 'package:android_avd_splash/src/contour.dart';
import 'package:android_avd_splash/src/fit.dart';
import 'package:android_avd_splash/src/shape.dart';
import 'package:test/test.dart';

List<Point> circle(double r, int n, {double cx = 0, double cy = 0, double phase = 0}) => [
      for (var i = 0; i < n; i++)
        Point(cx + r * math.cos(phase + i / n * 2 * math.pi),
            cy + r * math.sin(phase + i / n * 2 * math.pi)),
    ];

void main() {
  test('resamples at uniform arc length', () {
    final points = resample(circle(20, 137), 64);
    final steps = [
      for (var i = 0; i < points.length; i++) (points[(i + 1) % points.length] - points[i]).length,
    ];
    expect(steps.reduce(math.max) - steps.reduce(math.min), lessThan(0.01));
  });

  test('aligns a loop to a rotated copy of itself', () {
    final reference = resample(circle(20, 200), 64);
    final rotated = circle(20, 200, phase: 2.0);
    final aligned = align(reference, rotated);
    // Alignment is a whole-sample shift, so half a sample of phase can remain.
    final step = 2 * math.pi * 20 / 64;
    for (var i = 0; i < aligned.length; i++) {
      expect((aligned[i] - reference[i]).length, lessThan(step / 2));
    }
  });

  test('recovers a known similarity transform', () {
    final from = resample(circle(10, 120), 48);
    final radians = 0.7, scale = 2.5;
    final to = [
      for (final p in from)
        Point(scale * (math.cos(radians) * p.x - math.sin(radians) * p.y) + 30,
            scale * (math.sin(radians) * p.x + math.cos(radians) * p.y) - 12),
    ];
    final fit = fitSimilarity(from, to)!;
    expect(fit.scale, closeTo(scale, 1e-9));
    expect(fit.radians, closeTo(radians, 1e-9));
    expect(fit.tx, closeTo(30, 1e-9));
    expect(fit.ty, closeTo(-12, 1e-9));
    expect(fit.residual, lessThan(1e-9));
  });

  test('fits a circle within a hundredth of a pixel', () {
    final samples = resample(circle(20, 400), 128);
    final knots = chooseKnots([samples], 8);
    expect(knots.length, 8);
    expect(fitError(fitSpans(samples, knots), samples, knots), lessThan(0.01));
  });

  test('puts a knot on every corner of a square', () {
    final side = [
      for (var i = 0; i < 40; i++) Point(i.toDouble(), 0),
      for (var i = 0; i < 40; i++) Point(40, i.toDouble()),
      for (var i = 0; i < 40; i++) Point(40 - i.toDouble(), 40),
      for (var i = 0; i < 40; i++) Point(0, 40 - i.toDouble()),
    ];
    final samples = resample(side, 160);
    final knots = chooseKnots([samples], 4);
    final corners = [for (final k in knots) samples[k]];
    for (final corner in corners) {
      expect(math.min((corner.x % 40).abs(), 40 - (corner.x % 40)), lessThan(1.5));
    }
    expect(fitError(fitSpans(samples, knots), samples, knots), lessThan(0.5));
  });
}
