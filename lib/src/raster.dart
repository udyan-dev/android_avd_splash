import 'dart:math' as math;
import 'dart:typed_data';

import 'contour.dart';

/// Fills the loops of one path into a pixel mask, testing pixel centres - the
/// same question the GIF answers for every pixel. Separate paths must be
/// rasterised separately and combined, or overlapping ones would cancel instead
/// of painting over each other.
///
/// [nonZero] selects the winding rule instead of even-odd, which is what a
/// `<clip-path>` always uses on Android.
Uint8List rasterise(List<List<Point>> loops, int w, int h, {bool nonZero = false}) {
  // Edges bucketed by their first row, walked with an active list: the cost is
  // the edges plus the spans they cover, not the whole canvas per shape.
  final mask = Uint8List(w * h);
  final x0 = <double>[], y0 = <double>[], x1 = <double>[], y1 = <double>[];
  var top = h, bottom = -1;
  for (final loop in loops) {
    for (var i = 0; i < loop.length; i++) {
      final a = loop[i], b = loop[(i + 1) % loop.length];
      if (a.y == b.y) continue;
      x0.add(a.x);
      y0.add(a.y);
      x1.add(b.x);
      y1.add(b.y);
      final lo = (math.min(a.y, b.y) - 0.5).ceil();
      final hi = (math.max(a.y, b.y) - 0.5).floor();
      if (lo < top) top = lo;
      if (hi > bottom) bottom = hi;
    }
  }
  if (bottom < 0) return mask;
  top = top < 0 ? 0 : top;
  bottom = bottom > h - 1 ? h - 1 : bottom;

  final starting = List<List<int>?>.filled(bottom - top + 1, null);
  for (var e = 0; e < x0.length; e++) {
    final lo = (math.min(y0[e], y1[e]) - 0.5).ceil().clamp(top, bottom + 1);
    if (lo > bottom) continue;
    (starting[lo - top] ??= <int>[]).add(e);
  }

  final active = <int>[];
  final crossings = <double>[];
  final directions = <int>[];
  for (var y = top; y <= bottom; y++) {
    final cy = y + 0.5;
    final arriving = starting[y - top];
    if (arriving != null) active.addAll(arriving);
    active.removeWhere((e) => math.max(y0[e], y1[e]) <= cy);
    if (active.isEmpty) continue;
    crossings.clear();
    directions.clear();
    for (final e in active) {
      final down = y0[e] <= cy && y1[e] > cy;
      if (!down && !(y1[e] <= cy && y0[e] > cy)) continue;
      crossings.add(x0[e] + (cy - y0[e]) / (y1[e] - y0[e]) * (x1[e] - x0[e]));
      directions.add(down ? 1 : -1);
    }
    if (crossings.isEmpty) continue;
    final order = List<int>.generate(crossings.length, (i) => i)
      ..sort((a, b) => crossings[a].compareTo(crossings[b]));
    final row = y * w;
    var winding = 0;
    for (var i = 0; i + 1 < order.length; i++) {
      winding += nonZero ? directions[order[i]] : 1;
      final filled = nonZero ? winding != 0 : winding.isOdd;
      if (!filled) continue;
      final from = (crossings[order[i]] - 0.5).ceil().clamp(0, w - 1);
      final to = (crossings[order[i + 1]] - 0.5).floor().clamp(-1, w - 1);
      for (var x = from; x <= to; x++) {
        mask[row + x] = 1;
      }
    }
  }
  return mask;
}

/// Intersection over union of two masks.
double iou(Uint8List a, Uint8List b) {
  var both = 0, either = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != 0 || b[i] != 0) {
      either++;
      if (a[i] != 0 && b[i] != 0) both++;
    }
  }
  return either == 0 ? 1.0 : both / either;
}

/// Intersection over union that forgives a one-pixel edge shift: a pixel
/// counts as matched when the other mask has it in the 8-neighbourhood. GIF
/// edges are whole pixels, so a sub-pixel outline can never match exactly.
double tolerantIou(Uint8List a, Uint8List b, int w, int h) {
  final grownA = _grow(a, w, h), grownB = _grow(b, w, h);
  var both = 0, either = 0;
  for (var i = 0; i < a.length; i++) {
    final inA = a[i] != 0, inB = b[i] != 0;
    if (!inA && !inB) continue;
    either++;
    if ((inA && grownB[i] != 0) || (inB && grownA[i] != 0)) both++;
  }
  return either == 0 ? 1.0 : both / either;
}

/// One pixel of dilation, as two passes of three: the same 8-neighbourhood at
/// a third of the work.
Uint8List _grow(Uint8List mask, int w, int h) {
  final rows = Uint8List(mask.length);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      if (mask[row + x] == 0) continue;
      rows[row + x] = 1;
      if (x > 0) rows[row + x - 1] = 1;
      if (x < w - 1) rows[row + x + 1] = 1;
    }
  }
  final out = Uint8List(mask.length);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      if (rows[row + x] == 0) continue;
      out[row + x] = 1;
      if (y > 0) out[row - w + x] = 1;
      if (y < h - 1) out[row + w + x] = 1;
    }
  }
  return out;
}
