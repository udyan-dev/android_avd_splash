import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'contour.dart';
import 'fit.dart';
import 'model.dart';
import 'raster.dart';
import 'trim.dart';

/// Frame-by-frame agreement between the generated resources and the GIF.
class Report {
  Report(this.frames, this.exact, this.tolerant, this.deviation, this.histogram, this.ceiling,
      this.maxRadiusDp, this.safeRadiusDp, this.morphable);

  final int frames;

  /// Distance, in dp, from the generated outline to the nearest point of the
  /// GIF's own contour, per frame: the mean and the worst. This is the error a
  /// person could see, and unlike pixel overlap it has no floor - a vector edge
  /// can sit exactly on a sub-pixel contour, but it can never fill a whole
  /// pixel the way a GIF does.
  final List<List<double>> deviation;

  /// Deviation of every sampled outline point, in hundredths of a dp.
  final List<int> histogram;

  /// Strict pixel agreement of the GIF's own traced contours, rasterised
  /// straight back: the most any vector can score against whole pixels, and so
  /// the ceiling this run is measured against.
  final double ceiling;

  double get meanDeviationDp =>
      deviation.fold(0.0, (a, d) => a + d[0]) / (frames == 0 ? 1 : frames);

  double get worstDeviationDp => deviation.fold(0.0, (a, d) => math.max(a, d[1]));

  /// Deviation that 95 per cent of the outline stays inside, in dp.
  double get typicalDeviationDp {
    final total = histogram.fold(0, (a, n) => a + n);
    if (total == 0) return 0;
    var seen = 0;
    for (var i = 0; i < histogram.length; i++) {
      seen += histogram[i];
      if (seen >= total * 0.95) return i / 100;
    }
    return histogram.length / 100;
  }

  /// How much of the reachable accuracy this run actually reached.
  double get ofCeiling => ceiling <= 0 ? 1 : math.min(1, meanExact / ceiling);

  /// Furthest the artwork ever gets from the centre of the canvas, and the
  /// radius the platform allows before it clips the animated icon.
  final double maxRadiusDp;
  final double safeRadiusDp;

  bool get insideSafeArea => maxRadiusDp <= safeRadiusDp;

  /// Whether every path-data step keeps the command sequence its neighbour
  /// has. Android refuses to morph two paths that do not match command for
  /// command, and silently snaps instead.
  final bool morphable;

  /// Intersection over union per frame, and forgiving a one-pixel edge shift.
  final List<double> exact;
  final List<double> tolerant;

  double get meanExact => exact.reduce((a, b) => a + b) / frames;
  double get meanTolerant => tolerant.reduce((a, b) => a + b) / frames;
  double get worstTolerant => tolerant.reduce((a, b) => a < b ? a : b);
  int get worstFrame => tolerant.indexOf(worstTolerant);
}

/// Replays the emitted XML - the drawable, its animators and their keyframes -
/// and scores every frame against the GIF it came from. This reads the written
/// resources back, so it checks the files Android will load, not the model they
/// were written from.
class Playback {
  Playback(this.files, this.scale, this.offset);

  final Map<String, String> files;

  /// GIF pixels to canvas dp: the path data is in canvas units, the GIF frames
  /// it is checked against are not.
  final double scale;
  final Point offset;

  late final String name = files.keys
      .firstWhere((f) => f.startsWith('drawable/') && !f.endsWith('_vector.xml'))
      .replaceFirst('drawable/', '')
      .replaceFirst('.xml', '');
  late final XmlElement vector =
      XmlDocument.parse(files['drawable/${name}_vector.xml']!).rootElement;
  late final List<double> toPixels = [
    1 / scale,
    0,
    -offset.x / scale,
    0,
    1 / scale,
    -offset.y / scale
  ];
  late final double canvas = double.parse(_attr(vector, 'viewportWidth')!);
  late final Point centre = Point(canvas / 2, double.parse(_attr(vector, 'viewportHeight')!) / 2);

  /// Animators by the name they target. A target can appear twice - a shape
  /// animator and a paint animator on the same path - so the second one is
  /// filed under a suffix.
  late final Map<String, XmlElement> animators = () {
    final out = <String, XmlElement>{};
    for (final target
        in XmlDocument.parse(files['drawable/$name.xml']!).rootElement.findElements('target')) {
      final animation = _attr(target, 'animation')!.replaceFirst('@animator/', '');
      final element = XmlDocument.parse(files['animator/$animation.xml']!).rootElement;
      final key = _attr(target, 'name')!;
      out[out.containsKey(key) ? '$key#paint' : key] = element;
    }
    return out;
  }();

  /// The easing a `@interpolator/...` reference stands for.
  late final Map<String, Easing> easings = {
    for (final entry in files.entries)
      if (entry.key.startsWith('interpolator/'))
        '@interpolator/${entry.key.substring(13, entry.key.length - 4)}': () {
          final node = XmlDocument.parse(entry.value).rootElement;
          return Easing(
            double.parse(_attr(node, 'controlX1')!),
            double.parse(_attr(node, 'controlY1')!),
            double.parse(_attr(node, 'controlX2')!),
            double.parse(_attr(node, 'controlY2')!),
          );
        }(),
  };

  Easing easing(String? reference) =>
      reference == null ? Easing.linear : (easings[reference] ?? Easing.linear);

  /// Every `<path>` in GIF pixel space at [timeMs] of a [durationMs]
  /// animation: loops fill by the even-odd rule within a path, but separate
  /// paths paint over each other.
  List<Drawn> at(int timeMs, int durationMs) {
    final out = <Drawn>[];
    final fraction = durationMs == 0 ? 0.0 : timeMs / durationMs;
    for (final group in vector.findElements('group')) {
      _walk(group, toPixels, fraction, timeMs, animators, out, this, const []);
    }
    return out;
  }
}

Report verify(
  Map<String, String> files,
  List<Uint8List> masks,
  List<List<Point>> contours,
  double ceiling,
  List<int> times,
  int durationMs,
  int width,
  int height,
  double scale,
  Point offset,
) {
  final playback = Playback(files, scale, offset);

  final exact = <double>[], tolerant = <double>[], deviation = <List<double>>[];
  final histogram = List<int>.filled(2000, 0);
  var radius = 0.0;
  for (var f = 0; f < times.length; f++) {
    final paths = playback.at(times[f], durationMs);
    final mask = Uint8List(width * height);
    for (final path in paths) {
      final painted = rasterise(path.painted, width, height);
      for (final clip in path.clips) {
        // A clip has no fillType on Android; it fills by winding, and the
        // verifier has to answer as the platform does or a clip that the
        // platform cannot express would still score.
        final allowed = rasterise(clip, width, height, nonZero: true);
        for (var i = 0; i < painted.length; i++) {
          if (allowed[i] == 0) painted[i] = 0;
        }
      }
      for (var i = 0; i < mask.length; i++) {
        if (painted[i] != 0) mask[i] = 1;
      }
    }
    // How far the artwork reaches is measured from what is actually painted,
    // after every clip: geometry a clip removes is never on screen, so it can
    // never be what the platform crops.
    for (var i = 0; i < mask.length; i++) {
      if (mask[i] == 0) continue;
      final x = (i % width + 0.5) * scale + offset.x;
      final y = (i ~/ width + 0.5) * scale + offset.y;
      final d = (Point(x, y) - playback.centre).length;
      if (d > radius) radius = d;
    }
    exact.add(iou(mask, masks[f]));
    tolerant.add(tolerantIou(mask, masks[f], width, height));
    deviation.add(_deviation(paths, contours[f], scale, histogram));
  }
  return Report(times.length, exact, tolerant, deviation, histogram, ceiling, radius,
      playback.canvas / 3, _morphable(playback.animators.values));
}

void _walk(
    XmlElement node,
    List<double> parent,
    double fraction,
    int timeMs,
    Map<String, XmlElement> animators,
    List<Drawn> out,
    Playback playback,
    List<List<List<Point>>> clips) {
  final name = _attr(node, 'name');
  // A path can carry two animators: one for its shape, one for its paint.
  final animator = name == null ? null : animators[name];
  final paintAnimator = name == null ? null : animators['$name#paint'];
  final local = node.name.local == 'group'
      ? _compose(parent, _group(node, animator, fraction, playback))
      : parent;

  if (node.name.local == 'path') {
    // A fill and a stroke are both paint: what is on screen is one, the other,
    // or both, and what has faded to nothing is neither.
    final paint = paintAnimator ?? animator;
    double property(String name, double fallback) =>
        (paint == null ? null : _track(paint, name, fraction, playback)) ??
        double.parse(_attr(node, name) ?? '$fallback');
    final filled = _attr(node, 'fillColor') != null ||
        node.childElements.any((child) =>
            child.name.local == 'attr' && child.getAttribute('name') == 'android:fillColor');
    final fills = filled && property('fillAlpha', 1) >= 0.5;
    final width = _attr(node, 'strokeColor') == null ? 0.0 : property('strokeWidth', 0);
    final strokes = width > 0 && property('strokeAlpha', 1) >= 0.5;
    if (!fills && !strokes) return;
    var data = _attr(node, 'pathData')!;
    if (animator != null) data = _morph(animator, timeMs, playback) ?? data;
    final curves = _parse(data);
    final start = property('trimPathStart', 0), end = property('trimPathEnd', 1);
    // Read the way the platform reads it, not the way the source meant it:
    // this is what the device draws, and the gap between the two is the whole
    // point of checking.
    final closed = start == 0 && end == 1;
    final trimmed = strokes && !closed
        ? trimAndroid(curves, start, end, property('trimPathOffset', 0))
        : curves;
    // A `<group>` scale scales the stroke with the geometry, exactly as the
    // renderer does.
    final scale = math.sqrt((local[0] * local[4] - local[1] * local[3]).abs());
    out.add(Drawn(
      [
        for (final curve in curves) [for (final p in flatten(curve)) _apply(local, p)],
      ],
      clips,
      fills: fills,
      stroke: strokes ? width * scale : 0,
      stroked: [
        for (final curve in trimmed) [for (final p in flatten(curve)) _apply(local, p)],
      ],
      strokeClosed: closed,
    ));
    return;
  }
  // A clip-path narrows everything inside its group.
  var narrowed = clips;
  for (final child in node.childElements.where((c) => c.name.local == 'clip-path')) {
    final clipName = _attr(child, 'name');
    final clipAnimator = clipName == null ? null : animators[clipName];
    final data = (clipAnimator == null ? null : _morph(clipAnimator, timeMs, playback)) ??
        _attr(child, 'pathData')!;
    narrowed = [
      ...narrowed,
      [
        for (final curve in _parse(data)) [for (final p in flatten(curve)) _apply(local, p)],
      ],
    ];
  }
  for (final child in node.childElements) {
    _walk(child, local, fraction, timeMs, animators, out, playback, narrowed);
  }
}

/// Group transform: translate, then rotate and scale about the pivot.
List<double> _group(XmlElement node, XmlElement? animator, double fraction, Playback playback) {
  double value(String property, double fallback) {
    final animated = animator == null ? null : _track(animator, property, fraction, playback);
    return animated ?? double.parse(_attr(node, property) ?? '$fallback');
  }

  final px = double.parse(_attr(node, 'pivotX') ?? '0');
  final py = double.parse(_attr(node, 'pivotY') ?? '0');
  final tx = value('translateX', 0), ty = value('translateY', 0);
  final sx = value('scaleX', 1), sy = value('scaleY', 1);
  final radians = value('rotation', 0) * math.pi / 180;
  final cos = math.cos(radians), sin = math.sin(radians);
  // T(t) T(p) R S T(-p)
  final a = cos * sx, b = -sin * sy, d = sin * sx, e = cos * sy;
  return [a, b, tx + px - (a * px + b * py), d, e, ty + py - (d * px + e * py)];
}

double? _track(XmlElement animator, String property, double fraction, Playback playback) {
  for (final holder in animator.findAllElements('propertyValuesHolder')) {
    if (_attr(holder, 'propertyName') != property) continue;
    final frames = holder.findElements('keyframe').toList();
    if (frames.isEmpty) return null;
    double at(int i) => double.parse(_attr(frames[i], 'fraction')!);
    double value(int i) => double.parse(_attr(frames[i], 'value')!);
    if (fraction <= at(0)) return value(0);
    for (var i = 1; i < frames.length; i++) {
      if (fraction <= at(i)) {
        final span = at(i) - at(i - 1);
        // A keyframe's interpolator governs the interval that ends at it.
        final t = playback.easing(_attr(frames[i], 'interpolator'))(
            span <= 0 ? 1.0 : (fraction - at(i - 1)) / span);
        return value(i - 1) + (value(i) - value(i - 1)) * t;
      }
    }
    return value(frames.length - 1);
  }
  return null;
}

/// Path data of a sequential set of one-step `pathData` animators at [timeMs].
String? _morph(XmlElement animator, int timeMs, Playback playback) {
  var clock = 0;
  final steps = animator.findElements('objectAnimator').toList();
  if (steps.isEmpty) return null;
  for (final step in steps) {
    final length = int.parse(_attr(step, 'duration')!);
    if (timeMs < clock + length || step == steps.last) {
      final progress = length <= 0 ? 1.0 : ((timeMs - clock) / length).clamp(0.0, 1.0);
      final t = playback.easing(_attr(step, 'interpolator'))(progress);
      return _lerpData(_attr(step, 'valueFrom')!, _attr(step, 'valueTo')!, t);
    }
    clock += length;
  }
  return null;
}

String _lerpData(String from, String to, double t) {
  final a = _numbers(from), b = _numbers(to);
  var i = 0;
  return from.replaceAllMapped(_number, (m) {
    final v = a[i] + (b[i] - a[i]) * t;
    i++;
    return v.toStringAsFixed(4);
  });
}

final _number = RegExp(r'-?\d+(\.\d+)?');
List<double> _numbers(String data) =>
    [for (final m in _number.allMatches(data)) double.parse(m[0]!)];

/// Parses the path data this package writes, absolute or relative.
List<Curve> _parse(String data) {
  final curves = <Curve>[];
  final numbers = _numbers(data);
  Curve? current;
  var at = 0;
  var cx = 0.0, cy = 0.0, startX = 0.0, startY = 0.0;

  for (final code in data.split('').where((c) => 'MLCZmlcz'.contains(c))) {
    final relative = code.toLowerCase() == code;
    // In a relative command every point is measured from the current point.
    final bx = relative ? cx : 0.0, by = relative ? cy : 0.0;
    Point next() {
      final p = Point(bx + numbers[at], by + numbers[at + 1]);
      at += 2;
      return p;
    }

    switch (code.toUpperCase()) {
      case 'M':
        final p = next();
        cx = startX = p.x;
        cy = startY = p.y;
        current = [p];
        curves.add(current);
      case 'L':
        final from = current!.last, p = next();
        current.addAll([from + (p - from) * (1 / 3), from + (p - from) * (2 / 3), p]);
        cx = p.x;
        cy = p.y;
      case 'C':
        final c1 = next(), c2 = next(), p = next();
        current!.addAll([c1, c2, p]);
        cx = p.x;
        cy = p.y;
      case 'Z':
        cx = startX;
        cy = startY;
    }
  }
  return curves;
}

List<double> _compose(List<double> m, List<double> n) => [
      m[0] * n[0] + m[1] * n[3],
      m[0] * n[1] + m[1] * n[4],
      m[0] * n[2] + m[1] * n[5] + m[2],
      m[3] * n[0] + m[4] * n[3],
      m[3] * n[1] + m[4] * n[4],
      m[3] * n[2] + m[4] * n[5] + m[5],
    ];

Point _apply(List<double> m, Point p) =>
    Point(m[0] * p.x + m[1] * p.y + m[2], m[3] * p.x + m[4] * p.y + m[5]);

String? _attr(XmlElement node, String name) => node.getAttribute('android:$name');

bool _morphable(Iterable<XmlElement> animators) {
  for (final animator in animators) {
    for (final step in animator.findAllElements('objectAnimator')) {
      final from = _attr(step, 'valueFrom'), to = _attr(step, 'valueTo');
      if (from == null || to == null) continue;
      if (_commands(from) != _commands(to)) return false;
    }
  }
  return true;
}

String _commands(String data) => data.split('').where((c) => 'MLCQSTAZmlcqstaz'.contains(c)).join();

/// Mean and worst distance, in dp, from the generated outline to the contour
/// the GIF actually has. Nearest neighbours come from a uniform grid, so the
/// cost stays linear in the number of points.
List<double> _deviation(List<Drawn> paths, List<Point> contour, double scale, List<int> histogram) {
  if (contour.isEmpty) return [0, 0];
  const cell = 4.0;
  final grid = <int, List<Point>>{};
  int key(double x, double y) => (x / cell).floor() * 100003 + (y / cell).floor();
  for (final p in contour) {
    grid.putIfAbsent(key(p.x, p.y), () => <Point>[]).add(p);
  }

  var sum = 0.0, worst = 0.0, count = 0;
  for (final path in paths) {
    for (final loop in path.loops) {
      // A path the group has scaled to nothing is invisible: it has no edge to
      // compare, and its collapsed points sit nowhere near the artwork.
      if (_area(loop) < 1) continue;
      for (final p in loop) {
        var best = double.infinity;
        for (var ring = 0; ring < 8 && best.isInfinite; ring++) {
          for (var dx = -ring; dx <= ring; dx++) {
            for (var dy = -ring; dy <= ring; dy++) {
              if (ring > 0 && dx.abs() != ring && dy.abs() != ring) continue;
              for (final q in grid[key(p.x + dx * cell, p.y + dy * cell)] ?? const <Point>[]) {
                final d = (q - p).length;
                if (d < best) best = d;
              }
            }
          }
        }
        if (best.isInfinite) continue;
        sum += best;
        count++;
        if (best > worst) worst = best;
        final bin = (best * scale * 100).round();
        histogram[bin < histogram.length ? bin : histogram.length - 1]++;
      }
    }
  }
  return count == 0 ? [0, 0] : [sum / count * scale, worst * scale];
}

double _area(List<Point> loop) {
  var sum = 0.0;
  for (var i = 0; i < loop.length; i++) {
    final p = loop[i], q = loop[(i + 1) % loop.length];
    sum += p.x * q.y - q.x * p.y;
  }
  return sum.abs() / 2;
}
