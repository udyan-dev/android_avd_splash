import 'contour.dart';
import 'fit.dart';
import 'model.dart';
import 'stamp.dart';

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
    tracks.updateAll((_, track) => _span(track, drawable.durationMs));
    final out = StringBuffer(xmlHeader)
      ..writeln('<objectAnimator xmlns:android="http://schemas.android.com/apk/res/android"')
      ..writeln('    android:duration="${drawable.durationMs}">');
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
            ' android:interpolator="${interpolator(lead)}"/>');
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
    final out = StringBuffer(xmlHeader)
      ..writeln('<set xmlns:android="http://schemas.android.com/apk/res/android"'
          ' android:ordering="sequentially">');
    var clock = 0;
    for (var i = 0; i < data.keys.length - 1; i++) {
      final from = data.keys[i], to = data.keys[i + 1];
      clock += to.timeMs - from.timeMs;
      out
        ..writeln('    <objectAnimator android:propertyName="pathData"'
            ' android:valueType="pathType"')
        ..writeln('        android:duration="${to.timeMs - from.timeMs}"')
        ..writeln('        android:interpolator="${interpolator(from.easing)}"')
        ..writeln('        android:valueFrom="${pathData(from.value)}"')
        ..writeln('        android:valueTo="${pathData(to.value)}"/>');
    }
    // The shape holds after its last key; the set still has to fill the
    // drawable's length so the animation ends when the drawable does.
    if (clock < drawable.durationMs) {
      final last = pathData(data.keys.last.value);
      out
        ..writeln('    <objectAnimator android:propertyName="pathData"'
            ' android:valueType="pathType"')
        ..writeln('        android:duration="${drawable.durationMs - clock}"')
        ..writeln('        android:valueFrom="$last" android:valueTo="$last"/>');
    }
    out.writeln('</set>');
    files['animator/$target.xml'] = out.toString();
    targets.add(target);
  }

  final body = StringBuffer();
  void emitShape(PathItem shape, String indent) {
    final paint = shape.paint;
    final attributes = StringBuffer('$indent<path android:name="${shape.name}"'
        ' android:fillType="evenOdd"');
    if (paint.color != null) attributes.write(' android:fillColor="${_hex(paint.color!)}"');
    if (paint.alpha.isConstant && paint.alpha.first != 1) {
      attributes.write(' android:fillAlpha="${_n(paint.alpha.first, 4)}"');
    } else if (!paint.alpha.isConstant) {
      attributes.write(' android:fillAlpha="${_n(paint.alpha.first, 4)}"');
    }
    if (paint.strokeColor != null) {
      attributes.write(' android:strokeColor="${_hex(paint.strokeColor!)}"'
          ' android:strokeWidth="${_n(paint.strokeWidth.first, 4)}"');
      if (!paint.strokeAlpha.isConstant || paint.strokeAlpha.first != 1) {
        attributes.write(' android:strokeAlpha="${_n(paint.strokeAlpha.first, 4)}"');
      }
      if (paint.cap != null) attributes.write(' android:strokeLineCap="${paint.cap}"');
      if (paint.join != null) attributes.write(' android:strokeLineJoin="${paint.join}"');
    }
    for (final trim in [
      ('trimPathStart', paint.trimStart),
      ('trimPathEnd', paint.trimEnd),
      ('trimPathOffset', paint.trimOffset),
    ]) {
      final constant = trim.$2.isConstant, value = trim.$2.first;
      if (!constant || (trim.$1 == 'trimPathEnd' ? value != 1 : value != 0)) {
        attributes.write(' android:${trim.$1}="${_n(value, 6)}"');
      }
    }
    attributes.write(' android:pathData="${pathData(shape.data.first)}"');

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
      'trimPathStart': paint.trimStart,
      'trimPathEnd': paint.trimEnd,
      'trimPathOffset': paint.trimOffset,
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
      if (!track.$2.isConstant || track.$2.first != track.$3) {
        attributes.write(' android:${track.$1}="${_n(track.$2.first, 6)}"');
      }
    }
    body.writeln('$attributes>');
    final clip = group.clip;
    if (clip != null) {
      // No fillType here on purpose: VectorDrawableClipPath declares only name
      // and pathData, so a clip always fills by winding. The geometry is wound
      // to suit it before it gets here.
      body.writeln('$indent    <clip-path android:name="${group.name}_clip"'
          ' android:pathData="${pathData(clip.first)}"/>');
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
Track<T> _span<T>(Track<T> track, int durationMs) {
  final keys = [...track.keys];
  if (keys.first.timeMs > 0) {
    keys.insert(0, Key(0, keys.first.value, keys.first.easing));
  }
  if (keys.last.timeMs < durationMs) {
    keys.add(Key(durationMs, keys.last.value));
  }
  return Track(keys);
}

/// Path data as relative commands, each delta measured against the cursor as
/// already written so rounding cannot drift along the outline.
String pathData(List<Curve> curves) {
  final out = StringBuffer();
  var cx = 0.0, cy = 0.0;
  String from(Point p) => '${_n(p.x - cx)},${_n(p.y - cy)}';

  for (final curve in curves) {
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
    out.write('z');
    cx = startX;
    cy = startY;
  }
  return out.toString();
}

String _hex(int argb) => '#${(argb & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase()}';

String _n(num value, [int digits = 2]) {
  var s = value.toStringAsFixed(digits);
  if (s.contains('.')) s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  return s == '-0' || s.isEmpty ? '0' : s;
}
