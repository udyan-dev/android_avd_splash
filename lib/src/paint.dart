import 'dart:math' as math;

import 'contour.dart';
import 'fit.dart';
import 'gif.dart';
import 'model.dart';
import 'raster.dart';

/// Reads the colours the GIF actually painted inside [loops] and decides
/// whether the path needs a gradient. A linear model of position is fitted per
/// channel; a gradient is only worth writing when it explains what a single
/// colour cannot.
///
/// Null where the region is not this layer's artwork at all: the colours
/// inside it belong to another paint in [palette]. A pixel where two paints
/// meet is a blend of both, and a blend can be nearer a third colour than
/// either - light grey under green reads as olive - so the separation hands
/// it to whichever paint's own axis it happens to lie along. Measuring the
/// pixels is what catches it, and dropping the region uncovers the paint that
/// was always underneath.
Paint? fitFill(Gif gif, int frame, List<Curve> loops, double scale, Point offset, int fallback,
    {List<int> palette = const [], required bool gradients}) {
  final w = gif.width, h = gif.height;
  // The outlines arrive in canvas dp; the pixels to read are in the GIF.
  Point toPixels(Point p) => Point((p.x - offset.x) / scale, (p.y - offset.y) / scale);
  final mask = rasterise([
    for (final curve in loops) [for (final p in flatten(curve)) toPixels(p)]
  ], w, h);
  final rgba = gif.frames[frame].rgba;
  // Only pixels with an interior neighbourhood: the edge ones are blends with
  // whatever is behind the artwork.
  final xs = <double>[], ys = <double>[], cs = <List<double>>[];
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      if (mask[y * w + x] == 0) continue;
      if (mask[y * w + x - 1] == 0 || mask[y * w + x + 1] == 0) continue;
      if (mask[(y - 1) * w + x] == 0 || mask[(y + 1) * w + x] == 0) continue;
      final i = (y * w + x) * 4;
      if (rgba[i + 3] < 250) continue;
      xs.add(x + 0.5);
      ys.add(y + 0.5);
      cs.add([rgba[i].toDouble(), rgba[i + 1].toDouble(), rgba[i + 2].toDouble()]);
    }
  }
  if (cs.length < 64) return Paint(color: fallback);

  final mean = [for (var c = 0; c < 3; c++) cs.fold(0.0, (a, s) => a + s[c]) / cs.length];
  final average = 0xFF000000 |
      (mean[0].round().clamp(0, 255) << 16) |
      (mean[1].round().clamp(0, 255) << 8) |
      mean[2].round().clamp(0, 255);

  // A shade of the paint the region belongs to is artwork; a colour that is
  // plainly another paint's is not. The margin is wide on purpose: a genuine
  // shade - the dark wedge of a fold, say - stays with the paint it shades,
  // and only a region that sits squarely on another paint is disowned.
  final own = _distance(average, fallback);
  for (final other in palette) {
    if (other == fallback) continue;
    if (_distance(average, other) < own * 0.5) return null;
  }
  if (!gradients) return Paint(color: fallback);

  final model = <List<double>>[]; // per channel: constant, dx, dy
  for (var c = 0; c < 3; c++) {
    model.add(_plane(xs, ys, [for (final s in cs) s[c]]));
  }
  var axisX = 0.0, axisY = 0.0;
  for (final m in model) {
    axisX += m[1];
    axisY += m[2];
  }
  final axis = math.sqrt(axisX * axisX + axisY * axisY);
  if (axis < 1e-9) return Paint(color: average);
  axisX /= axis;
  axisY /= axis;

  var low = double.infinity, high = -double.infinity;
  var flat = 0.0, sloped = 0.0;
  for (var i = 0; i < cs.length; i++) {
    final t = xs[i] * axisX + ys[i] * axisY;
    low = math.min(low, t);
    high = math.max(high, t);
    for (var c = 0; c < 3; c++) {
      final predicted = model[c][0] + model[c][1] * xs[i] + model[c][2] * ys[i];
      flat += math.pow(cs[i][c] - mean[c], 2);
      sloped += math.pow(cs[i][c] - predicted, 2);
    }
  }
  Point toCanvas(Point p) => Point(p.x * scale + offset.x, p.y * scale + offset.y);
  final start = Point(axisX * low, axisY * low), end = Point(axisX * high, axisY * high);
  int colorAt(Point p) {
    var argb = 0xFF000000;
    for (var c = 0; c < 3; c++) {
      final v = (model[c][0] + model[c][1] * p.x + model[c][2] * p.y).round().clamp(0, 255);
      argb |= v << (16 - c * 8);
    }
    return argb;
  }

  final first = colorAt(start), last = colorAt(end);
  final spread = _distance(first, last);

  // Two flat colours meeting along a line are not a ramp, and a ramp drawn
  // across them washes the edge out. The colours along the axis say which it
  // is: a fold reads as two crowds with nothing between them, and it is drawn
  // as the step it is - the same two stops, a hair apart.
  final step = _step(xs, ys, cs, axisX, axisY, low, high, sloped);
  if (step != null) {
    final edge = (step.$1 - low) / (high - low);
    return Paint(
      color: average,
      gradient: Gradient('linear', toCanvas(start), toCanvas(end), [
        (0.0, step.$2),
        ((edge - 0.002).clamp(0.0, 1.0), step.$2),
        ((edge + 0.002).clamp(0.0, 1.0), step.$3),
        (1.0, step.$3),
      ]),
    );
  }
  if (spread < 12 || sloped > flat * 0.75) return Paint(color: average);
  return Paint(
    color: average,
    gradient: Gradient('linear', toCanvas(start), toCanvas(end), [(0.0, first), (1.0, last)]),
  );
}

/// Where the region steps from one flat colour to another along its own axis,
/// and the two colours - or null where it does no such thing.
///
/// The pixels are binned along the axis and the split that leaves the least
/// variance either side is taken. It is a step rather than a ramp when both
/// sides are flat compared with the distance between them, which is what
/// tells a fold in a logo from a gradient across it.
(double, int, int)? _step(List<double> xs, List<double> ys, List<List<double>> cs, double axisX,
    double axisY, double low, double high, double sloped) {
  const bins = 48;
  if (high - low < 1e-9) return null;
  final sums = List.generate(bins, (_) => <double>[0, 0, 0]);
  final counts = List<int>.filled(bins, 0);
  for (var i = 0; i < cs.length; i++) {
    final t = (xs[i] * axisX + ys[i] * axisY - low) / (high - low);
    final b = (t * bins).floor().clamp(0, bins - 1);
    counts[b]++;
    for (var c = 0; c < 3; c++) {
      sums[b][c] += cs[i][c];
    }
  }
  // Prefix sums make every candidate split a constant-time question.
  final n = List<int>.filled(bins + 1, 0);
  final m = List.generate(bins + 1, (_) => <double>[0, 0, 0]);
  for (var b = 0; b < bins; b++) {
    n[b + 1] = n[b] + counts[b];
    for (var c = 0; c < 3; c++) {
      m[b + 1][c] = m[b][c] + sums[b][c];
    }
  }
  if (n[bins] < 256) return null;
  var bestSplit = -1;
  var bestCost = double.infinity;
  List<double>? bestLeft, bestRight;
  for (var b = 1; b < bins; b++) {
    final left = n[b], right = n[bins] - n[b];
    if (left < n[bins] ~/ 12 || right < n[bins] ~/ 12) continue;
    final a = [for (var c = 0; c < 3; c++) m[b][c] / left];
    final z = [for (var c = 0; c < 3; c++) (m[bins][c] - m[b][c]) / right];
    var cost = 0.0;
    for (var c = 0; c < 3; c++) {
      cost -= left * a[c] * a[c] + right * z[c] * z[c];
    }
    if (cost < bestCost) {
      bestCost = cost;
      bestSplit = b;
      bestLeft = a;
      bestRight = z;
    }
  }
  if (bestSplit < 0 || bestLeft == null || bestRight == null) return null;
  final a = _argb(bestLeft), z = _argb(bestRight);
  if (_distance(a, z) < 24) return null;
  // Two flat colours or one ramp: whichever leaves less unexplained is the
  // one the region is made of. The two answers are nowhere near each other -
  // a fold leaves a line through it explaining a third less than the step
  // does, and a real ramp leaves the step explaining a thousandth of what the
  // line does - so the margin only has to exist.
  var stepped = 0.0;
  for (var i = 0; i < cs.length; i++) {
    final t = (xs[i] * axisX + ys[i] * axisY - low) / (high - low);
    final mean = (t * bins).floor().clamp(0, bins - 1) < bestSplit ? bestLeft : bestRight;
    for (var c = 0; c < 3; c++) {
      stepped += (cs[i][c] - mean[c]) * (cs[i][c] - mean[c]);
    }
  }
  if (stepped > sloped * 0.9) return null;
  return (low + (high - low) * bestSplit / bins, a, z);
}

int _argb(List<double> rgb) =>
    0xFF000000 |
    (rgb[0].round().clamp(0, 255) << 16) |
    (rgb[1].round().clamp(0, 255) << 8) |
    rgb[2].round().clamp(0, 255);

double _distance(int a, int b) {
  final dr = ((a >> 16) & 0xFF) - ((b >> 16) & 0xFF);
  final dg = ((a >> 8) & 0xFF) - ((b >> 8) & 0xFF);
  final db = (a & 0xFF) - (b & 0xFF);
  return math.sqrt((dr * dr + dg * dg + db * db).toDouble());
}

/// Least-squares plane `value = a + b x + c y`.
List<double> _plane(List<double> xs, List<double> ys, List<double> values) {
  final n = xs.length.toDouble();
  var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, sv = 0.0, sxv = 0.0, syv = 0.0;
  for (var i = 0; i < xs.length; i++) {
    sx += xs[i];
    sy += ys[i];
    sxx += xs[i] * xs[i];
    syy += ys[i] * ys[i];
    sxy += xs[i] * ys[i];
    sv += values[i];
    sxv += xs[i] * values[i];
    syv += ys[i] * values[i];
  }
  // 3x3 normal equations by Cramer's rule.
  final m = [
    [n, sx, sy],
    [sx, sxx, sxy],
    [sy, sxy, syy],
  ];
  final rhs = [sv, sxv, syv];
  final det = _det(m);
  if (det.abs() < 1e-9) return [sv / n, 0, 0];
  final out = <double>[];
  for (var col = 0; col < 3; col++) {
    final copy = [
      for (var r = 0; r < 3; r++) [for (var c = 0; c < 3; c++) c == col ? rhs[r] : m[r][c]],
    ];
    out.add(_det(copy) / det);
  }
  return out;
}

double _det(List<List<double>> m) =>
    m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
    m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
    m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
