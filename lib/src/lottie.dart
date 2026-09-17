import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'contour.dart';
import 'fit.dart';
import 'model.dart';
import 'trim.dart';
import 'winding.dart';

/// Reads a Lottie (Bodymovin) animation and rebuilds it as an
/// `AnimatedVectorDrawable`, structure for structure: paths stay the cubic
/// beziers their author drew, transforms stay `<group>` transforms, keyframes
/// keep their own cubic easing, and opacity, stroke width and trim become the
/// path properties Android animates natively. Nothing is traced and nothing is
/// approximated, so a supported file converts exactly.
class Lottie {
  Lottie._(this.width, this.height, this.frameRate, this.inPoint, this.outPoint, this.layers,
      this.assets, this.name);

  final double width;
  final double height;
  final double frameRate;
  final double inPoint;
  final double outPoint;
  final List<Map<String, dynamic>> layers;
  final Map<String, List<Map<String, dynamic>>> assets;
  final String name;

  int get durationMs => ((outPoint - inPoint) / frameRate * 1000).round();

  static Lottie parse(Uint8List bytes) {
    final root = json.decode(utf8.decode(bytes));
    if (root is! Map<String, dynamic>) throw const FormatException('not a Lottie animation');
    for (final required in ['w', 'h', 'fr', 'op', 'layers']) {
      if (!root.containsKey(required)) {
        throw const FormatException('not a Lottie animation: missing composition fields');
      }
    }
    final assets = <String, List<Map<String, dynamic>>>{};
    for (final asset in (root['assets'] as List? ?? const [])) {
      final map = asset as Map<String, dynamic>;
      if (map['layers'] != null) {
        assets[map['id'].toString()] = [
          for (final l in map['layers'] as List) l as Map<String, dynamic>,
        ];
      }
    }
    return Lottie._(
      (root['w'] as num).toDouble(),
      (root['h'] as num).toDouble(),
      (root['fr'] as num).toDouble(),
      ((root['ip'] as num?) ?? 0).toDouble(),
      (root['op'] as num).toDouble(),
      [for (final l in root['layers'] as List) l as Map<String, dynamic>],
      assets,
      (root['nm'] as String?) ?? 'lottie',
    );
  }

  /// Converts to the drawable model, laid out on a [canvasDp] canvas with the
  /// artwork inside [safeRadiusDp] of its centre.
  Drawable toDrawable(String name, double canvasDp, double safeRadiusDp,
      {double toleranceDp = 0.15}) {
    final unsupported = <String>{};
    final roots = <Group>[];
    var index = 0;
    // Resource names are global to the project, so everything this drawable
    // writes carries its name.
    String id(String kind) => '${name}_$kind${index++}';
    for (final group in _composition(layers, unsupported, id)) {
      roots.add(group);
    }
    if (roots.isEmpty) {
      throw StateError('nothing convertible in the Lottie file'
          '${unsupported.isEmpty ? '' : ': it uses ${unsupported.join(', ')}'}');
    }

    // Fit the artwork the same way the GIF path does: measure what the
    // animation ever covers, then place it inside the icon safe area.
    final draft = Drawable(name, canvasDp, durationMs, roots, source: 'Lottie');
    final samples = [
      for (var f = inPoint; f <= outPoint; f += 1) ((f - inPoint) / frameRate * 1000).round(),
    ];
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final t in samples) {
      for (final path in draft.at(t, fillsOnly: false)) {
        for (final loop in path.loops) {
          for (final p in loop) {
            minX = math.min(minX, p.x);
            minY = math.min(minY, p.y);
            maxX = math.max(maxX, p.x);
            maxY = math.max(maxY, p.y);
          }
        }
      }
    }
    if (!minX.isFinite) throw StateError('the Lottie file draws nothing');
    final centre = Point((minX + maxX) / 2, (minY + maxY) / 2);
    var radius = 1e-9;
    for (final t in samples) {
      for (final path in draft.at(t, fillsOnly: false)) {
        for (final loop in path.loops) {
          for (final p in loop) {
            radius = math.max(radius, (p - centre).length);
          }
        }
      }
    }
    final scale = (safeRadiusDp - 0.05) / radius;
    // Baked geometry is thinned here, where one unit of the source is a known
    // number of dp: a keyframe is worth keeping only if a person could see it.
    final thinned = [for (final group in roots) _thinGroup(group, toleranceDp / scale)];
    final placement = Group(
      '${name}_root',
      pivot: centre,
      translateX: Track.constant(canvasDp / 2 - centre.x),
      translateY: Track.constant(canvasDp / 2 - centre.y),
      scaleX: Track.constant(scale),
      scaleY: Track.constant(scale),
      groups: thinned,
    );
    _unsupported = unsupported;
    return Drawable(name, canvasDp, durationMs, [placement], source: 'Lottie');
  }

  /// Features found in the file that this converter does not reproduce.
  Set<String> get unsupported => _unsupported;
  Set<String> _unsupported = const {};

  List<Group> _composition(
      List<Map<String, dynamic>> source, Set<String> unsupported, String Function(String) id) {
    final byIndex = {for (final layer in source) layer['ind']: layer};
    final out = <Group>[];
    // Lottie draws the last layer first; Android draws in document order.
    for (var i = source.length - 1; i >= 0; i--) {
      final layer = source[i];
      if (layer['hd'] == true || layer['td'] == 1) continue; // a matte is not drawn
      if (layer['hasMask'] == true) unsupported.add('masks');
      var group = _layer(layer, byIndex, source, unsupported, id);
      if (group == null) continue;

      // A track matte draws this layer only where the layer above it is, or
      // only where it is not; a `<clip-path>` holding that shape - or the whole
      // canvas with that shape punched out of it - says exactly the same thing.
      final matteType = layer['tt'];
      if (matteType != null) {
        final matte = i > 0 ? source[i - 1] : null;
        if (matte == null || matte['td'] != 1) {
          unsupported.add('track mattes');
        } else if (matteType == 1 || matteType == 2) {
          group = Group(id('matte'),
              clip: _clip(matte, byIndex, group, inverted: matteType == 2), groups: [group]);
        } else {
          unsupported.add('luma mattes');
        }
      }
      out.add(group);
    }
    return out;
  }

  /// One layer: its shapes, under its own transform and its parents'.
  Group? _layer(Map<String, dynamic> layer, Map<Object?, Map<String, dynamic>> byIndex,
      List<Map<String, dynamic>> source, Set<String> unsupported, String Function(String) id) {
    final type = layer['ty'];
    final List<Group> children;
    if (type == 4) {
      children = _shapes(
        [for (final s in (layer['shapes'] as List? ?? const [])) s as Map<String, dynamic>],
        unsupported,
        id,
        null,
        _window(layer),
      );
    } else if (type == 0 && assets[layer['refId'].toString()] != null) {
      children = _composition(assets[layer['refId'].toString()]!, unsupported, id);
    } else {
      unsupported.add(switch (type) {
        1 => 'solid layers',
        2 => 'image layers',
        5 => 'text layers',
        _ => 'layer type $type',
      });
      return null;
    }
    if (children.isEmpty) return null;

    var group = _transform(layer['ks'] as Map<String, dynamic>?, id('layer'), children);
    // Parenting is just another transform above this one.
    var parent = layer['parent'];
    final seen = <Object?>{layer['ind']};
    while (parent != null && byIndex[parent] != null && seen.add(parent)) {
      final above = byIndex[parent]!;
      group = _transform(above['ks'] as Map<String, dynamic>?, id('parent'), [group]);
      parent = above['parent'];
    }
    return group;
  }

  /// A layer is on screen between its in and out points and nowhere else; two
  /// keyframes at the same instant make that a step rather than a fade.
  Track<double> _window(Map<String, dynamic> layer) {
    final ip = (layer['ip'] as num).toDouble(), op = (layer['op'] as num).toDouble();
    if (ip <= inPoint && op >= outPoint) return Track.constant(1);
    final keys = <Key<double>>[];
    if (ip > inPoint) {
      keys
        ..add(Key(0, 0))
        ..add(Key(_time(ip), 0))
        ..add(Key(_time(ip), 1));
    } else {
      keys.add(Key(0, 1));
    }
    if (op < outPoint) {
      keys
        ..add(Key(_time(op), 1))
        ..add(Key(_time(op), 0));
    }
    return Track(keys);
  }

  /// The clip a matte layer describes, in the space of the layer it mattes:
  /// the matte's own outline, transformed by its own transform, and for an
  /// inverted matte punched out of the whole canvas.
  Track<List<Curve>> _clip(
      Map<String, dynamic> matte, Map<Object?, Map<String, dynamic>> byIndex, Group clipped,
      {required bool inverted}) {
    final unsupported = <String>{};
    var index = 0;
    final group = _layer(matte, byIndex, const [], unsupported, (kind) => 'matte${index++}');
    final frames = [for (var f = inPoint; f <= outPoint; f += 1) _time(f)];
    final outlines = [
      for (final t in frames)
        if (group == null) const <Curve>[] else [for (final p in outlinesOfGroup(group, t)) ...p],
    ];
    // An inverted matte hides what it covers, so the clip is everything else -
    // and "everything else" only has to reach as far as the layer it clips.
    // Bounding it there instead of at some multiple of the canvas keeps the
    // numbers near the artwork, and this path is re-sent on every keyframe.
    final border = inverted ? _border(clipped, frames, outlines) : null;
    final shape = [
      for (var f = 0; f < frames.length; f++)
        [
          if (border != null) border,
          ...outlines[f],
        ],
    ];
    // A clip fills by winding, so the punch-out has to be wound, not declared.
    final winding = Winding.of(shape);
    return Track([
      for (var f = 0; f < frames.length; f++) Key(frames[f], winding.apply(shape[f])),
    ]);
  }

  /// A rectangle around everything the clip could matter to: the clipped
  /// layer and the matte itself, over the whole animation, with a margin so no
  /// edge lands on it.
  Curve _border(Group clipped, List<int> frames, List<List<Curve>> outlines) {
    var left = double.infinity, top = double.infinity;
    var right = -double.infinity, bottom = -double.infinity;
    void include(Point p) {
      if (p.x < left) left = p.x;
      if (p.x > right) right = p.x;
      if (p.y < top) top = p.y;
      if (p.y > bottom) bottom = p.y;
    }

    for (var f = 0; f < frames.length; f++) {
      for (final loop in [
        ...outlines[f],
        for (final path in outlinesOfGroup(clipped, frames[f], fillsOnly: false)) ...path,
      ]) {
        for (final p in loop) {
          include(p);
        }
      }
    }
    if (left > right) return const [];
    // Whole units, and a margin that is a third of the box: the rectangle is
    // re-sent on every keyframe, so its corners are worth keeping short, and
    // rounding outwards can only make it safer.
    final margin = math.max(right - left, bottom - top) / 3;
    final x0 = (left - margin).floorToDouble(), y0 = (top - margin).floorToDouble();
    final x1 = (right + margin).ceilToDouble(), y1 = (bottom + margin).ceilToDouble();
    final corners = [Point(x0, y0), Point(x1, y0), Point(x1, y1), Point(x0, y1)];
    // Control points on the corner they start from: a cubic whose handles sit
    // on its start point traces the straight segment exactly, and writes as
    // two zeroes instead of two interpolated thirds.
    final border = <Point>[corners[0]];
    for (var i = 0; i < 4; i++) {
      border.addAll([corners[i], corners[i], corners[(i + 1) % 4]]);
    }
    return border;
  }

  /// One Lottie shape group becomes one `<group>`; its paths become `<path>`
  /// elements painted by the fills and strokes that follow them.
  List<Group> _shapes(
      List<Map<String, dynamic>> items,
      Set<String> unsupported,
      String Function(String) id,
      Map<String, dynamic>? inheritedTrim,
      Track<double> inheritedAlpha) {
    final pathTracks = <Track<List<Curve>>>[];
    final children = <Group>[];
    Map<String, dynamic>? transform;
    final fills = <Map<String, dynamic>>[];
    final strokes = <Map<String, dynamic>>[];
    Map<String, dynamic>? trim;

    // A trim or an opacity set above this group applies to everything in it.
    Map<String, dynamic>? trimFor(List<Map<String, dynamic>> list) {
      for (final item in list) {
        if (item['ty'] == 'tm') return item;
      }
      return inheritedTrim;
    }

    final groupTrim = trimFor(items);
    final groupTransform =
        items.firstWhere((item) => item['ty'] == 'tr', orElse: () => <String, dynamic>{});
    final groupAlpha = groupTransform['o'] == null
        ? inheritedAlpha
        : _multiply(inheritedAlpha, _scalarTrack(groupTransform['o'], 0.01));

    for (final item in items.reversed) {
      switch (item['ty']) {
        case 'gr':
          children.addAll(_shapes(
              [for (final s in (item['it'] as List? ?? const [])) s as Map<String, dynamic>],
              unsupported,
              id,
              groupTrim,
              groupAlpha));
        case 'sh':
          pathTracks.add(_pathTrack(item['ks'] as Map<String, dynamic>));
        case 'rc':
          pathTracks.add(_rectTrack(item));
        case 'el':
          pathTracks.add(_ellipseTrack(item));
        case 'fl':
          fills.add(item);
        case 'gf':
          fills.add(item);
        case 'st':
        case 'gs':
          strokes.add(item);
        case 'tr':
          transform = item;
        case 'tm':
          trim = item;
          break;
        case 'sr':
          unsupported.add('star shapes');
        case 'rp':
          unsupported.add('repeaters');
        case 'mm':
          unsupported.add('merge paths');
        case 'rd':
          unsupported.add('rounded corners');
      }
    }
    final drawn = <PathItem>[];
    // In Lottie a fill or stroke paints every path in its own group, so one
    // paint and its paths become one `<path>` element with several subpaths.
    if (pathTracks.isNotEmpty && (fills.isNotEmpty || strokes.isNotEmpty)) {
      final shared = _merge(pathTracks);
      final painted = [
        for (final fill in fills) _paint(fill, false, trim ?? groupTrim, groupAlpha, unsupported),
        for (final stroke in strokes)
          _paint(stroke, true, trim ?? groupTrim, groupAlpha, unsupported),
      ];
      // Android trims only what it strokes, so a trim on a filled shape is cut
      // into the geometry instead - which is what Lottie shows.
      final baked = fills.length == 1 && _trims(painted.first);
      // A fill and a stroke over the same outline are one `<path>`: two would
      // carry the same path data, and morph it, twice. Only when the fill's
      // geometry had to be trimmed do the two stop sharing an outline.
      if (fills.length == 1 && strokes.length == 1 && !baked) {
        drawn.add(PathItem(id('path'), shared, painted.first.over(painted.last)));
      } else {
        for (var i = 0; i < painted.length; i++) {
          if (i == 0 && baked) {
            drawn.add(PathItem(
                id('path'), _bakeTrim(shared, painted.first), painted.first.withoutTrim()));
          } else {
            drawn.add(PathItem(id('path'), shared, painted[i]));
          }
        }
      }
    }
    if (drawn.isEmpty && children.isEmpty) return const [];
    return [_transform(transform, id('group'), children, drawn)];
  }

  Paint _paint(Map<String, dynamic> paint, bool stroke, Map<String, dynamic>? trim,
      Track<double> inheritedAlpha, Set<String> unsupported) {
    final gradient = paint['ty'] == 'gf' || paint['ty'] == 'gs';
    if (gradient && paint['ty'] == 'gs') unsupported.add('gradient strokes');
    // A `<group>` cannot carry opacity, so the opacity of every group above
    // this paint is folded into the paint itself.
    final alpha = _multiply(inheritedAlpha, _scalarTrack(paint['o'], 0.01));
    // Lottie keeps start and end as percentages and the offset in degrees.
    Track<double>? trimTrack(String key) =>
        trim == null ? null : _scalarTrack(trim[key], key == 'o' ? 1 / 360 : 0.01);

    return Paint(
      color: stroke ? null : (gradient ? null : _colour(paint['c'])),
      gradient: stroke || !gradient ? null : _gradient(paint),
      alpha: stroke ? null : alpha,
      strokeColor: stroke ? (gradient ? 0xFF808080 : _colour(paint['c'])) : null,
      strokeAlpha: stroke ? alpha : null,
      strokeWidth: stroke ? _scalarTrack(paint['w'], 1) : null,
      cap: stroke ? switch (paint['lc']) { 1 => 'butt', 3 => 'square', _ => 'round' } : null,
      join: stroke ? switch (paint['lj']) { 1 => 'miter', 3 => 'bevel', _ => 'round' } : null,
      trimStart: trimTrack('s'),
      trimEnd: trimTrack('e'),
      trimOffset: trimTrack('o'),
    );
  }

  Gradient _gradient(Map<String, dynamic> paint) {
    final start = _pointAt(paint['s']), end = _pointAt(paint['e']);
    final raw = ((paint['g'] as Map<String, dynamic>)['k'] as Map<String, dynamic>)['k'];
    final flat = [for (final v in _firstValue(raw)! as List) (v as num).toDouble()];
    final count = ((paint['g'] as Map<String, dynamic>)['p'] as num).toInt();

    // Colour stops first, then - if the gradient fades - alpha stops, as
    // offset and alpha pairs. Android takes one colour per stop, so the two
    // lists are sampled onto a single set of offsets.
    final colours = <double, List<double>>{};
    for (var i = 0; i < count && i * 4 + 3 < flat.length; i++) {
      colours[flat[i * 4]] = [flat[i * 4 + 1], flat[i * 4 + 2], flat[i * 4 + 3]];
    }
    final alphas = <double, double>{};
    for (var i = count * 4; i + 1 < flat.length; i += 2) {
      alphas[flat[i]] = flat[i + 1];
    }
    final offsets = <double>{...colours.keys, ...alphas.keys}.toList()..sort();

    double sample(Map<double, double> track, double at, double fallback) {
      if (track.isEmpty) return fallback;
      final keys = track.keys.toList()..sort();
      if (at <= keys.first) return track[keys.first]!;
      for (var i = 1; i < keys.length; i++) {
        if (at <= keys[i]) {
          final span = keys[i] - keys[i - 1];
          final t = span <= 0 ? 1.0 : (at - keys[i - 1]) / span;
          return track[keys[i - 1]]! + (track[keys[i]]! - track[keys[i - 1]]!) * t;
        }
      }
      return track[keys.last]!;
    }

    final stops = <(double, int)>[];
    for (final offset in offsets) {
      final rgb = [
        for (var c = 0; c < 3; c++)
          sample({for (final e in colours.entries) e.key: e.value[c]}, offset, 0),
      ];
      final alpha = sample(alphas, offset, 1);
      stops.add((
        offset,
        ((alpha * 255).round().clamp(0, 255) << 24) |
            ((rgb[0] * 255).round().clamp(0, 255) << 16) |
            ((rgb[1] * 255).round().clamp(0, 255) << 8) |
            (rgb[2] * 255).round().clamp(0, 255),
      ));
    }
    final radial = paint['t'] == 2;
    return Gradient(
        radial ? 'radial' : 'linear', start, end, stops, radial ? (end - start).length : 0);
  }

  Group _transform(Map<String, dynamic>? transform, String name, List<Group> groups,
      [List<PathItem> paths = const []]) {
    if (transform == null) {
      return Group(name, groups: groups, paths: paths);
    }
    final anchor = _pointAt(transform['a']);
    final position =
        transform['p'] is Map && (transform['p'] as Map)['s'] == true ? null : transform['p'];
    final scale = transform['s'];
    return Group(
      name,
      pivot: anchor,
      translateX: _offsetTrack(position, transform['px'], anchor.x, 0),
      translateY: _offsetTrack(position, transform['py'], anchor.y, 1),
      scaleX: _scalarTrack(scale, 0.01, 0),
      scaleY: _scalarTrack(scale, 0.01, 1),
      rotation: _scalarTrack(transform['r'] ?? transform['rz'], 1),
      groups: groups,
      paths: paths,
    );
  }

  /// A `<group>` translates by position minus anchor, which is exactly what a
  /// Lottie transform does once the anchor is used as the pivot.
  Track<double> _offsetTrack(Object? position, Object? separate, double anchor, int axis) {
    final source = position ?? separate;
    final track = _scalarTrack(source, 1, axis);
    return Track([
      for (final key in track.keys) Key(key.timeMs, key.value - anchor, key.easing),
    ]);
  }

  bool _trims(Paint paint) =>
      !paint.trimStart.isConstant ||
      !paint.trimEnd.isConstant ||
      !paint.trimOffset.isConstant ||
      paint.trimStart.first != 0 ||
      paint.trimEnd.first != 1 ||
      paint.trimOffset.first != 0;

  /// Cuts the trim into the outline, frame by frame, then keeps only the
  /// keyframes that carry it: the window moves along the path non-linearly, so
  /// the geometry has to be sampled and thinned rather than interpolated.
  Track<List<Curve>> _bakeTrim(Track<List<Curve>> data, Paint paint) {
    final frames = <int>[
      for (var f = inPoint; f <= outPoint; f += 1) _time(f),
    ];
    final baked = [
      for (final t in frames)
        Key(
          t,
          trimCurves(
              data.at(t), paint.trimStart.at(t), paint.trimEnd.at(t), paint.trimOffset.at(t)),
        ),
    ];
    return Track(baked);
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
  /// would move the outline more than a hundredth of the artwork.
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

  int _time(num frames) => ((frames.toDouble() - inPoint) / frameRate * 1000).round();

  Object? _firstValue(Object? property) {
    if (property is Map && property['k'] != null) return _firstValue(property['k']);
    if (property is List && property.isNotEmpty && property.first is Map) {
      final first = property.first as Map;
      if (first.containsKey('s')) return first['s'];
    }
    return property;
  }

  Point _pointAt(Object? property) {
    final value = _firstValue(property);
    if (value is List && value.length >= 2) {
      return Point((value[0] as num).toDouble(), (value[1] as num).toDouble());
    }
    return const Point(0, 0);
  }

  int? _colour(Object? property) {
    final value = _firstValue(property);
    if (value is! List || value.length < 3) return null;
    int channel(int i) => ((value[i] as num).toDouble() * 255).round().clamp(0, 255);
    return 0xFF000000 | (channel(0) << 16) | (channel(1) << 8) | channel(2);
  }

  /// A scalar property, scaled by [unit] (Lottie keeps percentages and degrees
  /// where Android wants fractions), taking dimension [axis] of a vector.
  Track<double> _scalarTrack(Object? property, double unit, [int axis = 0]) {
    double pick(Object? value) {
      if (value is num) return value.toDouble() * unit;
      if (value is List && value.isNotEmpty) {
        final at = axis < value.length ? value[axis] : value.first;
        return (at as num).toDouble() * unit;
      }
      return 0;
    }

    if (property == null) return Track.constant(0);
    if (property is num) return Track.constant(property.toDouble() * unit);
    final map = property is Map<String, dynamic> ? property : null;
    final raw = map == null ? property : map['k'];
    if (raw is num) return Track.constant(raw.toDouble() * unit);
    if (raw is List && raw.isNotEmpty && raw.first is! Map) return Track.constant(pick(raw));
    if (raw is! List) return Track.constant(0);

    // Two keyframe styles exist: newer files give every key its own start
    // value, older ones give a start and an end and close with a bare time.
    final keys = <Key<double>>[];
    for (var i = 0; i < raw.length; i++) {
      final frame = raw[i] as Map<String, dynamic>;
      final time = _time(frame['t'] as num);
      if (frame['s'] != null) {
        keys.add(Key(time, pick(frame['s']),
            frame['h'] == 1 ? const Easing(1, 0, 1, 0) : _easing(frame, axis)));
        continue;
      }
      final previous = i > 0 ? raw[i - 1] as Map<String, dynamic> : null;
      if (previous?['e'] != null) keys.add(Key(time, pick(previous!['e'])));
    }
    if (keys.isEmpty) return Track.constant(0);
    final last = raw.last as Map<String, dynamic>;
    if (last['s'] != null && last['e'] != null) {
      keys.add(Key(_time(last['t'] as num), pick(last['e'])));
    }
    return Track(_tidy(keys));
  }

  Track<List<Curve>> _pathTrack(Map<String, dynamic> property) {
    final raw = property['k'];
    if (raw is Map<String, dynamic>) return Track.constant([_curve(raw)]);
    if (raw is! List || raw.isEmpty) return Track.constant(const []);
    if (raw.first is! Map || !(raw.first as Map).containsKey('t')) {
      return Track.constant([_curve(raw.first as Map<String, dynamic>)]);
    }

    List<Curve> shape(Object? value) {
      final map = value is List ? value.first : value;
      return [_curve(map as Map<String, dynamic>)];
    }

    final keys = <Key<List<Curve>>>[];
    for (var i = 0; i < raw.length; i++) {
      final frame = raw[i] as Map<String, dynamic>;
      final time = _time(frame['t'] as num);
      if (frame['s'] != null) {
        keys.add(Key(time, shape(frame['s']),
            frame['h'] == 1 ? const Easing(1, 0, 1, 0) : _easing(frame, 0)));
        continue;
      }
      final previous = i > 0 ? raw[i - 1] as Map<String, dynamic> : null;
      if (previous?['e'] != null) keys.add(Key(time, shape(previous!['e'])));
    }
    if (keys.isEmpty) return Track.constant(const []);
    final last = raw.last as Map<String, dynamic>;
    if (last['s'] != null && last['e'] != null) {
      keys.add(Key(_time(last['t'] as num), shape(last['e'])));
    }
    return Track(keys);
  }

  Easing _easing(Map<String, dynamic> frame, int axis) {
    double at(Object? handle, String key, double fallback) {
      if (handle is! Map) return fallback;
      final value = handle[key];
      if (value is num) return value.toDouble();
      if (value is List && value.isNotEmpty) {
        return ((axis < value.length ? value[axis] : value.first) as num).toDouble();
      }
      return fallback;
    }

    final out = frame['o'], into = frame['i'];
    return Easing(at(out, 'x', 0), at(out, 'y', 0), at(into, 'x', 1), at(into, 'y', 1));
  }

  /// One cubic outline from Lottie's vertex, in-tangent and out-tangent lists.
  Curve _curve(Map<String, dynamic> shape) {
    final v = shape['v'] as List, i = shape['i'] as List, o = shape['o'] as List;
    final closed = shape['c'] == true;
    Point at(List<dynamic> list, int index) {
      final pair = list[index] as List;
      return Point((pair[0] as num).toDouble(), (pair[1] as num).toDouble());
    }

    final out = <Point>[at(v, 0)];
    final count = closed ? v.length : v.length - 1;
    for (var k = 0; k < count; k++) {
      final from = at(v, k), to = at(v, (k + 1) % v.length);
      out.addAll([from + at(o, k), to + at(i, (k + 1) % v.length), to]);
    }
    return out;
  }

  Track<List<Curve>> _rectTrack(Map<String, dynamic> item) {
    final size = _pointAt(item['s']), centre = _pointAt(item['p']);
    final rx = size.x / 2, ry = size.y / 2;
    final corner = math.min(((_firstValue(item['r']) as num?) ?? 0).toDouble(), math.min(rx, ry));
    final k = corner * 0.5523;
    final left = centre.x - rx, right = centre.x + rx;
    final top = centre.y - ry, bottom = centre.y + ry;
    final curve = <Point>[Point(left + corner, top)];
    void line(Point to) => curve.addAll([
          curve.last + (to - curve.last) * (1 / 3),
          curve.last + (to - curve.last) * (2 / 3),
          to,
        ]);
    void arc(Point control1, Point control2, Point to) => curve.addAll([control1, control2, to]);
    line(Point(right - corner, top));
    arc(Point(right - corner + k, top), Point(right, top + corner - k), Point(right, top + corner));
    line(Point(right, bottom - corner));
    arc(Point(right, bottom - corner + k), Point(right - corner + k, bottom),
        Point(right - corner, bottom));
    line(Point(left + corner, bottom));
    arc(Point(left + corner - k, bottom), Point(left, bottom - corner + k),
        Point(left, bottom - corner));
    line(Point(left, top + corner));
    arc(Point(left, top + corner - k), Point(left + corner - k, top), Point(left + corner, top));
    return Track.constant([curve]);
  }

  Track<List<Curve>> _ellipseTrack(Map<String, dynamic> item) {
    final size = _pointAt(item['s']), centre = _pointAt(item['p']);
    final rx = size.x / 2, ry = size.y / 2, k = 0.5523;
    return Track.constant([
      [
        Point(centre.x, centre.y - ry),
        Point(centre.x + rx * k, centre.y - ry),
        Point(centre.x + rx, centre.y - ry * k),
        Point(centre.x + rx, centre.y),
        Point(centre.x + rx, centre.y + ry * k),
        Point(centre.x + rx * k, centre.y + ry),
        Point(centre.x, centre.y + ry),
        Point(centre.x - rx * k, centre.y + ry),
        Point(centre.x - rx, centre.y + ry * k),
        Point(centre.x - rx, centre.y),
        Point(centre.x - rx, centre.y - ry * k),
        Point(centre.x - rx * k, centre.y - ry),
        Point(centre.x, centre.y - ry),
      ],
    ]);
  }

  /// Several paths under one paint become one `<path>` of several subpaths.
  Track<List<Curve>> _merge(List<Track<List<Curve>>> tracks) {
    if (tracks.length == 1) return tracks.single;
    final times = <int>{for (final track in tracks) ...track.keys.map((k) => k.timeMs)}.toList()
      ..sort();
    return Track([
      for (final t in times)
        Key(
            t,
            [
              for (final track in tracks) ...track.at(t),
            ],
            _easingAt(tracks, t)),
    ]);
  }

  Easing _easingAt(List<Track<List<Curve>>> tracks, int timeMs) {
    for (final track in tracks) {
      for (final key in track.keys) {
        if (key.timeMs == timeMs && !key.easing.isLinear) return key.easing;
      }
    }
    return Easing.linear;
  }

  /// The product of two opacity tracks, keyed wherever either one turns: a
  /// `<group>` cannot carry opacity, so a group's is folded into its paints.
  Track<double> _multiply(Track<double> a, Track<double> b) {
    if (a.isConstant && b.isConstant) return Track.constant(a.first * b.first);
    if (a.isConstant && a.first == 1) return b;
    if (b.isConstant && b.first == 1) return a;
    final times = <int>{...a.keys.map((k) => k.timeMs), ...b.keys.map((k) => k.timeMs)}.toList()
      ..sort();
    return Track([
      for (final t in times)
        Key(t, a.at(t) * b.at(t), _turnAt(a, t) ?? _turnAt(b, t) ?? Easing.linear),
    ]);
  }

  Easing? _turnAt(Track<double> track, int timeMs) {
    for (final key in track.keys) {
      if (key.timeMs == timeMs && !key.easing.isLinear) return key.easing;
    }
    return null;
  }

  /// Drops keys that repeat the value before them, and sorts by time.
  List<Key<double>> _tidy(List<Key<double>> keys) {
    keys.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    final out = <Key<double>>[keys.first];
    for (final key in keys.skip(1)) {
      final last = out.last;
      if (key.timeMs == last.timeMs && key.value == last.value) continue;
      out.add(key);
    }
    return out;
  }
}

/// The outlines of one group at [timeMs], in the space above it: how a matte
/// layer becomes a clip path. A stroke over the same outline is skipped, or the
/// two copies would cancel each other under the even-odd rule.
List<List<Curve>> outlinesOfGroup(Group group, int timeMs, {bool fillsOnly = true}) {
  final out = <List<Curve>>[];
  void walk(Group node, Matrix parent) {
    final local = compose(parent, node.matrixAt(timeMs));
    final filled = fillsOnly ? node.paths.where((path) => path.paint.hasFill) : node.paths;
    for (final path in filled.isEmpty ? node.paths.take(1) : filled) {
      out.add([
        for (final curve in path.data.at(timeMs)) [for (final p in curve) transform(local, p)],
      ]);
    }
    for (final child in node.groups) {
      walk(child, local);
    }
  }

  walk(group, identity);
  return out;
}
