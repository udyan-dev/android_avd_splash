import 'dart:math' as math;

import 'contour.dart';

/// A closed cubic outline: `[start, c1, c2, end, c1, c2, end, ...]`, the final
/// point equal to the first. Every frame of a morphing path is fitted with the
/// same knots, which is what makes its path data morphable.
typedef Curve = List<Point>;

/// Picks [segments] knot positions shared by every frame of one outline.
/// Corners come first, since a cubic cannot round one off, and a corner is kept
/// if any frame has it there - the samples correspond point for point, so an
/// index means the same place on the outline in every frame. The rest of the
/// knots are spread evenly in index space, which is even arc length in every
/// frame at once.
List<int> chooseKnots(List<List<Point>> frames, int segments) {
  final n = frames.first.length;
  final window = math.max(1, n ~/ 48);
  final angles = List<double>.filled(n, 0);
  for (final samples in frames) {
    for (var i = 0; i < n; i++) {
      final a = samples[i] - samples[(i - window + n) % n];
      final b = samples[(i + window) % n] - samples[i];
      if (a.length < 1e-9 || b.length < 1e-9) continue;
      final turn = math.atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y).abs();
      if (turn > angles[i]) angles[i] = turn;
    }
  }
  final corners = <int>[];
  for (var i = 0; i < n; i++) {
    if (angles[i] < 0.9) continue; // less than ~50 degrees of turn is not a corner
    var peak = true;
    for (var d = -window; d <= window && peak; d++) {
      if (angles[(i + d + n) % n] > angles[i]) peak = false;
    }
    if (peak) corners.add(i);
  }
  corners.sort((a, b) => angles[b].compareTo(angles[a]));
  final knots = corners.take(segments).toList()..sort();
  if (knots.isEmpty) knots.add(0);

  // Halve the widest gap until the wanted segment count is reached.
  while (knots.length < segments) {
    var at = 0, widest = -1;
    for (var i = 0; i < knots.length; i++) {
      final gap = knots.length == 1 ? n : (knots[(i + 1) % knots.length] - knots[i] + n) % n;
      if (gap > widest) {
        widest = gap;
        at = i;
      }
    }
    if (widest < 6) break;
    knots.insert(at + 1, (knots[at] + widest ~/ 2) % n);
    knots.sort();
  }
  return knots;
}

/// Least-squares cubic through each knot span of an arc-length sampled loop.
Curve fitSpans(List<Point> samples, List<int> knots) {
  final n = samples.length;
  final out = <Point>[samples[knots.first]];
  for (var k = 0; k < knots.length; k++) {
    final start = knots[k], span = (knots[(k + 1) % knots.length] - start + n) % n;
    final p0 = samples[start], p3 = samples[(start + span) % n];
    var c11 = 0.0, c12 = 0.0, c22 = 0.0, x1x = 0.0, x1y = 0.0, x2x = 0.0, x2y = 0.0;
    for (var j = 1; j < span; j++) {
      final t = j / span, u = 1 - t;
      final a1 = 3 * u * u * t, a2 = 3 * u * t * t;
      final q = samples[(start + j) % n];
      final rx = q.x - u * u * u * p0.x - t * t * t * p3.x;
      final ry = q.y - u * u * u * p0.y - t * t * t * p3.y;
      c11 += a1 * a1;
      c12 += a1 * a2;
      c22 += a2 * a2;
      x1x += a1 * rx;
      x1y += a1 * ry;
      x2x += a2 * rx;
      x2y += a2 * ry;
    }
    final det = c11 * c22 - c12 * c12;
    final c1 = det.abs() < 1e-12
        ? p0 + (p3 - p0) * (1 / 3)
        : Point((c22 * x1x - c12 * x2x) / det, (c22 * x1y - c12 * x2y) / det);
    final c2 = det.abs() < 1e-12
        ? p0 + (p3 - p0) * (2 / 3)
        : Point((c11 * x2x - c12 * x1x) / det, (c11 * x2y - c12 * x1y) / det);
    out.addAll([c1, c2, p3]);
  }
  return out;
}

/// Root-mean-square distance between a fitted curve and the samples it came
/// from. A contour traced from a handful of pixels is itself ragged, so the
/// worst single sample is not a useful budget - the average is.
double fitError(Curve curve, List<Point> samples, List<int> knots) {
  final n = samples.length;
  var sum = 0.0;
  var count = 0;
  for (var k = 0; k < knots.length; k++) {
    final start = knots[k], span = (knots[(k + 1) % knots.length] - start + n) % n;
    final p0 = curve[k * 3], c1 = curve[k * 3 + 1], c2 = curve[k * 3 + 2], p3 = curve[k * 3 + 3];
    for (var j = 1; j < span; j++) {
      final t = j / span, u = 1 - t;
      final b = p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p3 * (t * t * t);
      final d = (b - samples[(start + j) % n]).length;
      sum += d * d;
      count++;
    }
  }
  return count == 0 ? 0 : math.sqrt(sum / count);
}

/// Flattens a curve into a polyline, [perSegment] steps per cubic.
List<Point> flatten(Curve curve, {int perSegment = 16}) {
  final out = <Point>[];
  for (var s = 0; s < (curve.length - 1) ~/ 3; s++) {
    final p0 = curve[s * 3], c1 = curve[s * 3 + 1], c2 = curve[s * 3 + 2], p3 = curve[s * 3 + 3];
    for (var j = 0; j < perSegment; j++) {
      final t = j / perSegment, u = 1 - t;
      out.add(p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p3 * (t * t * t));
    }
  }
  return out;
}
