import 'dart:math' as math;

import 'contour.dart';
import 'fit.dart';
import 'model.dart';
import 'raster.dart';
import 'winding.dart';

/// The faintest paint that still counts as artwork when the fit is measured.
/// Only a paint that has faded to nothing is left out.
const _faintest = 1 / 512;

/// Lays a converted vector animation out on the icon canvas: clipped to the
/// box its author drew in, centred on what it actually shows, and scaled to
/// reach the radius the platform leaves visible.
///
/// Both vector front ends land here, so a Lottie file and an SVG are fitted
/// and measured by exactly the same rules.
Drawable place({
  required String name,
  required String source,
  required List<Group> roots,
  required double width,
  required double height,
  required int durationMs,
  required List<int> samples,
  required double canvasDp,
  required double safeRadiusDp,
  required double toleranceDp,
  bool trim = true,
}) {
  // A plate behind the artwork is the background, not the icon: the platform
  // masks the icon to a circle, so a square can only ever be drawn with its
  // corners cut, and it spends the whole icon on colour.
  final plate = _plate(roots, width, height);
  var painted = plate == null ? roots : _without(roots, plate.$2);

  // The source draws inside its own box and clips whatever leaves it, so the
  // drawable does too. Without this a shape that flies in from far outside is
  // measured as part of the artwork and the whole animation is shrunk to make
  // room for motion nobody ever sees. The box is a clip on the drawable and a
  // clamp on the measurements, which are the same thing said twice.
  final frame = frameClip(width, height);
  Point inside(Point p) =>
      Point(p.x.clamp(0.0, width).toDouble(), p.y.clamp(0.0, height).toDouble());
  final draft = Drawable(name, canvasDp, durationMs, painted, source: source);
  var covered = [for (final time in samples) _covered(draft, time, inside)];

  // Time before the first mark and after the last one is a splash screen
  // showing nothing, so it is cut and the animation keeps its own speed.
  if (trim) {
    var first = 0, last = samples.length - 1;
    while (first <= last && covered[first].isEmpty) {
      first++;
    }
    while (last >= first && covered[last].isEmpty) {
      last--;
    }
    if (first > last) throw StateError('the animation draws nothing');
    final start = samples[first], end = samples[last];
    if (start > 0 || end < durationMs) {
      painted = [for (final group in painted) group.mapped(1, -start)];
      durationMs = end - start;
      samples = [for (var i = first; i <= last; i++) samples[i] - start];
      covered = covered.sublist(first, last + 1);
    }
  }

  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final shot in covered) {
    for (final p in shot) {
      minX = math.min(minX, p.x);
      minY = math.min(minY, p.y);
      maxX = math.max(maxX, p.x);
      maxY = math.max(maxY, p.y);
    }
  }
  if (!minX.isFinite) throw StateError('the animation draws nothing');
  final centre = Point((minX + maxX) / 2, (minY + maxY) / 2);
  var radius = 1e-9;
  for (final shot in covered) {
    for (final p in shot) {
      radius = math.max(radius, (p - centre).length);
    }
  }
  final scale = (safeRadiusDp - 0.05) / radius;
  return Drawable(
    name,
    canvasDp,
    durationMs,
    [
      Group(
        '${name}_root',
        pivot: centre,
        translateX: Track.constant(canvasDp / 2 - centre.x),
        translateY: Track.constant(canvasDp / 2 - centre.y),
        scaleX: Track.constant(scale),
        scaleY: Track.constant(scale),
        groups: [
          Group('${name}_frame',
              clip: Track.constant(frame),
              // Baked geometry is thinned here, where one unit of the source is
              // a known number of dp: a keyframe is worth keeping only where a
              // person could see it.
              groups: [for (final group in painted) _thinGroup(group, toleranceDp / scale)]),
        ],
      ),
    ],
    source: source,
    plate: plate?.$1,
  );
}

/// Points on the boundary of everything the artwork covers at [timeMs].
///
/// A clip is part of the drawing. A layer a matte hides is not on screen, and
/// measuring it anyway is what leaves an icon smaller than the platform allows
/// and off the centre of its own canvas - so where a clip narrows a path its
/// coverage is rasterised and read back as the ends of every row it fills,
/// which is the answer the verifier gives. Where nothing narrows a path its
/// outline is used as it stands, which is exact and costs nothing.
///
/// [inside] is the source's own box: what it clamps away the frame clip cuts.
List<Point> _covered(Drawable draft, int timeMs, Point Function(Point) inside) {
  final out = <Point>[];
  for (final path in draft.at(timeMs, fillsOnly: false, minAlpha: _faintest)) {
    final painted = path.painted;
    if (!_spreads(painted)) continue;
    if (path.clips.isEmpty) {
      for (final loop in painted) {
        for (final p in loop) {
          out.add(inside(p));
        }
      }
      continue;
    }
    _narrowed(painted, path.clips, (p) => out.add(inside(p)));
  }
  return out;
}

/// Whether any of [loops] has room between two of its points. A shape a group
/// has scaled away is still a list of points, all of them in one place.
bool _spreads(List<List<Point>> loops) {
  for (final loop in loops) {
    for (final p in loop) {
      if ((p - loop.first).length > 1e-6) return true;
    }
  }
  return false;
}

/// The area [painted] keeps once every clip has narrowed it, as the ends of
/// each row of a raster of its own bounding box - so the cost is the shape's
/// area and not the canvas's.
void _narrowed(List<List<Point>> painted, List<List<List<Point>>> clips, void Function(Point) add) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final loop in painted) {
    for (final p in loop) {
      minX = math.min(minX, p.x);
      minY = math.min(minY, p.y);
      maxX = math.max(maxX, p.x);
      maxY = math.max(maxY, p.y);
    }
  }
  const perUnit = 2.0;
  final w = ((maxX - minX) * perUnit).ceil() + 1;
  final h = ((maxY - minY) * perUnit).ceil() + 1;
  // A shape far larger than the canvas is about to be clamped to it anyway,
  // and its outline is the nearest honest answer.
  if (w < 1 || h < 1 || w * h > 1 << 22) {
    for (final loop in painted) {
      for (final p in loop) {
        add(p);
      }
    }
    return;
  }
  List<List<Point>> local(List<List<Point>> loops) => [
        for (final loop in loops)
          [for (final p in loop) Point((p.x - minX) * perUnit, (p.y - minY) * perUnit)],
      ];
  final mask = rasterise(local(painted), w, h);
  for (final clip in clips) {
    // Non-zero because that is the only rule a `<clip-path>` has.
    final allowed = rasterise(local(clip), w, h, nonZero: true);
    for (var i = 0; i < mask.length; i++) {
      if (allowed[i] == 0) mask[i] = 0;
    }
  }
  for (var y = 0; y < h; y++) {
    final row = y * w;
    final top = minY + y / perUnit, bottom = minY + (y + 1) / perUnit;
    var run = -1;
    for (var x = 0; x <= w; x++) {
      final on = x < w && mask[row + x] != 0;
      if (on && run < 0) run = x;
      if (on || run < 0) continue;
      final left = minX + run / perUnit, right = minX + x / perUnit;
      add(Point(left, top));
      add(Point(right, top));
      add(Point(left, bottom));
      add(Point(right, bottom));
      run = -1;
    }
  }
}

/// The colour of a plate filling the whole box, and the path that draws it./// The colour of a plate filling the whole box, and the path that draws it.
///
/// Only the bottom-most shape counts, and only when it never moves, is opaque,
/// and covers the box: that is a background, and anything else is artwork that
/// happens to be large.
(int, PathItem)? _plate(List<Group> roots, double width, double height) {
  PathItem? first;
  void walk(Group group) {
    for (final path in group.paths) {
      first ??= path;
      if (first != null) return;
    }
    for (final child in group.groups) {
      if (first == null) walk(child);
    }
  }

  for (final root in roots) {
    if (first == null) walk(root);
  }
  final path = first;
  if (path == null) return null;
  final paint = path.paint;
  final colour = paint.color;
  if (colour == null ||
      paint.gradient != null ||
      paint.hasStroke ||
      !paint.alpha.isConstant ||
      paint.alpha.first < 1 ||
      (colour >> 24) != 0xFF ||
      !path.data.isConstant) {
    return null;
  }
  final loops = path.data.first;
  if (loops.length != 1) return null;
  var left = double.infinity, top = double.infinity;
  var right = -double.infinity, bottom = -double.infinity;
  for (final point in loops.single) {
    left = math.min(left, point.x);
    top = math.min(top, point.y);
    right = math.max(right, point.x);
    bottom = math.max(bottom, point.y);
  }
  final covers = right - left >= width * 0.98 && bottom - top >= height * 0.98;
  // A rounded corner costs a little area; a shape that is not a plate costs
  // much more than that.
  final filled = signedArea(flattenLoop(loops.single)).abs() >= width * height * 0.9;
  return covers && filled ? (colour, path) : null;
}

/// The same tree without one path, and without the groups it emptied.
List<Group> _without(List<Group> roots, PathItem path) {
  Group? strip(Group group) {
    final paths = [
      for (final own in group.paths)
        if (!identical(own, path)) own,
    ];
    final groups = [
      for (final child in group.groups)
        if (strip(child) case final kept?) kept,
    ];
    if (paths.isEmpty && groups.isEmpty && group.clip == null) return null;
    return Group(
      group.name,
      clip: group.clip,
      pivot: group.pivot,
      translateX: group.translateX,
      translateY: group.translateY,
      scaleX: group.scaleX,
      scaleY: group.scaleY,
      rotation: group.rotation,
      groups: groups,
      paths: paths,
    );
  }

  return [
    for (final root in roots)
      if (strip(root) case final kept?) kept,
  ];
}

/// The source's own box, as a clip: four straight cubics wound one way, which
/// is all a `<clip-path>` needs to keep the artwork inside the frame.
///
/// The corners are whole units and each cubic parks its handles on the point it
/// starts from, so the path data is the shortest that traces the box exactly.
List<Curve> frameClip(double width, double height) {
  final corners = [
    const Point(0, 0),
    Point(width, 0),
    Point(width, height),
    Point(0, height),
  ];
  final loop = <Point>[corners[0]];
  for (var i = 0; i < 4; i++) {
    loop.addAll([corners[i], corners[i], corners[(i + 1) % 4]]);
  }
  return [loop];
}

/// The same group with every baked outline thinned to [tolerance].
Group _thinGroup(Group group, double tolerance) => Group(
      group.name,
      clip: group.clip == null ? null : Track(_thin(group.clip!.keys, tolerance)),
      pivot: group.pivot,
      translateX: group.translateX,
      translateY: group.translateY,
      scaleX: group.scaleX,
      scaleY: group.scaleY,
      rotation: group.rotation,
      groups: [for (final child in group.groups) _thinGroup(child, tolerance)],
      paths: [
        for (final path in group.paths)
          PathItem(path.name, Track(_thin(path.data.keys, tolerance)), path.paint),
      ],
    );

/// Douglas-Peucker on path data: a keyframe survives only where dropping it
/// would move the outline more than the tolerance.
List<Key<List<Curve>>> _thin(List<Key<List<Curve>>> keys, double tolerance) {
  if (keys.length < 3) return keys;
  final keep = List<bool>.filled(keys.length, false);
  keep[0] = keep[keys.length - 1] = true;
  void split(int a, int b) {
    if (b - a < 2) return;
    var worst = -1;
    var error = tolerance;
    for (var i = a + 1; i < b; i++) {
      final t = (keys[i].timeMs - keys[a].timeMs) / (keys[b].timeMs - keys[a].timeMs);
      var local = 0.0;
      for (var c = 0; c < keys[i].value.length; c++) {
        for (var k = 0; k < keys[i].value[c].length; k++) {
          final guess = keys[a].value[c][k] + (keys[b].value[c][k] - keys[a].value[c][k]) * t;
          final d = (keys[i].value[c][k] - guess).length;
          if (d > local) local = d;
        }
      }
      if (local > error) {
        error = local;
        worst = i;
      }
    }
    if (worst < 0) return;
    keep[worst] = true;
    split(a, worst);
    split(worst, b);
  }

  split(0, keys.length - 1);
  return [
    for (var i = 0; i < keys.length; i++)
      if (keep[i]) keys[i],
  ];
}
