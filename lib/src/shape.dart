import 'dart:math' as math;

import 'contour.dart';

/// Resamples a closed loop to [n] points at uniform arc length, starting at
/// arc-length offset [phase] (a fraction of the perimeter).
List<Point> resample(Loop loop, int n, {double phase = 0}) {
  final steps = <double>[];
  var total = 0.0;
  for (var i = 0; i < loop.length; i++) {
    final d = (loop[(i + 1) % loop.length] - loop[i]).length;
    steps.add(d);
    total += d;
  }
  if (total == 0) return List.filled(n, loop.first);
  final out = <Point>[];
  var index = 0, walked = 0.0;
  final target = phase * total;
  for (var k = 0; k < n; k++) {
    final want = (target + k * total / n) % total;
    while (want < walked) {
      index = 0;
      walked = 0.0;
    }
    while (index < steps.length && walked + steps[index] <= want) {
      walked += steps[index];
      index++;
    }
    if (index >= steps.length) {
      out.add(loop.first);
      continue;
    }
    final t = steps[index] == 0 ? 0.0 : (want - walked) / steps[index];
    final a = loop[index], b = loop[(index + 1) % loop.length];
    out.add(Point(a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)));
  }
  return out;
}

/// Resamples [loop] to `reference.length` points, choosing the cyclic offset
/// and winding direction that line the points up with [reference]. Without this
/// the morph between two frames would twist the outline around itself. The
/// offset is found on a decimated copy first, then refined, so cost stays
/// linear in the point count.
List<Point> align(List<Point> reference, Loop loop) {
  final n = reference.length;
  final forward = resample(loop, n);
  final backward = [forward.first, ...forward.reversed.take(n - 1)];
  final stride = math.max(1, n ~/ 48);

  double cost(List<Point> candidate, int shift, int step, double limit) {
    var sum = 0.0;
    for (var i = 0; i < n; i += step) {
      final p = candidate[(i + shift) % n], q = reference[i];
      final dx = p.x - q.x, dy = p.y - q.y;
      sum += dx * dx + dy * dy;
      if (sum >= limit) return double.infinity;
    }
    return sum;
  }

  var best = forward;
  var bestShift = 0;
  var bestCost = double.infinity;
  for (final candidate in [forward, backward]) {
    for (var shift = 0; shift < n; shift += stride) {
      final c = cost(candidate, shift, stride, bestCost);
      if (c < bestCost) {
        bestCost = c;
        best = candidate;
        bestShift = shift;
      }
    }
  }
  bestCost = double.infinity;
  var shift = bestShift;
  for (var s = bestShift - stride; s <= bestShift + stride; s++) {
    final c = cost(best, (s + n) % n, 1, bestCost);
    if (c < bestCost) {
      bestCost = c;
      shift = (s + n) % n;
    }
  }
  return [for (var i = 0; i < n; i++) best[(i + shift) % n]];
}

/// A translation, uniform scale and rotation - everything a VectorDrawable
/// `<group>` can animate without touching path data.
class Similarity {
  Similarity(this.scale, this.radians, this.tx, this.ty, this.residual);

  final double scale;
  final double radians;
  final double tx;
  final double ty;

  /// Root-mean-square distance, in pixels, between the transformed source and
  /// the target points.
  final double residual;

  static final identity = Similarity(1, 0, 0, 0, 0);

  double get degrees => radians * 180 / math.pi;

  Point apply(Point p) {
    final c = math.cos(radians) * scale, s = math.sin(radians) * scale;
    return Point(c * p.x - s * p.y + tx, s * p.x + c * p.y + ty);
  }

  /// Maps a point back into the space this transform came from.
  Point unapply(Point p) {
    if (scale.abs() < 1e-12) return const Point(0, 0);
    final c = math.cos(radians) / scale, s = math.sin(radians) / scale;
    final x = p.x - tx, y = p.y - ty;
    return Point(c * x + s * y, -s * x + c * y);
  }

  /// Linear blend, the way an animated `<group>` interpolates its properties.
  static Similarity lerp(Similarity a, Similarity b, double t) => Similarity(
        a.scale + (b.scale - a.scale) * t,
        a.radians + (b.radians - a.radians) * t,
        a.tx + (b.tx - a.tx) * t,
        a.ty + (b.ty - a.ty) * t,
        0,
      );
}

/// Least-squares similarity transform taking [from] onto [to] (Umeyama).
/// Returns null when the best fit needs a reflection, which a `<group>` cannot
/// express as a single animated rotation.
Similarity? fitSimilarity(List<Point> from, List<Point> to) {
  final n = from.length;
  if (n == 0 || n != to.length) return null;
  var fx = 0.0, fy = 0.0, tx = 0.0, ty = 0.0;
  for (var i = 0; i < n; i++) {
    fx += from[i].x;
    fy += from[i].y;
    tx += to[i].x;
    ty += to[i].y;
  }
  fx /= n;
  fy /= n;
  tx /= n;
  ty /= n;
  var sxx = 0.0, sxy = 0.0, varFrom = 0.0;
  for (var i = 0; i < n; i++) {
    final ax = from[i].x - fx, ay = from[i].y - fy;
    final bx = to[i].x - tx, by = to[i].y - ty;
    sxx += ax * bx + ay * by;
    sxy += ax * by - ay * bx;
    varFrom += ax * ax + ay * ay;
  }
  if (varFrom < 1e-12) return null;
  final scale = math.sqrt(sxx * sxx + sxy * sxy) / varFrom;
  final radians = math.atan2(sxy, sxx);
  if (scale < 1e-9) return null;
  final c = math.cos(radians) * scale, s = math.sin(radians) * scale;
  final transform = Similarity(scale, radians, tx - (c * fx - s * fy), ty - (s * fx + c * fy), 0);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final p = transform.apply(from[i]);
    final dx = p.x - to[i].x, dy = p.y - to[i].y;
    sum += dx * dx + dy * dy;
  }
  return Similarity(scale, radians, transform.tx, transform.ty, math.sqrt(sum / n));
}
