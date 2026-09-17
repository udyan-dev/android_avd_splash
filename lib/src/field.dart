import 'dart:math' as math;
import 'dart:typed_data';

import 'gif.dart';

/// One paint colour of the artwork, with its per-frame coverage fields.
class Layer {
  Layer(this.color, this.fields);

  /// 0xAARRGGBB.
  final int color;

  /// Per frame, coverage in `[0, 1]` for every pixel, row major.
  final List<Float32List> fields;

  String get hex => '#${(color & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase()}';
}

/// Splits a GIF into a background colour and one coverage layer per paint
/// colour. Anti-aliased pixels are resolved to fractional coverage by
/// projecting them onto the background-to-paint axis, so contours recover the
/// sub-pixel geometry the GIF was rasterised from.
class Separation {
  Separation(this.background, this.layers);

  final int background;
  final List<Layer> layers;

  static Separation of(Gif gif, {int? background, List<int>? colors, double? smooth}) {
    final counts = <int, int>{};
    for (final frame in gif.frames) {
      final rgba = frame.rgba;
      for (var i = 0; i < rgba.length; i += 4) {
        final key =
            rgba[i + 3] == 0 ? 0 : 0xFF000000 | (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2];
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    final background0 = background ?? _background(gif, counts);
    final paints = colors ?? _paints(counts, background0);

    final layers = [for (final paint in paints) Layer(paint, [])];
    for (final frame in gif.frames) {
      final fields = _coverage(frame.rgba, background0, paints);
      for (var i = 0; i < layers.length; i++) {
        layers[i].fields.add(fields[i]);
      }
    }
    // A GIF with no anti-aliased pixels only knows whole pixels, so its
    // contours come out as staircases. One pixel of blur restores a smooth
    // level set at the same position - a symmetric kernel leaves a straight
    // edge exactly where it was - and stops the curve fitter chasing the
    // staircase instead of the shape.
    final sigma = smooth ?? (_hardEdged(layers) ? 1.0 : 0.0);
    if (sigma > 0) {
      for (final layer in layers) {
        for (final field in layer.fields) {
          _blur(field, gif.width, gif.height, sigma);
        }
      }
    }
    return Separation(background0, layers);
  }
}

int _background(Gif gif, Map<int, int> counts) {
  // The border of the first frame is background by construction; fall back to
  // the most common colour of the whole animation.
  final border = <int, int>{};
  final rgba = gif.frames.first.rgba;
  void sample(int x, int y) {
    final i = (y * gif.width + x) * 4;
    final key =
        rgba[i + 3] == 0 ? 0 : 0xFF000000 | (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2];
    border[key] = (border[key] ?? 0) + 1;
  }

  for (var x = 0; x < gif.width; x++) {
    sample(x, 0);
    sample(x, gif.height - 1);
  }
  for (var y = 0; y < gif.height; y++) {
    sample(0, y);
    sample(gif.width - 1, y);
  }
  final pool = border.isEmpty ? counts : border;
  return pool.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
}

/// Picks the paint colours: cluster every non-background colour by its
/// direction away from the background, take each cluster's far end, then merge
/// clusters that are close in colour. Merging is what keeps a gradient - a
/// chain of near neighbours - one piece of artwork instead of a stack of bands.
List<int> _paints(Map<int, int> counts, int background) {
  final bg = _rgb(background);
  final clusters = <List<double>>[]; // ux, uy, uz, weight, bestDistance, bestColour
  final sorted = counts.entries.where((e) => e.key != background).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final entry in sorted) {
    final c = _rgb(entry.key);
    final dx = c[0] - bg[0], dy = c[1] - bg[1], dz = c[2] - bg[2];
    final d = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (d < 8) continue; // indistinguishable from the background
    final ux = dx / d, uy = dy / d, uz = dz / d;
    var hit = false;
    for (final k in clusters) {
      if (ux * k[0] + uy * k[1] + uz * k[2] > 0.995) {
        k[3] += entry.value;
        if (d > k[4]) {
          k[4] = d;
          k[5] = entry.key.toDouble();
        }
        hit = true;
        break;
      }
    }
    if (!hit) clusters.add([ux, uy, uz, entry.value.toDouble(), d, entry.key.toDouble()]);
  }
  final total = clusters.fold(0.0, (a, k) => a + k[3]);
  clusters.removeWhere((k) => k[3] < total * 0.02); // anti-aliasing debris
  clusters.sort((a, b) => b[3].compareTo(a[3]));
  if (clusters.isEmpty) throw StateError('no artwork colour found in the GIF');

  final paints = <int>[];
  final weights = <double>[];
  for (final k in clusters) {
    final colour = k[5].toInt();
    var merged = false;
    for (var i = 0; i < paints.length; i++) {
      if (_distance(paints[i], colour) < 96) {
        final w = weights[i] + k[3];
        paints[i] = _mix(paints[i], weights[i] / w, colour);
        weights[i] = w;
        merged = true;
        break;
      }
    }
    if (!merged) {
      paints.add(colour);
      weights.add(k[3]);
    }
  }
  return paints;
}

double _distance(int a, int b) {
  final x = _rgb(a), y = _rgb(b);
  return math.sqrt(math.pow(x[0] - y[0], 2) + math.pow(x[1] - y[1], 2) + math.pow(x[2] - y[2], 2));
}

int _mix(int a, double weightOfA, int b) {
  final x = _rgb(a), y = _rgb(b);
  var argb = 0xFF000000;
  for (var c = 0; c < 3; c++) {
    final v = (x[c] * weightOfA + y[c] * (1 - weightOfA)).round().clamp(0, 255);
    argb |= v << (16 - c * 8);
  }
  return argb;
}

/// Coverage of every paint colour for one frame. Each pixel is assigned to the
/// single paint whose direction away from the background it points along, so
/// two paints - the ends of a gradient, say - never both claim it and the
/// artwork is never traced twice.
List<Float32List> _coverage(Uint8List rgba, int background, List<int> paints) {
  final bg = _rgb(background);
  final axes = [
    for (final paint in paints)
      [
        for (var c = 0; c < 3; c++) _rgb(paint)[c] - bg[c],
      ],
  ];
  final lengths = [for (final a in axes) math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])];
  final out = [for (final _ in paints) Float32List(rgba.length ~/ 4)];
  for (var i = 0, p = 0; i < rgba.length; i += 4, p++) {
    // A transparent pixel shows the background.
    final alpha = rgba[i + 3] / 255.0;
    final dx = (rgba[i] - bg[0]) * alpha;
    final dy = (rgba[i + 1] - bg[1]) * alpha;
    final dz = (rgba[i + 2] - bg[2]) * alpha;
    final length = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (length < 4) continue;
    var best = 0;
    var bestCosine = -2.0;
    for (var k = 0; k < axes.length; k++) {
      final cosine = (dx * axes[k][0] + dy * axes[k][1] + dz * axes[k][2]) / (length * lengths[k]);
      if (cosine > bestCosine) {
        bestCosine = cosine;
        best = k;
      }
    }
    final t = length / lengths[best];
    out[best][p] = t < 0 ? 0 : (t > 1 ? 1 : t);
  }
  return out;
}

List<double> _rgb(int argb) =>
    [((argb >> 16) & 0xFF).toDouble(), ((argb >> 8) & 0xFF).toDouble(), (argb & 0xFF).toDouble()];

bool _hardEdged(List<Layer> layers) {
  var partial = 0, solid = 0;
  for (final layer in layers) {
    for (final field in layer.fields) {
      for (final v in field) {
        if (v > 0.02 && v < 0.98) {
          partial++;
        } else if (v >= 0.98) {
          solid++;
        }
      }
    }
  }
  return solid > 0 && partial < solid * 0.02;
}

/// In-place separable Gaussian blur.
void _blur(Float32List field, int w, int h, double sigma) {
  final radius = math.max(1, (sigma * 3).ceil());
  final kernel = Float32List(radius * 2 + 1);
  var sum = 0.0;
  for (var i = -radius; i <= radius; i++) {
    final v = math.exp(-i * i / (2 * sigma * sigma));
    kernel[i + radius] = v;
    sum += v;
  }
  for (var i = 0; i < kernel.length; i++) {
    kernel[i] /= sum;
  }
  final tmp = Float32List(field.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var acc = 0.0;
      for (var i = -radius; i <= radius; i++) {
        final sx = (x + i).clamp(0, w - 1);
        acc += field[y * w + sx] * kernel[i + radius];
      }
      tmp[y * w + x] = acc;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var acc = 0.0;
      for (var i = -radius; i <= radius; i++) {
        final sy = (y + i).clamp(0, h - 1);
        acc += tmp[sy * w + x] * kernel[i + radius];
      }
      field[y * w + x] = acc;
    }
  }
}
