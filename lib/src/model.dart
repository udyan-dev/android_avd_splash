import 'dart:math' as math;

import 'contour.dart';
import 'fit.dart';

/// Cubic-bezier timing, in the same parameterisation Lottie keyframes and
/// Android's `<pathInterpolator>` both use.
class Easing {
  const Easing(this.x1, this.y1, this.x2, this.y2);

  final double x1;
  final double y1;
  final double x2;
  final double y2;

  static const linear = Easing(0, 0, 1, 1);

  bool get isLinear => x1 == 0 && y1 == 0 && x2 == 1 && y2 == 1;

  /// Eased progress at [t], by Newton iteration on the x curve.
  double call(double t) {
    if (isLinear || t <= 0) return t <= 0 ? 0 : (t >= 1 ? 1 : t);
    if (t >= 1) return 1;
    var u = t;
    for (var i = 0; i < 8; i++) {
      final v = 1 - u;
      final x = 3 * v * v * u * x1 + 3 * v * u * u * x2 + u * u * u;
      final dx = 3 * v * v * x1 + 6 * v * u * (x2 - x1) + 3 * u * u * (1 - x2);
      if (dx.abs() < 1e-9) break;
      final next = u - (x - t) / dx;
      if ((next - u).abs() < 1e-9) {
        u = next;
        break;
      }
      u = next.clamp(0.0, 1.0);
    }
    final v = 1 - u;
    return 3 * v * v * u * y1 + 3 * v * u * u * y2 + u * u * u;
  }
}

/// A 2x3 affine transform: `[a b tx d e ty]`.
typedef Matrix = List<double>;

const identity = <double>[1, 0, 0, 0, 1, 0];

Matrix compose(Matrix m, Matrix n) => [
      m[0] * n[0] + m[1] * n[3],
      m[0] * n[1] + m[1] * n[4],
      m[0] * n[2] + m[1] * n[5] + m[2],
      m[3] * n[0] + m[4] * n[3],
      m[3] * n[1] + m[4] * n[4],
      m[3] * n[2] + m[4] * n[5] + m[5],
    ];

Point transform(Matrix m, Point p) =>
    Point(m[0] * p.x + m[1] * p.y + m[2], m[3] * p.x + m[4] * p.y + m[5]);

Matrix invert(Matrix m) {
  final det = m[0] * m[4] - m[1] * m[3];
  final a = m[4] / det, b = -m[1] / det, d = -m[3] / det, e = m[0] / det;
  return [a, b, -(a * m[2] + b * m[5]), d, e, -(d * m[2] + e * m[5])];
}

class Key<T> {
  const Key(this.timeMs, this.value, [this.easing = Easing.linear]);

  final int timeMs;
  final T value;

  /// How the value travels from this key to the next.
  final Easing easing;
}

/// A property over time. One key means it never changes.
class Track<T> {
  Track(this.keys) : assert(keys.isNotEmpty);

  Track.constant(T value) : keys = [Key(0, value)];

  final List<Key<T>> keys;

  bool get isConstant => keys.length == 1;
  T get first => keys.first.value;

  /// The same track played over [scale] times its length. Easing is a shape in
  /// normalised time, so it is untouched.
  Track<T> retimed(double scale) =>
      Track([for (final key in keys) Key((key.timeMs * scale).round(), key.value, key.easing)]);

  /// The two keys around [timeMs] and the eased progress between them, or null
  /// where the track is already settled.
  (Key<T>, Key<T>, double)? span(int timeMs) {
    if (isConstant || timeMs <= keys.first.timeMs) return null;
    for (var i = 1; i < keys.length; i++) {
      if (timeMs <= keys[i].timeMs) {
        final a = keys[i - 1], b = keys[i];
        final length = b.timeMs - a.timeMs;
        return (a, b, a.easing(length <= 0 ? 1 : (timeMs - a.timeMs) / length));
      }
    }
    return null;
  }
}

extension NumberTrack on Track<double> {
  double at(int timeMs) {
    final between = span(timeMs);
    if (between == null) return timeMs <= keys.first.timeMs ? keys.first.value : keys.last.value;
    final (a, b, t) = between;
    return a.value + (b.value - a.value) * t;
  }
}

extension OutlineTrack on Track<List<Curve>> {
  List<Curve> at(int timeMs) {
    final between = span(timeMs);
    if (between == null) return timeMs <= keys.first.timeMs ? keys.first.value : keys.last.value;
    final (a, b, t) = between;
    return [
      for (var c = 0; c < a.value.length; c++)
        [
          for (var k = 0; k < a.value[c].length; k++)
            a.value[c][k] + (b.value[c][k] - a.value[c][k]) * t
        ],
    ];
  }
}

/// A fill: one colour, or a gradient of stops along a line or out from a
/// centre. Gradients are static, because `AnimatedVectorDrawable` cannot
/// animate one.
class Gradient {
  const Gradient(this.type, this.start, this.end, this.stops, [this.radius = 0]);

  /// 'linear' or 'radial'.
  final String type;
  final Point start;
  final Point end;

  /// Offset in `[0, 1]` and colour, in order.
  final List<(double, int)> stops;
  final double radius;
}

class Paint {
  Paint({
    this.color,
    this.gradient,
    Track<double>? alpha,
    this.strokeColor,
    Track<double>? strokeAlpha,
    Track<double>? strokeWidth,
    this.cap,
    this.join,
    Track<double>? trimStart,
    Track<double>? trimEnd,
    Track<double>? trimOffset,
  })  : alpha = alpha ?? Track.constant(1),
        strokeAlpha = strokeAlpha ?? Track.constant(1),
        strokeWidth = strokeWidth ?? Track.constant(0),
        trimStart = trimStart ?? Track.constant(0),
        trimEnd = trimEnd ?? Track.constant(1),
        trimOffset = trimOffset ?? Track.constant(0);

  final int? color;
  final Gradient? gradient;
  final Track<double> alpha;
  final int? strokeColor;
  final Track<double> strokeAlpha;
  final Track<double> strokeWidth;
  final String? cap;
  final String? join;
  final Track<double> trimStart;
  final Track<double> trimEnd;
  final Track<double> trimOffset;

  bool get hasFill => color != null || gradient != null;

  /// The same paint with the trim left out: used when the trim has been cut
  /// into the geometry instead.
  Paint withoutTrim() => Paint(
        color: color,
        gradient: gradient,
        alpha: alpha,
        strokeColor: strokeColor,
        strokeAlpha: strokeAlpha,
        strokeWidth: strokeWidth,
        cap: cap,
        join: join,
      );
  bool get hasStroke => strokeColor != null && !(strokeWidth.isConstant && strokeWidth.first == 0);

  Paint retimed(double scale) => Paint(
        color: color,
        gradient: gradient,
        alpha: alpha.retimed(scale),
        strokeColor: strokeColor,
        strokeAlpha: strokeAlpha.retimed(scale),
        strokeWidth: strokeWidth.retimed(scale),
        cap: cap,
        join: join,
        trimStart: trimStart.retimed(scale),
        trimEnd: trimEnd.retimed(scale),
        trimOffset: trimOffset.retimed(scale),
      );

  /// This fill and [stroke]'s stroke on one paint. A `<path>` carries both, and
  /// Android strokes after it fills, which is the order they were stacked in.
  Paint over(Paint stroke) => Paint(
        color: color,
        gradient: gradient,
        alpha: alpha,
        strokeColor: stroke.strokeColor,
        strokeAlpha: stroke.strokeAlpha,
        strokeWidth: stroke.strokeWidth,
        cap: stroke.cap,
        join: stroke.join,
        trimStart: stroke.trimStart,
        trimEnd: stroke.trimEnd,
        trimOffset: stroke.trimOffset,
      );
}

/// A `<path>`: outlines over time, and how they are painted.
class PathItem {
  PathItem(this.name, this.data, this.paint);

  final String name;

  /// Outline over time. Every key must have the same command structure, or the
  /// platform cannot morph between them.
  final Track<List<Curve>> data;
  final Paint paint;

  int get segments => data.first.fold(0, (a, c) => a + (c.length - 1) ~/ 3);

  PathItem retimed(double scale) => PathItem(name, data.retimed(scale), paint.retimed(scale));
}

/// A `<group>`: a transform over time, and what it transforms. Nesting is kept
/// as it comes, so an imported animation keeps the structure its author gave
/// it and every transform stays exact.
class Group {
  Group(
    this.name, {
    this.clip,
    this.pivot = const Point(0, 0),
    Track<double>? translateX,
    Track<double>? translateY,
    Track<double>? scaleX,
    Track<double>? scaleY,
    Track<double>? rotation,
    List<Group>? groups,
    List<PathItem>? paths,
  })  : translateX = translateX ?? Track.constant(0),
        translateY = translateY ?? Track.constant(0),
        scaleX = scaleX ?? Track.constant(1),
        scaleY = scaleY ?? Track.constant(1),
        rotation = rotation ?? Track.constant(0),
        groups = groups ?? const [],
        paths = paths ?? const [];

  final String name;

  /// A `<clip-path>`: everything in this group is drawn only inside it.
  final Track<List<Curve>>? clip;
  final Point pivot;
  final Track<double> translateX;
  final Track<double> translateY;
  final Track<double> scaleX;
  final Track<double> scaleY;
  final Track<double> rotation;
  final List<Group> groups;
  final List<PathItem> paths;

  Iterable<PathItem> get allPaths => [...paths, for (final group in groups) ...group.allPaths];

  /// What this group does to its contents at [timeMs]: translate, then rotate
  /// and scale about the pivot - the order a `<group>` applies them in.
  Matrix matrixAt(int timeMs) {
    final radians = rotation.at(timeMs) * math.pi / 180;
    final cos = math.cos(radians), sin = math.sin(radians);
    final sx = scaleX.at(timeMs), sy = scaleY.at(timeMs);
    final a = cos * sx, b = -sin * sy, d = sin * sx, e = cos * sy;
    return [
      a,
      b,
      translateX.at(timeMs) + pivot.x - (a * pivot.x + b * pivot.y),
      d,
      e,
      translateY.at(timeMs) + pivot.y - (d * pivot.x + e * pivot.y),
    ];
  }

  bool get isAnimated =>
      !translateX.isConstant ||
      !translateY.isConstant ||
      !scaleX.isConstant ||
      !scaleY.isConstant ||
      !rotation.isConstant;

  Group retimed(double scale) => Group(
        name,
        clip: clip?.retimed(scale),
        pivot: pivot,
        translateX: translateX.retimed(scale),
        translateY: translateY.retimed(scale),
        scaleX: scaleX.retimed(scale),
        scaleY: scaleY.retimed(scale),
        rotation: rotation.retimed(scale),
        groups: [for (final group in groups) group.retimed(scale)],
        paths: [for (final path in paths) path.retimed(scale)],
      );
}

/// One `<path>` as it stands at an instant: its loops, and the clips that
/// narrow where they may be drawn.
class Drawn {
  Drawn(this.loops, this.clips);

  final List<List<Point>> loops;
  final List<List<List<Point>>> clips;
}

/// What the emitter writes: a canvas, a length, and a tree.
class Drawable {
  Drawable(this.name, this.canvasDp, this.durationMs, this.roots, {this.source = 'GIF'});

  final String name;
  final double canvasDp;
  final int durationMs;
  final List<Group> roots;

  /// Where the artwork came from, for the report.
  final String source;

  Iterable<PathItem> get paths => [for (final root in roots) ...root.allPaths];

  int get segments => paths.fold(0, (a, s) => a + s.segments);

  Iterable<Group> get groups {
    Iterable<Group> walk(Group group) => [group, for (final g in group.groups) ...walk(g)];
    return [for (final root in roots) ...walk(root)];
  }

  int get morphingPaths => paths.where((s) => !s.data.isConstant).length;

  /// Bezier segments whose path data changes every frame: the work the
  /// renderer repeats.
  int get morphLoad => paths.where((s) => !s.data.isConstant).fold(0, (a, s) => a + s.segments);

  /// The same animation played over [durationMs] instead of its own length.
  ///
  /// Every keyframe moves by one factor, so the motion is identical and only
  /// the clock changes - which is what a duration set in configuration means,
  /// and what keeps an animation inside the one second the platform's splash
  /// screen guidelines ask for.
  Drawable retimed(int durationMs) {
    if (durationMs == this.durationMs) return this;
    final scale = durationMs / this.durationMs;
    return Drawable(
      name,
      canvasDp,
      durationMs,
      [for (final root in roots) root.retimed(scale)],
      source: source,
    );
  }

  /// Every path at [timeMs], in canvas coordinates, with the clips that narrow
  /// it: the model's own answer, to check the written XML against.
  List<Drawn> at(int timeMs, {bool fillsOnly = true}) {
    final out = <Drawn>[];
    void walk(Group group, Matrix parent, List<List<List<Point>>> clips) {
      final local = compose(parent, group.matrixAt(timeMs));
      final clip = group.clip;
      final narrowed = clip == null
          ? clips
          : [
              ...clips,
              [
                for (final curve in clip.at(timeMs))
                  [for (final p in flatten(curve)) transform(local, p)],
              ],
            ];
      for (final path in group.paths) {
        // Comparing filled pixels needs a yes or no, and the middle of a fade
        // is the one place where the answer does not turn on rounding.
        if (fillsOnly && (!path.paint.hasFill || path.paint.alpha.at(timeMs) < 0.5)) continue;
        out.add(Drawn([
          for (final curve in path.data.at(timeMs))
            [for (final p in flatten(curve)) transform(local, p)],
        ], narrowed));
      }
      for (final child in group.groups) {
        walk(child, local, narrowed);
      }
    }

    for (final root in roots) {
      walk(root, identity, const []);
    }
    return out;
  }
}
