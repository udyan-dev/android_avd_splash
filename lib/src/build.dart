import 'dart:math' as math;

import 'contour.dart';
import 'field.dart';
import 'fit.dart';
import 'gif.dart';
import 'model.dart';
import 'paint.dart';
import 'shape.dart';

class Options {
  const Options({
    this.name = 'splash',
    this.canvasDp = 288,
    this.safeRadiusDp = 96,
    this.curveTolerance = 0.15,
    this.rigidTolerance = 0.4,
    this.keyframeTolerance = 0.15,
    this.minAreaDp = 2.0,
    this.minThicknessDp = 0.4,
    this.trim = true,
    this.smooth,
    this.gradients = true,
    this.maxMorphSegments = 400,
    this.durationMs,
    this.background,
    this.colors,
  });

  /// Returns the same options with every tolerance scaled to [dp]: the single
  /// dial the budget search turns.
  Options atQuality(double dp) => Options(
        name: name,
        canvasDp: canvasDp,
        safeRadiusDp: safeRadiusDp,
        curveTolerance: dp,
        rigidTolerance: dp * 2,
        keyframeTolerance: dp,
        minAreaDp: minAreaDp,
        minThicknessDp: minThicknessDp,
        trim: trim,
        smooth: smooth,
        gradients: gradients,
        maxMorphSegments: maxMorphSegments,
        durationMs: durationMs,
        background: background,
        colors: colors,
      );

  /// Resource name stem for the generated files.
  final String name;

  /// Drawable size. 288dp with a 96dp safe radius is the Android splash screen
  /// icon spec: the platform clips the animated icon to a 192dp square.
  final double canvasDp;
  final double safeRadiusDp;

  /// Every tolerance below is in dp *as rendered*, not in GIF pixels, so a
  /// 1000px source and a 200px source of the same artwork cost the same: what
  /// matters is the error a person can see on the screen.
  ///
  /// Largest distance between a fitted Bezier outline and the traced contour.
  final double curveTolerance;

  /// Largest residual that still counts as rigid motion, and so becomes an
  /// animated `<group>` transform instead of path-data morphing.
  final double rigidTolerance;

  /// Largest geometric error allowed when dropping a keyframe.
  final double keyframeTolerance;

  /// Regions that never reach this area, in square dp, are dropped: at this
  /// size they are anti-aliasing debris between two colours, and each one
  /// would otherwise cost a path, a group and an animator of its own.
  final double minAreaDp;

  /// Regions thinner than this, in dp, are dropped however long they are: a
  /// seam where two colours meet is a hairline the screen cannot show, but its
  /// outline is long and it changes shape every frame.
  final double minThicknessDp;

  /// Drop leading blank frames and the static tail.
  final bool trim;

  /// Gaussian blur, in pixels, applied to coverage before tracing. Defaults to
  /// 0.6 for hard-edged GIFs and none for anti-aliased ones.
  final double? smooth;

  /// Fill a path with a gradient when a single colour cannot describe it.
  final bool gradients;

  /// Bezier segments that may morph on every frame. The generator spends its
  /// accuracy budget up to this limit and no further, because path morphing is
  /// what costs the renderer work: a drawable that misses frames looks worse
  /// than one whose outline is a hundredth of a dp off. Zero lifts the limit.
  final int maxMorphSegments;

  /// Plays the animation over this many milliseconds instead of its own
  /// length. The platform's splash screen guidelines ask for one second or
  /// less on phones.
  final int? durationMs;

  /// 0xAARRGGBB overrides for the detected background and paint colours.
  final int? background;
  final List<int>? colors;
}

/// What an animated `<group>` does to a path: translate, then rotate and
/// scale about the pivot. Interpolating these four numbers is exactly what
/// Android interpolates, so a keyframe here means what it will mean on screen.
class Motion {
  const Motion(this.tx, this.ty, this.scale, this.degrees);

  /// The group properties that reproduce [fit] about [pivot].
  factory Motion.of(Similarity fit, Point pivot) {
    final c = math.cos(fit.radians) * fit.scale, s = math.sin(fit.radians) * fit.scale;
    return Motion(
      fit.tx + c * pivot.x - s * pivot.y - pivot.x,
      fit.ty + s * pivot.x + c * pivot.y - pivot.y,
      fit.scale,
      fit.degrees,
    );
  }

  final double tx;
  final double ty;
  final double scale;
  final double degrees;

  static const identity = Motion(0, 0, 1, 0);

  /// The same placement, collapsed to nothing: how a region waits for its turn.
  Motion get hidden => Motion(tx, ty, 0, degrees);

  Point apply(Point pivot, Point p) {
    final radians = degrees * math.pi / 180;
    final c = math.cos(radians) * scale, s = math.sin(radians) * scale;
    final x = p.x - pivot.x, y = p.y - pivot.y;
    return Point(tx + pivot.x + c * x - s * y, ty + pivot.y + s * x + c * y);
  }

  Point unapply(Point pivot, Point p) {
    if (scale.abs() < 1e-12) return pivot;
    final radians = degrees * math.pi / 180;
    final c = math.cos(radians) / scale, s = math.sin(radians) / scale;
    final x = p.x - tx - pivot.x, y = p.y - ty - pivot.y;
    return Point(pivot.x + c * x + s * y, pivot.y - s * x + c * y);
  }

  static Motion lerp(Motion a, Motion b, double t) => Motion(
        a.tx + (b.tx - a.tx) * t,
        a.ty + (b.ty - a.ty) * t,
        a.scale + (b.scale - a.scale) * t,
        a.degrees + (b.degrees - a.degrees) * t,
      );
}

/// One traced region followed through the animation. Its rigid motion lives in
/// an animated `<group>`; only the deformation left over after that motion is
/// taken out has to morph the path data, which is the expensive part.
/// What the tracer measured, for the report and for verification.
class Avd {
  Avd(this.options, this.traced, this.drawable);

  final Options options;
  final Traced traced;
  final Drawable drawable;

  Gif get gif => traced.gif;
  Separation get separation => traced.separation;
  List<int> get frameTimes => traced.times;
  List<int> get frameIndices => traced.indices;
  int get durationMs => traced.durationMs;
  double get scale => traced.scale;
  Point get offset => traced.offset;
  int get droppedRegions => traced.dropped;
}

class Region {
  Region(this.name, this.color, this.slot, this.samples, this.referenceIndex);

  final String name;
  final int color;

  /// The region's shape per kept frame, or null where it is absent.
  final List<Shape?> slot;

  /// Arc-length samples of every loop of every frame, corresponding point for
  /// point across frames. Independent of any accuracy choice, so the tolerance
  /// search reuses them.
  final List<List<List<Point>>> samples;
  final int referenceIndex;
}

class Traced {
  Traced._(this.gif, this.separation, this.regions, this.shapes, this.dropped, this.times,
      this.indices, this.durationMs, this.scale, this.offset);

  final Gif gif;
  final Separation separation;

  /// Every region worth drawing, with its correspondence already solved.
  final List<Region> regions;

  /// Every region there is, per layer and kept frame, in canvas dp: what the
  /// GIF actually contains, before anything is left out. Verification measures
  /// against this instead of tracing the frames a second time.
  final List<List<List<Shape>>> shapes;

  /// Regions left out for being too small or too thin to see.
  final int dropped;
  final List<int> times;
  final List<int> indices;
  final int durationMs;
  final double scale;
  final Point offset;

  static Traced of(Gif gif, Options options) {
    final separation = Separation.of(gif,
        background: options.background, colors: options.colors, smooth: options.smooth);
    final traced = [
      for (final layer in separation.layers)
        [for (final field in layer.fields) trace(field, gif.width, gif.height)],
    ];

    var first = 0, last = gif.frames.length - 1;
    if (options.trim) {
      while (first < last && traced.every((l) => l[first].isEmpty)) {
        first++;
      }
      while (last > first && _same(traced, last, last - 1)) {
        last--;
      }
    }

    var clock = 0;
    final times = <int>[], indices = <int>[];
    for (var i = first; i <= last; i++) {
      times.add(clock);
      indices.add(i);
      clock += gif.frames[i].delayMs;
    }

    // Where the artwork sits and how big it is, straight off the contours.
    var ax = 0.0, ay = 0.0, weight = 0.0;
    for (final shape in [for (final layer in traced) ...layer[last]]) {
      final c = shape.centroid, a = shape.area;
      ax += c.x * a;
      ay += c.y * a;
      weight += a;
    }
    final anchor =
        weight > 0 ? Point(ax / weight, ay / weight) : Point(gif.width / 2, gif.height / 2);
    var radius = 1e-6;
    for (final layer in traced) {
      for (final i in indices) {
        for (final shape in layer[i]) {
          for (final loop in [shape.outer, ...shape.holes]) {
            for (final p in loop) {
              radius = math.max(radius, (p - anchor).length);
            }
          }
        }
      }
    }
    // A tenth of a dp of headroom absorbs coordinate rounding, so the artwork
    // cannot land a hair outside the safe circle and get clipped.
    final scale = (options.safeRadiusDp - 0.1) / radius;
    final offset =
        Point(options.canvasDp / 2 - anchor.x * scale, options.canvasDp / 2 - anchor.y * scale);

    // From here on every number is in canvas dp: tolerances, areas, path data,
    // transforms. The same artwork then costs the same whether the GIF is
    // 200px or 4000px wide, and two decimals are a hundredth of a dp.
    Point toCanvas(Point p) => Point(p.x * scale + offset.x, p.y * scale + offset.y);
    Loop mapLoop(Loop loop) => [for (final p in loop) toCanvas(p)];

    final shapes = [
      for (final layer in traced)
        [
          for (final i in indices)
            [
              for (final shape in layer[i])
                Shape(mapLoop(shape.outer), [for (final hole in shape.holes) mapLoop(hole)]),
            ],
        ],
    ];

    final regions = <Region>[];
    var dropped = 0;
    for (var l = 0; l < separation.layers.length; l++) {
      final slots = _follow(shapes[l]);
      if (slots.isEmpty) {
        throw StateError('nothing to trace in ${separation.layers[l].hex}: '
            'that colour does not appear in the GIF');
      }
      for (var k = 0; k < slots.length; k++) {
        if (!_visible(slots[k], options)) {
          dropped++;
          continue;
        }
        final slot = slots[k];
        final referenceIndex = _reference(slot);
        final model = slot[referenceIndex]!;
        final loops = 1 + slot.fold<int>(0, (a, s) => math.max(a, s?.holes.length ?? 0));
        final outlines = [model.outer, ...model.holes];
        // One sample per GIF pixel of outline: the resolution the contour has.
        final counts = [
          for (var i = 0; i < loops; i++)
            i < outlines.length ? (_perimeter(outlines[i]) / scale).round().clamp(32, 1024) : 32,
        ];
        final suffix = separation.layers.length > 1 ? '${l}_$k' : '$k';
        regions.add(Region('${options.name}_$suffix', separation.layers[l].color, slot,
            _sample(slot, counts, referenceIndex), referenceIndex));
      }
    }
    if (regions.isEmpty) throw StateError('nothing left to animate above --min-area');

    return Traced._(gif, separation, regions, shapes, dropped, times, indices, math.max(clock, 1),
        scale, offset);
  }
}

Avd analyse(Gif gif, Options options) => assemble(Traced.of(gif, options), options);

/// Fits the traced contours into paths, transforms and keyframes.
Avd assemble(Traced traced, Options options) {
  final gif = traced.gif;
  final times = traced.times;
  final indices = traced.indices;
  final duration = traced.durationMs;
  final scale = traced.scale;
  final offset = traced.offset;

  final palette = [for (final layer in traced.separation.layers) layer.color];
  final groups = [
    for (final region in traced.regions)
      if (_region(region, times, duration, indices, gif, scale, offset, options, palette)
          case final group?)
        group,
  ];
  if (groups.isEmpty) throw StateError('nothing left to animate above --min-area');

  // The scale was chosen from the traced contours, but a fitted outline can sit
  // a tolerance outside them. Measure what was actually built and shrink it to
  // fit: the platform clips the animated icon, so this has to be exact.
  final draft = Drawable(options.name, options.canvasDp, duration, groups);
  final centre = Point(options.canvasDp / 2, options.canvasDp / 2);
  var reach = 1e-9;
  for (final t in times) {
    for (final path in draft.at(t, fillsOnly: false)) {
      for (final loop in path.loops) {
        for (final p in loop) {
          reach = math.max(reach, (p - centre).length);
        }
      }
    }
  }
  final allowed = options.safeRadiusDp - 0.05;
  final drawable = reach <= allowed
      ? draft
      : Drawable(options.name, options.canvasDp, duration,
          [for (final group in groups) _shrink(group, allowed / reach, centre)]);
  return Avd(options, traced, drawable);
}

/// Whether a region is ever big enough, and solid enough, to see. Anti-aliased
/// artwork produces specks and hairline seams between colours; each one would
/// cost a path, a group and an animator, and none of them is visible.
bool _visible(List<Shape?> slot, Options options) {
  for (final shape in slot) {
    if (shape == null) continue;
    final thickness = shape.perimeter <= 0 ? 0.0 : 2 * shape.area / shape.perimeter;
    if (shape.area >= options.minAreaDp && thickness >= options.minThicknessDp) return true;
  }
  return false;
}

bool _same(List<List<List<Shape>>> traced, int a, int b) {
  for (final layer in traced) {
    final x = layer[a], y = layer[b];
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if ((x[i].area - y[i].area).abs() > 1e-6) return false;
      if ((x[i].centroid - y[i].centroid).length > 1e-6) return false;
    }
  }
  return true;
}

/// Follows every traced region through the frames, so a region that moves,
/// appears, splits or merges keeps one identity - and one path in the drawable.
/// Matching is against the position predicted from the region's own velocity,
/// which is what lets a fast-moving shape be followed at all.
List<List<Shape?>> _follow(List<List<Shape>> frames) {
  final slots = <List<Shape?>>[];
  final tracks = <_Track>[];
  for (var f = 0; f < frames.length; f++) {
    for (final slot in slots) {
      slot.add(null);
    }
    final shapes = frames[f];
    final pairs = <List<double>>[];
    for (var i = 0; i < shapes.length; i++) {
      final c = shapes[i].centroid, r = math.sqrt(shapes[i].area / math.pi);
      for (var j = 0; j < tracks.length; j++) {
        final d = (c - tracks[j].predict()).length;
        if (d < 16 + 0.6 * (r + tracks[j].radius)) pairs.add([d, i.toDouble(), j.toDouble()]);
      }
    }
    pairs.sort((a, b) => a[0].compareTo(b[0]));
    final usedShape = <int>{}, usedSlot = <int>{};
    for (final pair in pairs) {
      final i = pair[1].toInt(), j = pair[2].toInt();
      if (usedShape.contains(i) || usedSlot.contains(j)) continue;
      usedShape.add(i);
      usedSlot.add(j);
      slots[j][f] = shapes[i];
      tracks[j].move(shapes[i]);
    }
    for (var j = 0; j < tracks.length; j++) {
      if (!usedSlot.contains(j)) tracks[j].lose();
    }
    for (var i = 0; i < shapes.length; i++) {
      if (usedShape.contains(i)) continue;
      slots.add([...List<Shape?>.filled(f, null), shapes[i]]);
      tracks.add(_Track(shapes[i]));
    }
  }
  return slots;
}

class _Track {
  _Track(Shape shape)
      : at = shape.centroid,
        radius = math.sqrt(shape.area / math.pi);

  Point at;
  double radius;
  Point velocity = const Point(0, 0);

  Point predict() => at + velocity;

  void move(Shape shape) {
    velocity = shape.centroid - at;
    at = shape.centroid;
    radius = math.sqrt(shape.area / math.pi);
  }

  /// A region that vanished may come back; it will not come back moving.
  void lose() => velocity = const Point(0, 0);
}

Group? _region(Region region, List<int> times, int duration, List<int> frames, Gif gif,
    double scale, Point offset, Options options, List<int> palette) {
  final name = region.name;
  final color = region.color;
  final slot = region.slot;
  final samples = region.samples;
  final referenceIndex = region.referenceIndex;
  final loops = samples[referenceIndex].length;
  final counts = [for (final loop in samples[referenceIndex]) loop.length];

  // The fewest Bezier segments per outline that still hold the tolerance:
  // double until it fits, then bisect. Starting from the coarsest possible
  // outline is what keeps a 1000px source from costing more than a 200px one
  // of the same artwork.
  final segments = [
    for (var i = 0; i < loops; i++)
      _segments([for (final frame in samples) frame[i]], options.curveTolerance,
          math.max(4, counts[i] ~/ 3)),
  ];
  final knots = [
    for (var i = 0; i < loops; i++)
      chooseKnots([for (final frame in samples) frame[i]], segments[i]),
  ];
  final curves = [
    for (final frame in samples) [for (var i = 0; i < loops; i++) fitSpans(frame[i], knots[i])],
  ];

  // Split the motion from the deformation: fit the best translation, rotation
  // and uniform scale for every frame, keep that in the group, and leave the
  // path data to carry only what the transform cannot express. A shape that
  // merely moves then needs no path animation at all.
  final pivot = _centroid(curves[referenceIndex][0]);
  final reference = curves[referenceIndex].expand((c) => c).toList();
  final motions = <Motion>[];
  // Rigidity is judged on the exact per-frame fits, before the transform track
  // is thinned: otherwise the error saved by dropping a keyframe would be
  // mistaken for deformation and cost a path animation.
  var rigid = true;
  for (var f = 0; f < slot.length; f++) {
    if (slot[f] == null) {
      motions.add((motions.isEmpty ? Motion.identity : motions.last).hidden);
      continue;
    }
    final fit = fitSimilarity(reference, curves[f].expand((c) => c).toList());
    if (fit == null || fit.residual > options.rigidTolerance) rigid = false;
    motions.add(fit == null ? Motion.identity : Motion.of(fit, pivot));
  }
  // GIF frames are held images, not tweened vector keyframes. Keeping every
  // frame as a discrete key prevents Android from inventing in-between path
  // geometry that never existed in the source (and can self-intersect badly).
  final motionKeys = [
    for (var f = 0; f < motions.length; f++) Key(times[f], motions[f], Easing.hold),
  ];

  // The leftover shape, measured in the group's own space against the motion
  // track as it will actually be interpolated. A frame where the region is
  // absent holds the reference outline: the group scales it to nothing there,
  // so its shape is nobody's business.
  Motion at(int timeMs) => _motionAt(motionKeys, timeMs);
  final residuals = [
    for (var f = 0; f < slot.length; f++)
      if (slot[f] == null)
        curves[referenceIndex]
      else
        [
          for (final curve in curves[f]) [for (final p in curve) at(times[f]).unapply(pivot, p)],
        ],
  ];
  final shapeKeys = rigid
      ? [Key(times[referenceIndex], curves[referenceIndex])]
      : [
          for (var f = 0; f < residuals.length; f++) Key(times[f], residuals[f], Easing.hold),
        ];

  // The fill is read off the GIF in canvas space; the path is drawn in the
  // group's space, so a gradient axis has to come back through the transform.
  final measured = options.colors != null
      ? Paint(color: color)
      : fitFill(gif, frames[referenceIndex], curves[referenceIndex], scale, offset, color,
          palette: palette, gradients: options.gradients);
  if (measured == null) return null;
  final gradient = measured.gradient;
  final fill = gradient == null
      ? measured
      : Paint(
          color: measured.color,
          gradient: Gradient(
            gradient.type,
            at(times[referenceIndex]).unapply(pivot, gradient.start),
            at(times[referenceIndex]).unapply(pivot, gradient.end),
            gradient.stops,
            gradient.radius,
          ),
        );
  if (motionKeys.last.timeMs != duration) {
    motionKeys.add(Key(duration, motionKeys.last.value));
  }
  return Group(
    '${name}_group',
    pivot: pivot,
    translateX: Track([for (final k in motionKeys) Key(k.timeMs, k.value.tx, k.easing)]),
    translateY: Track([for (final k in motionKeys) Key(k.timeMs, k.value.ty, k.easing)]),
    scaleX: Track([for (final k in motionKeys) Key(k.timeMs, k.value.scale, k.easing)]),
    scaleY: Track([for (final k in motionKeys) Key(k.timeMs, k.value.scale, k.easing)]),
    rotation: Track([for (final k in motionKeys) Key(k.timeMs, k.value.degrees, k.easing)]),
    paths: [
      PathItem(
        name,
        Track([for (final k in shapeKeys) Key(k.timeMs, k.value, k.easing)]),
        fill.asEvenOdd(),
      ),
    ],
  );
}

/// The same group inside a drawable shrunk by [k] about [centre]: one
/// similarity over every number, so nothing has to be fitted again.
Group _shrink(Group group, double k, Point centre) {
  Point move(Point p) => Point(centre.x + (p.x - centre.x) * k, centre.y + (p.y - centre.y) * k);
  Track<double> scaled(Track<double> track) =>
      Track([for (final key in track.keys) Key(key.timeMs, key.value * k, key.easing)]);
  return Group(
    group.name,
    pivot: move(group.pivot),
    translateX: scaled(group.translateX),
    translateY: scaled(group.translateY),
    scaleX: group.scaleX,
    scaleY: group.scaleY,
    rotation: group.rotation,
    clip: group.clip,
    groups: [for (final child in group.groups) _shrink(child, k, centre)],
    paths: [
      for (final path in group.paths)
        PathItem(
          path.name,
          Track([
            for (final key in path.data.keys)
              Key(
                  key.timeMs,
                  [
                    for (final curve in key.value) [for (final p in curve) move(p)],
                  ],
                  key.easing),
          ]),
          _shrinkPaint(path.paint, k, centre),
        ),
    ],
  );
}

Paint _shrinkPaint(Paint paint, double k, Point centre) {
  final gradient = paint.gradient;
  if (gradient == null) return paint;
  Point move(Point p) => Point(centre.x + (p.x - centre.x) * k, centre.y + (p.y - centre.y) * k);
  return Paint(
    color: paint.color,
    gradient: Gradient(gradient.type, move(gradient.start), move(gradient.end), gradient.stops,
        gradient.radius * k),
    alpha: paint.alpha,
    evenOdd: paint.evenOdd,
  );
}

Motion _motionAt(List<Key<Motion>> keys, int timeMs) {
  if (timeMs <= keys.first.timeMs) return keys.first.value;
  for (var i = 1; i < keys.length; i++) {
    if (timeMs <= keys[i].timeMs) {
      final span = keys[i].timeMs - keys[i - 1].timeMs;
      final t = span <= 0 ? 1.0 : (timeMs - keys[i - 1].timeMs) / span;
      return Motion.lerp(keys[i - 1].value, keys[i].value, t);
    }
  }
  return keys.last.value;
}

/// Fewest segments whose fit stays inside [tolerance] on every frame, never
/// more than [cap].
int _segments(List<List<Point>> frames, double tolerance, int cap) {
  // The error to beat is the ninth decile across frames, not the worst frame:
  // one transient - a region caught mid-appearance, a few jagged pixels wide -
  // would otherwise set the segment count for the whole animation.
  double error(int count) {
    final knots = chooseKnots(frames, count);
    final errors = [
      for (final samples in frames) fitError(fitSpans(samples, knots), samples, knots),
    ]..sort();
    return errors[(errors.length * 0.9).floor().clamp(0, errors.length - 1)];
  }

  var low = 4, high = 4;
  while (error(high) > tolerance) {
    low = high;
    if (high >= cap) return cap;
    high = math.min(cap, (high * 1.6).ceil());
  }
  while (high - low > 1) {
    final middle = (low + high) ~/ 2;
    if (error(middle) > tolerance) {
      low = middle;
    } else {
      high = middle;
    }
  }
  return high;
}

/// Arc-length samples of every loop of every frame, point-for-point
/// corresponding across frames. Frames where the region is absent collapse
/// onto a point of the nearest frame that has it, so it grows out of its own
/// outline instead of fading or sliding in.
List<List<List<Point>>> _sample(List<Shape?> slot, List<int> counts, int referenceIndex) {
  final out = List<List<List<Point>>?>.filled(slot.length, null);
  out[referenceIndex] = _normalise(slot[referenceIndex]!, counts, null);
  for (final step in [1, -1]) {
    var guide = out[referenceIndex]!;
    for (var f = referenceIndex + step; f >= 0 && f < slot.length; f += step) {
      final shape = slot[f];
      if (shape == null) continue;
      guide = _normalise(shape, counts, guide);
      out[f] = guide;
    }
  }
  for (var f = 0; f < slot.length; f++) {
    if (out[f] != null) continue;
    final near = out[_nearest(out, f)]!;
    final anchor = _closest(near[0], _centroid(near[0]));
    out[f] = [for (final count in counts) List.filled(count, anchor)];
  }
  return [for (final frame in out) frame!];
}

int _reference(List<Shape?> slot) {
  var best = -1, bestLoops = -1;
  var bestPerimeter = -1.0;
  for (var i = 0; i < slot.length; i++) {
    final s = slot[i];
    if (s == null) continue;
    // Prefer the frame with the most holes, then the most outline detail: it
    // has to supply the structure every other frame is matched against.
    if (s.holes.length > bestLoops ||
        (s.holes.length == bestLoops && s.perimeter > bestPerimeter)) {
      bestLoops = s.holes.length;
      bestPerimeter = s.perimeter;
      best = i;
    }
  }
  return best;
}

List<List<Point>> _normalise(Shape shape, List<int> counts, List<List<Point>>? guide) {
  final out = <List<Point>>[];
  out.add(guide == null ? resample(shape.outer, counts[0]) : align(guide[0], shape.outer));
  final holes = [...shape.holes];
  for (var i = 1; i < counts.length; i++) {
    if (holes.isEmpty) {
      out.add(List.filled(counts[i], _closest(out[0], _centroid(out[0]))));
      continue;
    }
    final want = guide != null ? _centroid(guide[i]) : _centroid(out[0]);
    holes.sort((a, b) => (_centroid(a) - want).length.compareTo((_centroid(b) - want).length));
    final loop = holes.removeAt(0);
    out.add(guide == null ? resample(loop, counts[i]) : align(guide[i], loop));
  }
  return out;
}

int _nearest(List<List<List<Point>>?> frames, int f) {
  for (var d = 1; d < frames.length; d++) {
    if (f - d >= 0 && frames[f - d] != null) return f - d;
    if (f + d < frames.length && frames[f + d] != null) return f + d;
  }
  throw StateError('region never appears');
}

Point _closest(List<Point> points, Point to) =>
    points.reduce((a, b) => (a - to).length <= (b - to).length ? a : b);

Point _centroid(List<Point> points) {
  var x = 0.0, y = 0.0;
  for (final p in points) {
    x += p.x;
    y += p.y;
  }
  return Point(x / points.length, y / points.length);
}

double _perimeter(Loop loop) {
  var sum = 0.0;
  for (var i = 0; i < loop.length; i++) {
    sum += (loop[(i + 1) % loop.length] - loop[i]).length;
  }
  return sum;
}
