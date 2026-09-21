import 'dart:math' as math;

import 'contour.dart';
import 'fit.dart';
import 'stroke.dart';
import 'trim.dart';

/// Cubic-bezier timing, in the same parameterisation Lottie keyframes and
/// Android's `<pathInterpolator>` both use.
class Easing {
  const Easing(this.x1, this.y1, this.x2, this.y2);

  final double x1;
  final double y1;
  final double x2;
  final double y2;

  static const linear = Easing(0, 0, 1, 1);
  static const hold = Easing(1, 0, 1, 0);

  bool get isLinear => x1 == 0 && y1 == 0 && x2 == 1 && y2 == 1;
  bool get isHold => x1 == 1 && y1 == 0 && x2 == 1 && y2 == 0;

  /// Two easings of the same shape are one curve, so they are one
  /// `<pathInterpolator>` resource however many keyframes reach for them.
  @override
  bool operator ==(Object other) =>
      other is Easing && other.x1 == x1 && other.y1 == y1 && other.x2 == x2 && other.y2 == y2;

  @override
  int get hashCode => Object.hash(x1, y1, x2, y2);

  /// Eased progress at [t], by Newton iteration on the x curve.
  double call(double t) {
    if (isHold) return t >= 1 ? 1 : 0;
    if (isLinear || t <= 0) return t <= 0 ? 0 : (t >= 1 ? 1 : t);
    if (t >= 1) return 1;
    final u = _parameterAt(t);
    final v = 1 - u;
    return 3 * v * v * u * y1 + 3 * v * u * u * y2 + u * u * u;
  }

  /// This easing cut in two at [at] of its interval: the shape the first part
  /// has on its own, and the shape the second part has on its own.
  ///
  /// Cutting a keyframe interval short - which is what shortening an animation
  /// does to the interval the new end lands in - leaves an interval whose
  /// easing is no longer the one that was written: the same curve read over
  /// less of itself, stretched back out to a full interval. A cubic splits
  /// into two cubics exactly, so the parts are written rather than
  /// approximated and the motion is the motion the author drew.
  (Easing, Easing) split(double at) {
    if (at <= 0 || at >= 1) return (Easing.linear, this);
    if (isLinear) return (linear, linear);
    if (isHold) return (linear, hold);
    final u = _parameterAt(at);
    final v = 1 - u;
    // De Casteljau on the control polygon (0,0) (x1,y1) (x2,y2) (1,1).
    final ax = u * x1, ay = u * y1;
    final bx = v * x1 + u * x2, by = v * y1 + u * y2;
    final cx = v * x2 + u, cy = v * y2 + u;
    final dx = v * ax + u * bx, dy = v * ay + u * by;
    final ex = v * bx + u * cx, ey = v * by + u * cy;
    final px = v * dx + u * ex, py = v * dy + u * ey;
    // Each part is stretched back to run from (0,0) to (1,1). A part whose
    // value never moves has no shape to keep.
    final before = py <= 0 || px <= 0 ? linear : Easing(ax / px, ay / py, dx / px, dy / py);
    final after = py >= 1 || px >= 1
        ? linear
        : Easing(
            (ex - px) / (1 - px), (ey - py) / (1 - py), (cx - px) / (1 - px), (cy - py) / (1 - py));
    return (before, after);
  }

  /// Where on the curve x reaches [t], by Newton iteration.
  double _parameterAt(double t) {
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
    return u;
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

  Track<T> mapped(double scale, int shiftMs) => Track([
        for (final key in keys) Key((key.timeMs * scale).round() + shiftMs, key.value, key.easing),
      ]);

  /// The two keys around [timeMs] and the eased progress between them, or null
  /// where the track is already settled.
  (Key<T>, Key<T>, double)? span(int timeMs) {
    if (isConstant || timeMs <= keys.first.timeMs) return null;
    for (var i = 1; i < keys.length; i++) {
      if (timeMs <= keys[i].timeMs) {
        // Several values at one instant are a step, and the value a step
        // leaves behind is the last of them - which is what the platform
        // shows, and so what the model has to say too.
        var last = i;
        while (last + 1 < keys.length && keys[last + 1].timeMs == timeMs) {
          last++;
        }
        final a = keys[last - 1], b = keys[last];
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
    this.evenOdd = false,
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

  /// Fill rule. Lottie records one per fill and defaults to non-zero, which is
  /// what the author drew their overlapping subpaths for; even-odd would open
  /// holes where they meant solid.
  final bool evenOdd;

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
        evenOdd: evenOdd,
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
        evenOdd: evenOdd,
      );

  Paint mapped(double scale, int shiftMs) => Paint(
        color: color,
        gradient: gradient,
        alpha: alpha.mapped(scale, shiftMs),
        strokeColor: strokeColor,
        strokeAlpha: strokeAlpha.mapped(scale, shiftMs),
        strokeWidth: strokeWidth.mapped(scale, shiftMs),
        cap: cap,
        join: join,
        trimStart: trimStart.mapped(scale, shiftMs),
        trimEnd: trimEnd.mapped(scale, shiftMs),
        trimOffset: trimOffset.mapped(scale, shiftMs),
        evenOdd: evenOdd,
      );

  /// The same paint filled by the even-odd rule: how a traced region says
  /// "outer loop, minus its holes" in one path.
  Paint asEvenOdd() => Paint(
        color: color,
        gradient: gradient,
        alpha: alpha,
        strokeColor: strokeColor,
        strokeAlpha: strokeAlpha,
        strokeWidth: strokeWidth,
        cap: cap,
        join: join,
        trimStart: trimStart,
        trimEnd: trimEnd,
        trimOffset: trimOffset,
        evenOdd: true,
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
        evenOdd: evenOdd,
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

  PathItem mapped(double scale, int shiftMs) =>
      PathItem(name, data.mapped(scale, shiftMs), paint.mapped(scale, shiftMs));
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

  Group mapped(double scale, int shiftMs) => Group(
        name,
        clip: clip?.mapped(scale, shiftMs),
        pivot: pivot,
        translateX: translateX.mapped(scale, shiftMs),
        translateY: translateY.mapped(scale, shiftMs),
        scaleX: scaleX.mapped(scale, shiftMs),
        scaleY: scaleY.mapped(scale, shiftMs),
        rotation: rotation.mapped(scale, shiftMs),
        groups: [for (final group in groups) group.mapped(scale, shiftMs)],
        paths: [for (final path in paths) path.mapped(scale, shiftMs)],
      );
}

/// One `<path>` as it stands at an instant: its loops, and the clips that
/// narrow where they may be drawn.
class Drawn {
  Drawn(
    this.loops,
    this.clips, {
    this.fills = true,
    this.stroke = 0,
    List<List<Point>>? stroked,
    this.strokeClosed = true,
  }) : stroked = stroked ?? loops;

  /// The outline, as the fill sees it.
  final List<List<Point>> loops;

  /// The outline the stroke follows: the same thing, with a trim cut out of it.
  final List<List<Point>> stroked;
  final List<List<List<Point>>> clips;

  /// Whether the loops are filled, as against only stroked.
  final bool fills;

  /// The width of the stroke along [stroked], in the same space as it is, or
  /// zero when nothing is stroked. A stroke reaches half of it to either side
  /// of the outline, which is what makes it part of the artwork.
  final double stroke;

  /// Whether the stroked outline closes. A trim that does not cover the whole
  /// path leaves an open arc, and an open arc's band runs out along one side
  /// and back along the other.
  final bool strokeClosed;

  /// Everything this paints: the fill, and the band the stroke covers.
  List<List<Point>> get painted => [
        if (fills) ...loops,
        if (stroke > 0)
          for (final loop in stroked)
            ...strokeBands(loop, stroke,
                closed: strokeClosed && (loop.first - loop.last).length <= 1e-6),
      ];
}

/// What the emitter writes: a canvas, a length, and a tree.
class Drawable {
  Drawable(this.name, this.canvasDp, this.durationMs, this.roots,
      {this.source = 'GIF', this.plate});

  final String name;
  final double canvasDp;
  final int durationMs;
  final List<Group> roots;

  /// Where the artwork came from, for the report.
  final String source;

  /// The colour of a full-bleed plate the artwork was drawn on, when it had
  /// one and it was dropped.
  ///
  /// The platform masks the animated icon to a circle, so a square behind the
  /// artwork can never be drawn as its author meant it: its corners are cut
  /// and it spends the whole icon on colour. It belongs to the splash
  /// background or the icon background instead, and it is reported here so
  /// the caller can put it there.
  final int? plate;

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
      plate: plate,
    );
  }

  /// Every path at [timeMs], in canvas coordinates, with the clips that narrow
  /// it: the model's own answer, to check the written XML against.
  ///
  /// With [fillsOnly] the answer is what Android fills, which is what a pixel
  /// comparison needs; without it, anything visible counts, stroke or fill,
  /// which is what measuring the artwork needs.
  /// Every path as it stands at [timeMs], with the clips that narrow it.
  ///
  /// [minAlpha] is how faint a paint may be and still count. Half is the right
  /// answer when the result is a pixel mask - the middle of a fade is the one
  /// place where a yes or a no does not turn on rounding - and near zero is the
  /// right answer when the question is how far the artwork reaches, because
  /// faint artwork is still on screen.
  List<Drawn> at(int timeMs, {bool fillsOnly = true, double minAlpha = 0.5}) {
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
        final paint = path.paint;
        final fills = paint.hasFill && paint.alpha.at(timeMs) >= minAlpha;
        final strokes = paint.hasStroke && paint.strokeAlpha.at(timeMs) >= minAlpha;
        if (fillsOnly ? !fills : !(fills || strokes)) continue;
        // A stroke is measured in the path's own space and drawn in the
        // group's, so its width travels through the same transform the
        // geometry does.
        final scale = math.sqrt((local[0] * local[4] - local[1] * local[3]).abs());
        final curves = path.data.at(timeMs);
        // Android trims what it strokes and nothing else, so the fill keeps
        // the whole outline and the stroke follows the trimmed one.
        final start = paint.trimStart.at(timeMs), end = paint.trimEnd.at(timeMs);
        final closed = (end - start).abs() >= 1 - 1e-9;
        final trimmed = strokes && !closed
            ? trimPieces(curves, start, end, paint.trimOffset.at(timeMs))
            : curves;
        out.add(Drawn(
          [
            for (final curve in curves) [for (final p in flatten(curve)) transform(local, p)],
          ],
          narrowed,
          fills: fills,
          stroke: strokes ? paint.strokeWidth.at(timeMs) * scale : 0,
          stroked: [
            for (final curve in trimmed) [for (final p in flatten(curve)) transform(local, p)],
          ],
          strokeClosed: closed,
        ));
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

/// Two tracks multiplied together, sampled wherever either one has a key.
///
/// This is how an opacity that sits above a paint reaches it: a `<group>`
/// cannot carry alpha, so the alpha has to arrive already folded into the
/// paints below it.
Track<double> multiplyTracks(Track<double> a, Track<double> b) {
  if (a.isConstant && b.isConstant) return Track.constant(a.first * b.first);
  if (a.isConstant && a.first == 1) return b;
  if (b.isConstant && b.first == 1) return a;
  final times = <int>{...a.keys.map((k) => k.timeMs), ...b.keys.map((k) => k.timeMs)}.toList()
    ..sort();
  return Track([
    for (final time in times)
      Key(time, a.at(time) * b.at(time), turnAt(a, time) ?? turnAt(b, time) ?? Easing.linear),
  ]);
}

/// The easing a track turns with at [timeMs], when it turns there at all.
Easing? turnAt(Track<double> track, int timeMs) {
  for (final key in track.keys) {
    if (key.timeMs == timeMs && !key.easing.isLinear) return key.easing;
  }
  return null;
}
