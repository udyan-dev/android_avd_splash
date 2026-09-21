import 'dart:math' as math;

import 'contour.dart';
import 'fit.dart';

/// Cuts [curves] down to the arc-length window `[start, end]`, both fractions
/// of the total length, rotated by [offset] turns.
///
/// Android's `trimPathStart` and `trimPathEnd` only affect stroking, so a
/// Lottie trim on a filled shape has to be cut into the geometry instead. Each
/// cubic of the original comes back as exactly one cubic - split with de
/// Casteljau where the window crosses it, collapsed to a point where the window
/// misses it - so the command structure never changes and the result can still
/// morph from frame to frame.
/// The live pieces of [curves] under the same window, as separate outlines.
///
/// A window that wraps past the end of the path leaves two arcs with a gap
/// between them, and a stroke draws exactly that. One outline cannot hold two
/// arcs without a gap, so this hands back one outline per arc - which is what
/// anything measuring or rasterising a stroke needs, while a trim baked into a
/// *fill* stays one outline and closes across.
List<Curve> trimPieces(List<Curve> curves, double start, double end, double offset) {
  var lo = math.min(start, end) + offset, hi = math.max(start, end) + offset;
  final span = hi - lo;
  if (span >= 1 - 1e-9) return curves;
  lo -= lo.floor();
  hi = lo + span;
  if (hi <= 1) return trimCurves(curves, lo, hi, 0);
  return [
    ...trimCurves(curves, lo, 1, 0),
    ...trimCurves(curves, 0, hi - 1, 0),
  ];
}

/// The arc a `VectorDrawable` stroke draws for these attributes.
///
/// The platform adds the offset, wraps each end into one turn, and reads a
/// start that has run past its end as a window across the seam - the rest of
/// the outline, which is the complement of what Lottie draws for the same
/// pair. Only a pair already in order means the same thing to both, and only
/// a plain `0`..`1` is the whole outline: any other full turn leaves the two
/// ends on the same point and draws nothing at all.
List<Curve> trimAndroid(List<Curve> curves, double start, double end, double offset) {
  if (start == 0 && end == 1) return curves;
  final from = _turn(start + offset), to = _turn(end + offset);
  if (from > to) {
    return [...trimCurves(curves, from, 1, 0), ...trimCurves(curves, 0, to, 0)];
  }
  return trimCurves(curves, from, to, 0);
}

double _turn(double value) {
  final wrapped = value % 1;
  return wrapped < 0 ? wrapped + 1 : wrapped;
}

List<Curve> trimCurves(List<Curve> curves, double start, double end, double offset) {
  var lo = math.min(start, end) + offset, hi = math.max(start, end) + offset;
  final span = hi - lo;
  if (span >= 1 - 1e-9) return curves;

  final total = _total(curves);
  if (total <= 0) return curves;
  lo -= lo.floor();
  hi = lo + span;
  final windows = hi <= 1
      ? [
          [lo, hi],
        ]
      : [
          [lo, 1.0],
          [0.0, hi - 1],
        ];

  // Where the window begins and ends on the path, as points: a cubic the
  // window misses collapses onto the nearer of them, so the outline keeps its
  // commands without wandering away from what is left of the path.
  final segments = <List<Point>>[];
  final spans = <(double, double)>[];
  var measured = 0.0;
  for (final curve in curves) {
    for (var s = 0; s < (curve.length - 1) ~/ 3; s++) {
      final segment = [curve[s * 3], curve[s * 3 + 1], curve[s * 3 + 2], curve[s * 3 + 3]];
      final length = _length(segment);
      segments.add(segment);
      spans.add((measured / total, (measured + length) / total));
      measured += length;
    }
  }

  Point at(double fraction) {
    for (var i = 0; i < segments.length; i++) {
      final (from, to) = spans[i];
      if (fraction <= to || i == segments.length - 1) {
        final inside = to - from <= 0 ? 0.0 : (fraction - from) / (to - from);
        return _at(segments[i], _parameterAt(segments[i], inside.clamp(0.0, 1.0)));
      }
    }
    return segments.last[3];
  }

  final edges = <(double, Point)>[
    for (final window in windows)
      for (final edge in window) (edge, at(edge)),
  ];

  final out = <Curve>[];
  var index = 0;
  for (final curve in curves) {
    final cubics = (curve.length - 1) ~/ 3;
    final trimmed = <Point>[];
    for (var s = 0; s < cubics; s++) {
      final segment = segments[index];
      final (from, to) = spans[index];
      index++;

      // The window this cubic overlaps most; a cubic rarely straddles the wrap.
      var bestFrom = 0.0, bestTo = 0.0, best = 0.0;
      for (final window in windows) {
        final a = math.max(from, window[0]), b = math.min(to, window[1]);
        if (b - a > best) {
          best = b - a;
          bestFrom = a;
          bestTo = b;
        }
      }
      final List<Point> piece;
      if (best <= 0 || to - from <= 0) {
        var nearest = edges.first;
        var distance = double.infinity;
        for (final edge in edges) {
          final away = edge.$1 < from ? from - edge.$1 : (edge.$1 > to ? edge.$1 - to : 0.0);
          if (away < distance) {
            distance = away;
            nearest = edge;
          }
        }
        piece = [nearest.$2, nearest.$2, nearest.$2, nearest.$2];
      } else {
        final t0 = _parameterAt(segment, (bestFrom - from) / (to - from));
        final t1 = _parameterAt(segment, (bestTo - from) / (to - from));
        piece = _slice(segment, t0, t1);
      }
      if (trimmed.isEmpty) trimmed.add(piece[0]);
      trimmed.addAll([piece[1], piece[2], piece[3]]);
    }
    if (trimmed.length >= 4) out.add(trimmed);
  }
  return out;
}

double _total(List<Curve> curves) {
  var total = 0.0;
  for (final curve in curves) {
    for (var s = 0; s < (curve.length - 1) ~/ 3; s++) {
      total += _length([curve[s * 3], curve[s * 3 + 1], curve[s * 3 + 2], curve[s * 3 + 3]]);
    }
  }
  return total;
}

/// The part of a cubic between two parameters, by de Casteljau twice.
List<Point> _slice(List<Point> segment, double t0, double t1) {
  final tail = t0 <= 0 ? segment : _after(segment, t0);
  if (t1 >= 1) return tail;
  final remaining = 1 - t0;
  return _before(tail, remaining <= 0 ? 1 : ((t1 - t0) / remaining).clamp(0.0, 1.0));
}

/// The parameter where a cubic reaches [fraction] of its own arc length.
double _parameterAt(List<Point> segment, double fraction) {
  if (fraction <= 0) return 0;
  if (fraction >= 1) return 1;
  const steps = 24;
  var previous = segment[0];
  final lengths = <double>[0];
  for (var i = 1; i <= steps; i++) {
    final point = _at(segment, i / steps);
    lengths.add(lengths.last + (point - previous).length);
    previous = point;
  }
  final want = lengths.last * fraction;
  for (var i = 1; i <= steps; i++) {
    if (lengths[i] >= want) {
      final span = lengths[i] - lengths[i - 1];
      final t = span <= 0 ? 0.0 : (want - lengths[i - 1]) / span;
      return (i - 1 + t) / steps;
    }
  }
  return 1;
}

double _length(List<Point> segment) {
  var sum = 0.0;
  var previous = segment[0];
  for (var i = 1; i <= 24; i++) {
    final point = _at(segment, i / 24);
    sum += (point - previous).length;
    previous = point;
  }
  return sum;
}

Point _at(List<Point> s, double t) {
  final u = 1 - t;
  return s[0] * (u * u * u) + s[1] * (3 * u * u * t) + s[2] * (3 * u * t * t) + s[3] * (t * t * t);
}

List<Point> _after(List<Point> s, double t) {
  final a = s[0] + (s[1] - s[0]) * t;
  final b = s[1] + (s[2] - s[1]) * t;
  final c = s[2] + (s[3] - s[2]) * t;
  final d = a + (b - a) * t;
  final e = b + (c - b) * t;
  return [d + (e - d) * t, e, c, s[3]];
}

List<Point> _before(List<Point> s, double t) {
  final a = s[0] + (s[1] - s[0]) * t;
  final b = s[1] + (s[2] - s[1]) * t;
  final c = s[2] + (s[3] - s[2]) * t;
  final d = a + (b - a) * t;
  final e = b + (c - b) * t;
  return [s[0], a, d, d + (e - d) * t];
}
