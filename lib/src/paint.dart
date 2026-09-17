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
Paint fitFill(Gif gif, int frame, List<Curve> loops, double scale, Point offset, int fallback) {
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
  final spread = math.sqrt(math.pow(((first >> 16) & 0xFF) - ((last >> 16) & 0xFF), 2) +
      math.pow(((first >> 8) & 0xFF) - ((last >> 8) & 0xFF), 2) +
      math.pow((first & 0xFF) - (last & 0xFF), 2));
  if (spread < 12 || sloped > flat * 0.75) return Paint(color: average);
  return Paint(
    color: average,
    gradient: Gradient('linear', toCanvas(start), toCanvas(end), [(0.0, first), (1.0, last)]),
  );
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
