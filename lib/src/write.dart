import 'dart:math' as math;

import 'contour.dart';
import 'fit.dart';
import 'model.dart';
import 'stamp.dart';
import 'winding.dart';

/// Renders a [Drawable] as Android resource files, keyed by path relative to
/// `res/`. Animation lives in three places, and each is used for what it is
/// best at: a `<group>` transform for motion, `pathData` morphing for genuine
/// deformation, and the paint properties - alpha, stroke width, trim - for
/// everything a shape does without changing shape.
Map<String, String> render(Drawable drawable, {double? canvasOverride}) {
  final files = <String, String>{};
  final interpolators = <Easing, String>{};

  String interpolator(Easing easing) {
    if (easing.isLinear) return '@android:anim/linear_interpolator';
    final name =
        interpolators.putIfAbsent(easing, () => '${drawable.name}_ease${interpolators.length + 1}');
    files['interpolator/$name.xml'] = '$xmlHeader'
        '<pathInterpolator xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:controlX1="${_n(easing.x1, 4)}" android:controlY1="${_n(easing.y1, 4)}"\n'
        '    android:controlX2="${_n(easing.x2, 4)}" android:controlY2="${_n(easing.y2, 4)}"/>\n';
    return '@interpolator/$name';
  }

  final targets = <String>[];

  /// A float track as one `<objectAnimator>` with per-keyframe easing. Every
  /// track is padded to the full timeline: the native animator extrapolates
  /// past its outermost keyframes instead of holding them, so a track that
  /// stops short keeps drifting.
  void floats(String target, Map<String, Track<double>> tracks) {
    tracks.removeWhere((_, track) => track.isConstant);
    if (tracks.isEmpty) return;
    tracks.updateAll((_, track) => _stepped(_span(track, drawable.durationMs)));
    // A track can carry several keys and never leave its value - a source
    // often writes one - and the `<path>` or `<group>` already holds it.
    tracks.removeWhere((_, track) => track.keys.every((key) => key.value == track.first));
    if (tracks.isEmpty) return;
    // The animator's own interpolator warps the whole track before a keyframe
    // is ever consulted, and `AnimatorInflater` defaults it to
    // accelerate-decelerate. The timeline is the source's own, so it has to be
    // said out loud that nothing bends it: the easing belongs to the
    // keyframes, one interval at a time.
    final out = StringBuffer(xmlHeader)
      ..writeln('<objectAnimator xmlns:android="http://schemas.android.com/apk/res/android"')
      ..writeln('    android:duration="${drawable.durationMs}"')
      ..writeln('    android:interpolator="@android:anim/linear_interpolator">');
    tracks.forEach((property, track) {
      out.writeln('    <propertyValuesHolder android:propertyName="$property"'
          ' android:valueType="floatType">');
      for (var i = 0; i < track.keys.length; i++) {
        final key = track.keys[i];
        // A keyframe carries the easing that leads into it, so the easing of
        // one Lottie or GIF interval belongs to the key that closes it.
        final lead = i == 0 ? Easing.linear : track.keys[i - 1].easing;
        out.writeln('        <keyframe'
            ' android:fraction="${_n(key.timeMs / drawable.durationMs, 6)}"'
            ' android:value="${_n(key.value, 6)}"'
            '${lead.isLinear ? '' : ' android:interpolator="${interpolator(lead)}"'}/>');
      }
      out.writeln('    </propertyValuesHolder>');
    });
    out.writeln('</objectAnimator>');
    files['animator/$target.xml'] = out.toString();
    targets.add(target);
  }

  /// Path data as a sequential set of one-step morphs: `AnimatorInflater`
  /// ignores `pathData` keyframes, so this is the only form that works.
  void morph(String target, Track<List<Curve>> data) {
    if (data.isConstant) return;
    data = _span(data, drawable.durationMs);
    final closures = _closures(data);
    final steps = <({int durationMs, String from, String to, Easing easing})>[];
    var clock = 0;
    for (var i = 0; i < data.keys.length - 1; i++) {
      final from = data.keys[i], to = data.keys[i + 1];
      final held = from.easing.isHold;
      clock += to.timeMs - from.timeMs;
      steps.add((
        durationMs: to.timeMs - from.timeMs,
        from: pathData(from.value, closures),
        to: pathData(held ? from.value : to.value, closures),
        easing: held ? Easing.linear : from.easing,
      ));
    }
    // The shape holds after its last key; the set still has to fill the
    // drawable's length so the animation ends when the drawable does.
    if (clock < drawable.durationMs) {
      final last = pathData(data.keys.last.value, closures);
      steps.add((
        durationMs: drawable.durationMs - clock,
        from: last,
        to: last,
        easing: Easing.linear,
      ));
    }
    // Neighbouring steps that hold the same shape are one wait, and the shape
    // is the longest string in the file: saying it once is worth the pass.
    for (var i = steps.length - 1; i > 0; i--) {
      final step = steps[i], before = steps[i - 1];
      if (step.from != step.to || before.from != before.to || step.from != before.from) continue;
      steps[i - 1] = (
        durationMs: before.durationMs + step.durationMs,
        from: before.from,
        to: before.to,
        easing: before.easing,
      );
      steps.removeAt(i);
    }
    final out = StringBuffer(xmlHeader)
      ..writeln('<set xmlns:android="http://schemas.android.com/apk/res/android"'
          ' android:ordering="sequentially">');
    for (final step in steps) {
      out
        ..writeln('    <objectAnimator android:propertyName="pathData"'
            ' android:valueType="pathType"')
        ..writeln('        android:duration="${step.durationMs}"');
      // A step that ends where it began cannot be bent, so the interpolator
      // the platform would default to is harmless and the attribute is not
      // worth its bytes - and a held GIF frame is most of them.
      if (step.from != step.to) {
        out.writeln('        android:interpolator="${interpolator(step.easing)}"');
      }
      out
        ..writeln('        android:valueFrom="${step.from}"')
        ..writeln('        android:valueTo="${step.to}"/>');
    }
    out.writeln('</set>');
    files['animator/$target.xml'] = out.toString();
    targets.add(target);
  }

  final body = StringBuffer();
  void emitShape(PathItem shape, String indent) {
    final paint = shape.paint;
    final trims = _ordered(paint, drawable.durationMs);
    final attributes = StringBuffer('$indent<path android:name="${shape.name}"'
        '${paint.evenOdd ? ' android:fillType="evenOdd"' : ''}');
    // A gradient is written as the fill below; a flat colour here as well
    // would declare the same attribute twice, which the Android Gradle plugin
    // refuses to compile when it has to unroll the inline resource itself.
    if (paint.color != null && paint.gradient == null) {
      attributes.write(' android:fillColor="${_hex(paint.color!)}"');
    }
    if (!paint.alpha.isConstant || paint.alpha.at(0) != 1) {
      attributes.write(' android:fillAlpha="${_n(paint.alpha.at(0), 4)}"');
    }
    if (paint.strokeColor != null) {
      attributes.write(' android:strokeColor="${_hex(paint.strokeColor!)}"'
          ' android:strokeWidth="${_n(paint.strokeWidth.at(0), 4)}"');
      if (!paint.strokeAlpha.isConstant || paint.strokeAlpha.at(0) != 1) {
        attributes.write(' android:strokeAlpha="${_n(paint.strokeAlpha.at(0), 4)}"');
      }
      if (paint.cap != null) attributes.write(' android:strokeLineCap="${paint.cap}"');
      if (paint.join != null) attributes.write(' android:strokeLineJoin="${paint.join}"');
    }
    for (final trim in [
      ('trimPathStart', trims.start),
      ('trimPathEnd', trims.end),
      ('trimPathOffset', trims.offset),
    ]) {
      final value = trim.$2.at(0);
      if (!trim.$2.isConstant || (trim.$1 == 'trimPathEnd' ? value != 1 : value != 0)) {
        attributes.write(' android:${trim.$1}="${_n(value, 6)}"');
      }
    }
    attributes.write(' android:pathData="${pathData(shape.data.at(0), _closures(shape.data))}"');

    final gradient = paint.gradient;
    if (gradient == null) {
      body.writeln('$attributes/>');
    } else {
      body
        ..writeln('$attributes>')
        ..writeln('$indent    <aapt:attr name="android:fillColor">')
        ..writeln('$indent        <gradient android:type="${gradient.type}"'
            '${gradient.type == 'radial' ? ' android:centerX="${_n(gradient.start.x)}"'
                ' android:centerY="${_n(gradient.start.y)}"'
                ' android:gradientRadius="${_n(gradient.radius)}"' : ' android:startX="${_n(gradient.start.x)}"'
                ' android:startY="${_n(gradient.start.y)}"'
                ' android:endX="${_n(gradient.end.x)}"'
                ' android:endY="${_n(gradient.end.y)}"'}>');
      for (final stop in gradient.stops) {
        body.writeln('$indent            <item android:offset="${_n(stop.$1, 4)}"'
            ' android:color="${_hex(stop.$2)}"/>');
      }
      body
        ..writeln('$indent        </gradient>')
        ..writeln('$indent    </aapt:attr>')
        ..writeln('$indent</path>');
    }

    morph('${shape.name}_shape', shape.data);
    floats('${shape.name}_paint', {
      'fillAlpha': paint.alpha,
      if (paint.strokeColor != null) 'strokeAlpha': paint.strokeAlpha,
      if (paint.strokeColor != null) 'strokeWidth': paint.strokeWidth,
      'trimPathStart': trims.start,
      'trimPathEnd': trims.end,
      'trimPathOffset': trims.offset,
    });
  }

  void emitGroup(Group group, String indent) {
    final attributes = StringBuffer('$indent<group android:name="${group.name}"');
    if (group.pivot.x != 0 || group.pivot.y != 0) {
      attributes.write(' android:pivotX="${_n(group.pivot.x)}"'
          ' android:pivotY="${_n(group.pivot.y)}"');
    }
    for (final track in [
      ('translateX', group.translateX, 0.0),
      ('translateY', group.translateY, 0.0),
      ('scaleX', group.scaleX, 1.0),
      ('scaleY', group.scaleY, 1.0),
      ('rotation', group.rotation, 0.0),
    ]) {
      final value = track.$2.at(0);
      if (!track.$2.isConstant || value != track.$3) {
        attributes.write(' android:${track.$1}="${_n(value, 6)}"');
      }
    }
    body.writeln('$attributes>');
    final clip = group.clip;
    if (clip != null) {
      // No fillType here on purpose: VectorDrawableClipPath declares only name
      // and pathData, so a clip always fills by winding. The geometry is wound
      // to suit it before it gets here.
      body.writeln('$indent    <clip-path android:name="${group.name}_clip"'
          ' android:pathData="${pathData(clip.at(0), _closures(clip))}"/>');
      morph('${group.name}_clip_shape', clip);
    }
    floats('${group.name}_motion', {
      'translateX': group.translateX,
      'translateY': group.translateY,
      'scaleX': group.scaleX,
      'scaleY': group.scaleY,
      'rotation': group.rotation,
    });
    for (final child in group.groups) {
      emitGroup(child, '$indent    ');
    }
    for (final shape in group.paths) {
      emitShape(shape, '$indent    ');
    }
    body.writeln('$indent</group>');
  }

  for (final root in drawable.roots) {
    emitGroup(root, '    ');
  }

  final canvas = canvasOverride ?? drawable.canvasDp;
  final gradients = drawable.paths.any((s) => s.paint.gradient != null);
  final vector = StringBuffer(xmlHeader)
    ..writeln('<vector xmlns:android="http://schemas.android.com/apk/res/android"')
    ..writeln('    android:width="${_n(canvas)}dp"')
    ..writeln('    android:height="${_n(canvas)}dp"')
    ..writeln('    android:viewportWidth="${_n(canvas)}"')
    ..writeln('    android:viewportHeight="${_n(canvas)}"'
        '${gradients ? '\n    xmlns:aapt="http://schemas.android.com/aapt"' : ''}>')
    ..write(body)
    ..writeln('</vector>');
  files['drawable/${drawable.name}_vector.xml'] = vector.toString();

  final animated = StringBuffer(xmlHeader)
    ..writeln('<animated-vector xmlns:android="http://schemas.android.com/apk/res/android"')
    ..writeln('    android:drawable="@drawable/${drawable.name}_vector">');
  for (final target in targets) {
    final owner = target.endsWith('_clip_shape')
        ? target.replaceFirst(RegExp(r'_shape$'), '')
        : target.replaceFirst(RegExp(r'_(shape|paint|motion)$'), '');
    animated.writeln('    <target android:name="$owner"'
        ' android:animation="@animator/$target"/>');
  }
  animated.writeln('</animated-vector>');
  files['drawable/${drawable.name}.xml'] = animated.toString();
  return files;
}

/// Pads a track so it starts at zero and ends at the drawable's length.
///
/// A key outside the timeline is not simply dropped: the interval it belongs
/// to is cut where the timeline cuts it, and the easing of the part that
/// survives is the easing of that part alone.
Track<T> _span<T>(Track<T> track, int durationMs) {
  T valueAt(int timeMs) {
    if (track is Track<double>) return (track as Track<double>).at(timeMs) as T;
    if (track is Track<List<Curve>>) {
      return (track as Track<List<Curve>>).at(timeMs) as T;
    }
    throw StateError('unsupported track value');
  }

  /// The keys either side of [timeMs], and how far through them it falls.
  (Key<T>, Key<T>, double)? straddling(int timeMs) {
    for (var i = 1; i < track.keys.length; i++) {
      final a = track.keys[i - 1], b = track.keys[i];
      if (timeMs <= a.timeMs || timeMs >= b.timeMs || b.timeMs <= a.timeMs) continue;
      return (a, b, (timeMs - a.timeMs) / (b.timeMs - a.timeMs));
    }
    return null;
  }

  final keys = [
    for (final key in track.keys)
      if (key.timeMs >= 0 && key.timeMs <= durationMs) key
  ];
  if (keys.isEmpty || keys.first.timeMs > 0) {
    final cut = straddling(0);
    // The interval that zero falls inside keeps its second half; a track that
    // only starts later simply holds its first value up to where it begins.
    final easing = cut == null ? Easing.linear : cut.$1.easing.split(cut.$3).$2;
    keys.insert(0, Key(0, valueAt(0), easing));
  }
  if (keys.last.timeMs < durationMs) {
    final cut = straddling(durationMs);
    if (cut != null && keys.last.timeMs == cut.$1.timeMs) {
      final last = keys.length - 1;
      keys[last] = Key(keys[last].timeMs, keys[last].value, cut.$1.easing.split(cut.$3).$1);
    }
    keys.add(Key(durationMs, valueAt(durationMs)));
  }
  return Track(keys);
}

/// The same trim said the way `VectorDrawable` reads one.
///
/// Lottie draws the arc between the lower and the higher of start and end;
/// the platform adds the offset, wraps each end into one turn, and reads a
/// start past its end as a window across the seam - the rest of the outline.
/// Written straight through, a source that runs its start ahead of its end
/// draws the complement of what it meant. Putting the pair in order says the
/// same arc to both, and where the two cross, or a full turn has to be spelt
/// as the plain `0`..`1` the platform tests for, the pair is resampled
/// instead: the offset is folded in and the track carries the wrap itself.
({Track<double> start, Track<double> end, Track<double> offset}) _ordered(
    Paint paint, int durationMs) {
  final start = paint.trimStart, end = paint.trimEnd, offset = paint.trimOffset;
  if (start.isConstant && end.isConstant && offset.isConstant) {
    final window = _window(start.first, end.first, offset.first);
    return (
      start: Track.constant(window.$1),
      end: Track.constant(window.$2),
      offset: Track.constant(0),
    );
  }

  // Every instant either track can turn on, and a frame's worth of steps in
  // between: enough to see a crossing, and fine enough that the line drawn
  // between two samples never leaves the curve it replaces.
  final times = <int>{0, durationMs};
  for (final track in [start, end, offset]) {
    for (final key in track.keys) {
      times.add(key.timeMs.clamp(0, durationMs));
    }
  }
  for (var time = 0; time < durationMs; time += _sampleMs) {
    times.add(time);
  }
  final grid = times.toList()..sort();

  // A pair that keeps its order, either way round, is already the window the
  // platform reads: the tracks are handed over as they are, easing and all,
  // and only a crossing or a full turn costs a resample.
  var ordered = true, reversed = true, whole = false;
  for (final time in grid) {
    final low = start.at(time), high = end.at(time);
    if (high < low - 1e-9) ordered = false;
    if (low < high - 1e-9) reversed = false;
    if ((high - low).abs() >= 1 - 1e-9) whole = true;
  }
  if (!whole && ordered) return (start: start, end: end, offset: offset);
  if (!whole && reversed) return (start: end, end: start, offset: offset);

  final starts = <Key<double>>[], ends = <Key<double>>[];
  for (final time in grid) {
    final window = _window(start.at(time), end.at(time), offset.at(time));
    // A window that has wrapped past the seam puts its start above its end,
    // and the next sample brings it back: interpolating across either jump
    // would draw an arc that was never asked for, so it is held and stepped.
    _keep(starts, time, window.$1);
    _keep(ends, time, window.$2);
  }
  return (start: Track(starts), end: Track(ends), offset: Track.constant(0));
}

/// One rendered frame at 60Hz, the finest step a splash screen can show.
const _sampleMs = 16;

/// The start and end a `VectorDrawable` has to carry for Lottie's window,
/// with the offset folded in so nothing is left to wrap it twice.
(double, double) _window(double start, double end, double offset) {
  final low = math.min(start, end) + offset, high = math.max(start, end) + offset;
  final span = high - low;
  if (span >= 1 - 1e-9) return (0, 1);
  final from = low - low.floor();
  final to = from + span;
  return (from, to <= 1 ? to : to - 1);
}

void _keep(List<Key<double>> keys, int timeMs, double value) {
  if (keys.isEmpty) {
    keys.add(Key(timeMs, value));
    return;
  }
  final previous = keys.last;
  if (previous.value == value) return;
  if ((previous.value - value).abs() > 0.5 && timeMs - previous.timeMs > 1) {
    keys.add(Key(timeMs - 1, previous.value));
  }
  keys.add(Key(timeMs, value));
}

/// The same track with every instant change written as a change one
/// millisecond wide.
///
/// A step is two values at one instant, and `KeyframeSet` cannot read that: it
/// divides by the gap between the keyframes around a fraction, so two
/// keyframes sharing one fraction give it a zero to divide by and the value it
/// returns is not the step that was meant. Android holds the value it has
/// until the next keyframe, so the same step is said exactly by putting the
/// old value a millisecond before the new one - under a rendered frame at any
/// length a splash screen has, and arithmetic the platform can do.
Track<double> _stepped(Track<double> track) {
  final keys = <Key<double>>[];
  for (final key in track.keys) {
    if (keys.isEmpty) {
      keys.add(key);
      continue;
    }
    final previous = keys.removeLast();
    // A hold carries its value to the end of its interval, and two values at
    // one instant say the same thing another way.
    final steps = previous.easing.isHold || previous.timeMs >= key.timeMs;
    final edge = key.timeMs - 1;
    if (!steps) {
      keys
        ..add(previous)
        ..add(key);
    } else if (previous.timeMs >= key.timeMs) {
      final floor = keys.isEmpty ? -1 : keys.last.timeMs;
      if (edge > floor) keys.add(Key(edge, previous.value));
      keys.add(key);
    } else {
      keys.add(Key(previous.timeMs, previous.value));
      if (edge > previous.timeMs) keys.add(Key(edge, previous.value));
      keys.add(key);
    }
  }
  return Track(keys);
}

/// Path data as relative commands, each delta measured against the cursor as
/// already written so rounding cannot drift along the outline.
/// Which contours of [track] close on every keyframe.
///
/// A morph can only run between two strings with the same commands, so this
/// is decided once for the whole track: a contour that ever leaves its start
/// point is written open throughout.
List<bool> _closures(Track<List<Curve>> track) {
  final shut = [for (final curve in track.keys.first.value) _shuts(curve)];
  for (final key in track.keys.skip(1)) {
    for (var i = 0; i < shut.length && i < key.value.length; i++) {
      shut[i] = shut[i] && _shuts(key.value[i]);
    }
  }
  return shut;
}

bool _shuts(Curve curve) => (curve.last - curve[0]).length <= 1e-6;

String pathData(List<Curve> curves, [List<bool>? closures]) {
  final out = StringBuffer();
  var cx = 0.0, cy = 0.0;
  String from(Point p) => '${_n(p.x - cx)},${_n(p.y - cy)}';

  for (var index = 0; index < curves.length; index++) {
    final curve = curves[index];
    out.write('m${from(curve[0])}');
    cx += double.parse(_n(curve[0].x - cx));
    cy += double.parse(_n(curve[0].y - cy));
    final startX = cx, startY = cy;
    for (var s = 0; s < (curve.length - 1) ~/ 3; s++) {
      final end = curve[s * 3 + 3];
      out.write('c${from(curve[s * 3 + 1])} ${from(curve[s * 3 + 2])} ${from(end)}');
      cx += double.parse(_n(end.x - cx));
      cy += double.parse(_n(end.y - cy));
    }
    // Only a contour that comes back to where it started is closed. Closing
    // an open one draws a chord across it and a join at the seam, which a
    // stroke shows as a spike; a fill closes itself either way.
    if (closures == null ? _shuts(curve) : closures[index]) {
      out.write('z');
      cx = startX;
      cy = startY;
    }
  }
  return out.toString();
}

String _hex(int argb) => '#${(argb & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase()}';

/// Numbers as short as they can be without the renderer seeing the rounding.
///
/// Three decimals of a canvas unit is under a thousandth of the artwork, which
/// is finer than a device pixel at any icon size, and two is not: a stroke's
/// own width can be a unit or less, and a clip cut from one turns visibly
/// ragged when its edges land on a coarser grid.
String _n(num value, [int digits = 3]) {
  var s = value.toStringAsFixed(digits);
  if (s.contains('.')) s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  return s == '-0' || s.isEmpty ? '0' : s;
}

/// The longest string a compiled Android resource can carry.
///
/// `aapt2` writes a compiled XML's strings into a pool that stores each length
/// in fifteen bits, so a longer attribute comes back broken at runtime and the
/// whole drawable fails to inflate. The platform splash screen reports that by
/// silently showing the launcher icon instead of the animated one, which is
/// the hardest kind of bug to find - so it is prevented here instead.
const resourceStringLimit = 32767;

/// What a path is actually held to: the limit, less the room a compiler needs
/// for its own bookkeeping, so nothing lands on the edge of it.
const _budget = 32000;

/// The same drawable with every `<path>` short enough to survive compilation.
///
/// A path that would overrun [limit] is split across several `<path>`
/// elements, one per group of outlines that have to stay together: an outline
/// and the outlines nested inside it are one shape under any fill rule, so
/// they move as a unit, and separate shapes paint the same whether they share
/// a path or not. Nothing about the drawing changes.
Drawable withinStringLimit(Drawable drawable, Set<String> unsupported, {int limit = _budget}) {
  Group fit(Group group) {
    final clip = group.clip;
    if (clip != null && clip.keys.any((key) => pathData(key.value).length > limit)) {
      // A clip is one path intersected with its group; two clips intersect
      // each other, so a clip that is too long cannot be split the way a
      // painted path can.
      unsupported.add('a clip path too long for one Android resource string');
    }
    return Group(
      group.name,
      clip: clip,
      pivot: group.pivot,
      translateX: group.translateX,
      translateY: group.translateY,
      scaleX: group.scaleX,
      scaleY: group.scaleY,
      rotation: group.rotation,
      groups: [for (final child in group.groups) fit(child)],
      paths: [for (final path in group.paths) ..._split(path, limit, unsupported)],
    );
  }

  return Drawable(drawable.name, drawable.canvasDp, drawable.durationMs,
      [for (final root in drawable.roots) fit(root)],
      source: drawable.source, plate: drawable.plate);
}

List<PathItem> _split(PathItem path, int limit, Set<String> unsupported) {
  int length(Iterable<int> loops) => path.data.keys.fold(
      0,
      (worst, key) =>
          math.max(worst, pathData([for (final loop in loops) key.value[loop]]).length));
  if (length(Iterable<int>.generate(path.data.first.length)) <= limit) return [path];

  final chunks = <List<int>>[];
  for (final island in _islands(path.data.first)) {
    if (chunks.isNotEmpty && length([...chunks.last, ...island]) <= limit) {
      chunks.last.addAll(island);
      continue;
    }
    if (length(island) > limit) {
      unsupported.add('a shape too long for one Android resource string');
    }
    chunks.add([...island]);
  }
  return [
    for (var i = 0; i < chunks.length; i++)
      PathItem(
        '${path.name}_$i',
        Track([
          for (final key in path.data.keys)
            Key(key.timeMs, [for (final loop in chunks[i]) key.value[loop]], key.easing),
        ]),
        path.paint,
      ),
  ];
}

/// Outlines grouped into the shapes they describe: an outline, and every
/// outline nested inside it. A hole only reads as a hole beside the outline
/// that contains it, so the two can never be written to different paths.
List<List<int>> _islands(List<Curve> loops) {
  final polygons = [for (final loop in loops) flattenLoop(loop)];
  final owner = List<int>.filled(loops.length, -1);
  for (var i = 0; i < loops.length; i++) {
    var best = -1;
    for (var j = 0; j < loops.length; j++) {
      if (i == j || !surrounds(polygons[j], polygons[i])) continue;
      // The nearest container wins, so a hole inside a hole stays with both.
      if (best < 0 || surrounds(polygons[best], polygons[j])) best = j;
    }
    owner[i] = best;
  }
  int root(int i) {
    var at = i;
    for (var step = 0; step < loops.length && owner[at] >= 0; step++) {
      at = owner[at];
    }
    return at;
  }

  final islands = <int, List<int>>{};
  for (var i = 0; i < loops.length; i++) {
    islands.putIfAbsent(root(i), () => <int>[]).add(i);
  }
  return [
    for (final key in islands.keys.toList()..sort()) islands[key]!,
  ];
}
