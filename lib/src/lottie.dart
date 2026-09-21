import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'contour.dart';
import 'fit.dart';
import 'model.dart';
import 'place.dart';
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
      {double toleranceDp = 0.15, bool trim = true}) {
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

    _unsupported = unsupported;
    return place(
      name: name,
      source: 'Lottie',
      roots: roots,
      width: width,
      height: height,
      durationMs: durationMs,
      samples: [
        for (var f = inPoint; f <= outPoint; f += 1) ((f - inPoint) / frameRate * 1000).round(),
      ],
      canvasDp: canvasDp,
      safeRadiusDp: safeRadiusDp,
      toleranceDp: toleranceDp,
      trim: trim,
    );
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
      var group = _layer(layer, byIndex, source, unsupported, id);
      if (group == null) continue;

      // Added masks form one union that clips the layer; subtracted masks form
      // another union punched out of it. Nesting the two clips expresses the
      // intersection exactly without flattening either operation.
      final masks = _masks(layer, byIndex, unsupported, id);
      if (masks.added.parts.isNotEmpty) {
        group = Group(
          id('mask'),
          clip: _clip(masks.added, group, inverted: false),
          groups: [group],
        );
      }
      if (masks.subtracted.parts.isNotEmpty) {
        group = Group(
          id('mask'),
          clip: _clip(masks.subtracted, group, inverted: true),
          groups: [group],
        );
      }

      // A track matte draws this layer only where the layer above it is, or
      // only where it is not; a `<clip-path>` holding that shape - or the whole
      // canvas with that shape punched out of it - says exactly the same thing.
      final matteType = layer['tt'];
      if (matteType != null) {
        final matte = i > 0 ? source[i - 1] : null;
        if (matte == null || matte['td'] != 1) {
          unsupported.add('track mattes');
        } else if (matteType == 1 || matteType == 2) {
          final region = _matteOf(matte, byIndex, source, unsupported, id);
          group = Group(id('matte'),
              clip: _clip(region, group, inverted: matteType == 2), groups: [group]);
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
    late List<Group> children;
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
      final stretch = ((layer['sr'] as num?) ?? 1).toDouble();
      final start = ((layer['st'] as num?) ?? 0).toDouble();
      final shiftMs = ((start + inPoint * (stretch - 1)) / frameRate * 1000).round();
      children = [for (final child in children) child.mapped(stretch, shiftMs)];
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
    if (type == 0) {
      final window = _window(layer);
      if (!window.isConstant) {
        group = Group(id('window'), scaleX: window, scaleY: window, groups: [group]);
      }
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

  /// What a matte layer covers, as a plan that can be evaluated at any time.
  ///
  /// A matte is not always one shape. It can be a whole precomposition, whose
  /// layers appear and vanish and can carry mattes of their own, and a
  /// `<clip-path>` is one path filled by winding. So the plan records what each
  /// part *adds* and what a matte of its own *removes*, and the clip is written
  /// by winding those parts against each other: adding turns one way, removing
  /// turns the other, and non-zero winding cancels them exactly where Lottie
  /// would have cut the pixels away.
  _Matte _matteOf(Map<String, dynamic> layer, Map<Object?, Map<String, dynamic>> byIndex,
      List<Map<String, dynamic>> siblings, Set<String> unsupported, String Function(String) id) {
    final nested = layer['refId'] == null ? null : assets[layer['refId'].toString()];
    if (layer['ty'] == 0 && nested != null) {
      final parts = <_MattePart>[];
      final inner = {for (final l in nested) l['ind']: l};
      // The precomposition's own transform sits above everything inside it.
      final stack = _transformStack(layer, byIndex, unsupported, id);
      for (var i = nested.length - 1; i >= 0; i--) {
        final child = nested[i];
        if (child['hd'] == true || child['td'] == 1) continue;
        final matteType = child['tt'];
        final matte = matteType == null || i == 0 ? null : nested[i - 1];
        if (matteType == 1) unsupported.add('a matte inside a matte');
        parts.add(_MatteNest(
          stack,
          _window(layer),
          _matteOf(child, inner, nested, unsupported, id),
          matteType == 2 && matte != null && matte['td'] == 1
              ? _matteOf(matte, inner, nested, unsupported, id)
              : null,
        ));
      }
      return _Matte(parts);
    }
    final group = _layer(layer, byIndex, siblings, unsupported, id);
    if (group == null) return const _Matte([]);
    // What paints is what mattes: a fill covers its interior and a stroke
    // covers a band around it. A path that does neither still has an outline,
    // which is the nearest thing to coverage it has.
    final leaves = <_MatteLeaf>[];
    void walk(Group node, List<Group> stack) {
      final here = [...stack, node];
      final painting = node.paths.where((path) => path.paint.hasFill || path.paint.hasStroke);
      for (final path in painting.isEmpty ? node.paths.take(1) : painting) {
        leaves.add(_MatteLeaf(here, path));
      }
      for (final child in node.groups) {
        walk(child, here);
      }
    }

    walk(group, const []);
    // A mask narrows the layer, and here the layer is itself being taken out
    // of something else. Subtracting a region that reaches outside what it is
    // subtracted from needs an intersection, and one wound path cannot say
    // intersection, so this is reported rather than approximated.
    if (layer['masksProperties'] is List && (layer['masksProperties'] as List).isNotEmpty) {
      unsupported.add('a mask on a matte');
    }
    return _Matte(leaves);
  }

  /// The regions a layer's masks keep or remove, in the layer's own space.
  ///
  /// A mask lives above the shapes and below the layer transform, so it takes
  /// the layer's transform stack and none of the groups inside it. Only the
  /// Added masks and subtracted masks are each unions. Applying the added union
  /// as one clip and the subtracted union as a nested inverse clip reproduces
  /// their intersection with the layer.
  ({_Matte added, _Matte subtracted}) _masks(
      Map<String, dynamic> layer,
      Map<Object?, Map<String, dynamic>> byIndex,
      Set<String> unsupported,
      String Function(String) id) {
    final masks = layer['masksProperties'];
    if (masks is! List || masks.isEmpty) {
      return (added: const _Matte([]), subtracted: const _Matte([]));
    }
    final added = <_MattePart>[];
    final subtracted = <_MattePart>[];
    var stack = const <Group>[];
    final window = _window(layer);
    for (final entry in masks) {
      final mask = entry as Map<String, dynamic>;
      final mode = mask['mode'];
      final inverted = mask['inv'] == true;
      // 'a' adds the mask to what is shown, 's' subtracts it; inverting one
      // turns it into the other. 'n' is a mask that is switched off.
      if (mode == 'n') continue;
      if (mode != 'a' && mode != 's') {
        unsupported.add('masks');
        continue;
      }
      final path = mask['pt'];
      if (path is! Map<String, dynamic>) continue;
      if ((mask['x'] as Map?)?['k'] is num && ((mask['x'] as Map)['k'] as num) != 0) {
        unsupported.add('mask expansion');
      }
      if (stack.isEmpty) stack = _transformStack(layer, byIndex, unsupported, id);
      final part = _MatteLeaf(
        stack,
        PathItem(
          id('mask'),
          _pathTrack(path),
          Paint(
            color: 0xFF000000,
            alpha: multiplyTracks(window, _scalarTrack(mask['o'], 0.01)),
          ),
        ),
      );
      final subtracts = (mode == 'a' && inverted) || (mode == 's' && !inverted);
      (subtracts ? subtracted : added).add(part);
    }
    return (added: _Matte(added), subtracted: _Matte(subtracted));
  }

  /// The transform above a layer: its own, then every parent's.
  List<Group> _transformStack(
      Map<String, dynamic> layer,
      Map<Object?, Map<String, dynamic>> byIndex,
      Set<String> unsupported,
      String Function(String) id) {
    final stack = <Group>[_transform(layer['ks'] as Map<String, dynamic>?, id('matte'), const [])];
    var parent = layer['parent'];
    final seen = <Object?>{layer['ind']};
    while (parent != null && byIndex[parent] != null && seen.add(parent)) {
      final above = byIndex[parent]!;
      stack.insert(0, _transform(above['ks'] as Map<String, dynamic>?, id('matte'), const []));
      parent = above['parent'];
    }
    return stack;
  }

  /// The clip a matte describes, in the space of the layer it mattes.
  ///
  /// The loops are wound, not declared: `VectorDrawableClipPath` has no
  /// `fillType`, so a clip always fills by winding, and a hole only exists
  /// where the geometry turns against the shape around it. An inverted matte
  /// is the layer's own area with the matte punched out, so it adds a box and
  /// removes everything the matte covers.
  Track<List<Curve>> _clip(_Matte region, Group clipped, {required bool inverted}) {
    final frames = [for (var f = inPoint; f <= outPoint; f += 1) _time(f)];
    final parts = [for (final t in frames) region.at(t)];
    // Winding is decided once per part, from every frame, because reversing a
    // loop reverses its path commands: a frame free to disagree would run one
    // loop backwards in the middle of a morph.
    final count = parts.isEmpty ? 0 : parts.first.length;
    final flip = List<bool>.filled(count, false);
    for (var i = 0; i < count; i++) {
      var votes = 0;
      for (final frame in parts) {
        if (frame.length != count) continue;
        final part = frame[i];
        final area = _outerArea(part.loops);
        if (area == 0) continue;
        final wanted = (inverted ? -part.sign : part.sign) > 0 ? 1 : -1;
        votes += area * wanted < 0 ? 1 : -1;
      }
      flip[i] = votes > 0;
    }
    final outlines = [
      for (final frame in parts)
        [
          for (var i = 0; i < frame.length; i++)
            ...(i < flip.length && flip[i]
                ? [for (final loop in frame[i].loops) reverseLoop(loop)]
                : frame[i].loops),
        ],
    ];
    final border = inverted ? _border(clipped, frames, outlines) : null;
    final shape = [
      for (var f = 0; f < frames.length; f++)
        [
          if (border != null && border.isNotEmpty) border,
          ...outlines[f],
        ],
    ];
    return Track([
      for (var f = 0; f < frames.length; f++) Key(frames[f], shape[f]),
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
        : multiplyTracks(inheritedAlpha, _scalarTrack(groupTransform['o'], 0.01));

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
    final alpha = multiplyTracks(inheritedAlpha, _scalarTrack(paint['o'], 0.01));
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
    final motion = _motion(position);
    final track = motion != null
        ? Track([
            for (final key in motion)
              Key(key.timeMs, axis == 0 ? key.value.x : key.value.y, key.easing),
          ])
        : _scalarTrack(position ?? separate, 1, axis);
    return Track([
      for (final key in track.keys) Key(key.timeMs, key.value - anchor, key.easing),
    ]);
  }

  /// Position keyframes with their spatial bezier sampled into plain keys, or
  /// null when the position travels straight and needs none of this.
  ///
  /// `to` and `ti` are tangent handles on the path the position travels along,
  /// and Lottie reads the value at *arc length* down that curve rather than
  /// between the keyframes. Android animates `translateX` and `translateY`
  /// separately and in a straight line, so the only way to keep the motion is
  /// to walk the curve here: one key per source frame, thinned to what a person
  /// could see. Ignoring the handles is what makes a fly-in drift off its arc
  /// and its matte slide out from under it.
  List<Key<Point>>? _motion(Object? property) {
    if (property is! Map) return null;
    if (property['s'] == true) return null; // x and y are separate properties
    final cached = _motions[property];
    if (cached != null) return cached.isEmpty ? null : cached;
    final raw = property['k'];
    final frames = raw is List && raw.isNotEmpty && raw.first is Map
        ? [for (final frame in raw) frame as Map<String, dynamic>]
        : const <Map<String, dynamic>>[];
    final keys = frames.any(_curved) ? _sampleMotion(frames) : const <Key<Point>>[];
    _motions[property] = keys;
    return keys.isEmpty ? null : keys;
  }

  final _motions = <Object, List<Key<Point>>>{};

  /// Whether a position keyframe bends the path it leaves on.
  bool _curved(Map<String, dynamic> frame) {
    final to = _vector(frame['to']), ti = _vector(frame['ti']);
    return (to != null && to.length > 0.01) || (ti != null && ti.length > 0.01);
  }

  List<Key<Point>> _sampleMotion(List<Map<String, dynamic>> frames) {
    final keys = <Key<Point>>[];
    for (var i = 0; i < frames.length; i++) {
      final frame = frames[i];
      final start = _vector(frame['s']);
      if (start == null) continue;
      final time = _time(frame['t'] as num);
      final next = i + 1 < frames.length ? frames[i + 1] : null;
      final end = _vector(frame['e']) ?? (next == null ? null : _vector(next['s']));
      if (next == null || end == null) {
        keys.add(Key(time, start));
        break;
      }
      final until = _time(next['t'] as num);
      final to = _vector(frame['to']), ti = _vector(frame['ti']);
      if (frame['h'] == 1 || to == null || ti == null || !_curved(frame)) {
        keys.add(Key(time, start, frame['h'] == 1 ? const Easing(1, 0, 1, 0) : _easing(frame, 0)));
        continue;
      }
      // Four samples per source frame: a frame is not fine enough, because the
      // easing bends inside one and a fast fly-in can cross a shape's own width
      // in that time. The thinning below takes back every sample a straight
      // line already covers, so a gentle arc still costs two keys.
      final steps = math.max(2, (((next['t'] as num) - (frame['t'] as num)) * 4).round());
      final arc = _Arc([start, start + to, end + ti, end]);
      final easing = _easing(frame, 0);
      final walked = [
        for (var step = 0; step <= steps; step++)
          Key(time + ((until - time) * step / steps).round(), arc.at(easing(step / steps))),
      ];
      keys.addAll(_thinPoints(walked, _motionTolerance));
    }
    return _tidy(keys);
  }

  /// How far a sample may move the artwork before it has to be kept, in
  /// composition units.
  ///
  /// The artwork ends up fitted to roughly twice the safe radius across, so a
  /// unit is about `192 / max(width, height)` dp: this is a quarter of a dp,
  /// which no phone can show, whatever the source was drawn at.
  double get _motionTolerance => math.max(width, height) / 768;

  /// Douglas-Peucker on a walked motion path: a sample survives only where
  /// dropping it would move the artwork further than [tolerance].
  List<Key<Point>> _thinPoints(List<Key<Point>> keys, double tolerance) {
    if (keys.length < 3) return keys.sublist(0, keys.length - 1);
    final keep = List<bool>.filled(keys.length, false);
    keep[0] = keep[keys.length - 1] = true;
    void split(int a, int b) {
      if (b - a < 2) return;
      var worst = -1;
      var error = tolerance;
      for (var i = a + 1; i < b; i++) {
        final span = keys[b].timeMs - keys[a].timeMs;
        final t = span == 0 ? 0.0 : (keys[i].timeMs - keys[a].timeMs) / span;
        final guess = keys[a].value + (keys[b].value - keys[a].value) * t;
        final d = (keys[i].value - guess).length;
        if (d > error) {
          error = d;
          worst = i;
        }
      }
      if (worst < 0) return;
      keep[worst] = true;
      split(a, worst);
      split(worst, b);
    }

    split(0, keys.length - 1);
    // The last sample is the next keyframe's own start, so the next span
    // writes it; writing it here would double it.
    return [
      for (var i = 0; i < keys.length - 1; i++)
        if (keep[i]) keys[i],
    ];
  }

  Point? _vector(Object? value) {
    final raw = value is List ? value : null;
    if (raw == null || raw.length < 2 || raw.first is! num) return null;
    return Point((raw[0] as num).toDouble(), (raw[1] as num).toDouble());
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

  /// A rectangle, as Lottie draws one: from the top right, down the right
  /// side, and round clockwise.
  ///
  /// The start point and the direction are not cosmetic - a trim measures from
  /// the start - and the size, the centre and the corner radius can all
  /// animate, so this is a track and not one shape. Every frame keeps the same
  /// eight cubics, so the result can still morph: a square corner is a cubic
  /// whose handles sit on the corner it turns.
  Track<List<Curve>> _rectTrack(Map<String, dynamic> item) {
    final width = _scalarTrack(item['s'], 1, 0), height = _scalarTrack(item['s'], 1, 1);
    final x = _scalarTrack(item['p'], 1, 0), y = _scalarTrack(item['p'], 1, 1);
    final round = _scalarTrack(item['r'] ?? 0, 1);
    return _shapeTrack([width, height, x, y, round], (time) {
      final halfWidth = width.at(time) / 2, halfHeight = height.at(time) / 2;
      final centre = Point(x.at(time), y.at(time));
      final corner = round.at(time).clamp(0.0, math.min(halfWidth, halfHeight));
      final k = corner * (1 - _kappa);
      final left = centre.x - halfWidth, right = centre.x + halfWidth;
      final top = centre.y - halfHeight, bottom = centre.y + halfHeight;
      final curve = <Point>[Point(right, top + corner)];
      void line(Point to) => curve.addAll([
            curve.last + (to - curve.last) * (1 / 3),
            curve.last + (to - curve.last) * (2 / 3),
            to,
          ]);
      void arc(Point handle1, Point handle2, Point to) => curve.addAll([handle1, handle2, to]);
      line(Point(right, bottom - corner));
      arc(Point(right, bottom - k), Point(right - k, bottom), Point(right - corner, bottom));
      line(Point(left + corner, bottom));
      arc(Point(left + k, bottom), Point(left, bottom - k), Point(left, bottom - corner));
      line(Point(left, top + corner));
      arc(Point(left, top + k), Point(left + k, top), Point(left + corner, top));
      line(Point(right - corner, top));
      arc(Point(right - k, top), Point(right, top + k), Point(right, top + corner));
      return [curve];
    });
  }

  /// An ellipse, as Lottie draws one: from the top, clockwise, or the other way
  /// round when the shape says it is reversed.
  Track<List<Curve>> _ellipseTrack(Map<String, dynamic> item) {
    final width = _scalarTrack(item['s'], 1, 0), height = _scalarTrack(item['s'], 1, 1);
    final x = _scalarTrack(item['p'], 1, 0), y = _scalarTrack(item['p'], 1, 1);
    final reversed = item['d'] == 3;
    return _shapeTrack([width, height, x, y], (time) {
      final rx = width.at(time) / 2, ry = height.at(time) / 2;
      final centre = Point(x.at(time), y.at(time));
      final hx = rx * _kappa * (reversed ? -1 : 1);
      final side = reversed ? -rx : rx;
      final hy = ry * _kappa;
      return [
        [
          Point(centre.x, centre.y - ry),
          Point(centre.x + hx, centre.y - ry),
          Point(centre.x + side, centre.y - hy),
          Point(centre.x + side, centre.y),
          Point(centre.x + side, centre.y + hy),
          Point(centre.x + hx, centre.y + ry),
          Point(centre.x, centre.y + ry),
          Point(centre.x - hx, centre.y + ry),
          Point(centre.x - side, centre.y + hy),
          Point(centre.x - side, centre.y),
          Point(centre.x - side, centre.y - hy),
          Point(centre.x - hx, centre.y - ry),
          Point(centre.x, centre.y - ry),
        ],
      ];
    });
  }

  /// A primitive shape sampled wherever any of the properties that build it
  /// has a key, keeping that key's own easing.
  Track<List<Curve>> _shapeTrack(
      List<Track<double>> properties, List<Curve> Function(int timeMs) build) {
    if (properties.every((track) => track.isConstant)) return Track.constant(build(0));
    final times = <int>{
      for (final track in properties) ...track.keys.map((key) => key.timeMs),
    }.toList()
      ..sort();
    return Track([
      for (final time in times) Key(time, build(time), _turn(properties, time)),
    ]);
  }

  /// The easing whichever property turns with at [timeMs].
  Easing _turn(List<Track<double>> properties, int timeMs) {
    for (final track in properties) {
      final easing = turnAt(track, timeMs);
      if (easing != null) return easing;
    }
    return Easing.linear;
  }

  /// The handle length that turns a quarter circle into a cubic, as Lottie
  /// itself writes it: matching the renderer matters more here than the last
  /// digit of the ideal value, because a trim measures along this curve.
  static const _kappa = 0.55228;

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

  /// Drops keys that repeat the value before them, and sorts by time.
  List<Key<T>> _tidy<T>(List<Key<T>> keys) {
    keys.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    final out = <Key<T>>[keys.first];
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

/// Loops of one part of a matte, and whether the part adds to what the matte
/// covers or takes away from it.
typedef _Signed = ({List<Curve> loops, int sign});

/// What a matte covers, as parts that can be evaluated at any instant.
class _Matte {
  const _Matte(this.parts);

  final List<_MattePart> parts;

  List<_Signed> at(int timeMs) {
    final out = <_Signed>[];
    for (final part in parts) {
      part.emit(timeMs, identity, 1, out, live: true);
    }
    return out;
  }
}

abstract class _MattePart {
  void emit(int timeMs, Matrix parent, int sign, List<_Signed> out, {required bool live});
}

/// One path of a matte layer.
///
/// A part that is off screen is emitted collapsed to a point rather than
/// dropped: a clip is morphed from keyframe to keyframe, and Android can only
/// morph path data whose commands match, so the loop has to stay in the path
/// and cover nothing.
class _MatteLeaf implements _MattePart {
  _MatteLeaf(this.stack, this.path);

  final List<Group> stack;
  final PathItem path;

  @override
  void emit(int timeMs, Matrix parent, int sign, List<_Signed> out, {required bool live}) {
    var local = parent;
    for (final group in stack) {
      local = compose(local, group.matrixAt(timeMs));
    }
    final paint = path.paint;
    final fills = live && paint.hasFill && paint.alpha.at(timeMs) >= 0.5;
    final strokes = live && paint.hasStroke && paint.strokeAlpha.at(timeMs) >= 0.5;
    final data = path.data.at(timeMs);
    final start = paint.trimStart.at(timeMs), end = paint.trimEnd.at(timeMs);
    final stroked = paint.hasStroke
        ? trimCurves(data, start, end, paint.trimOffset.at(timeMs))
        : const <Curve>[];
    final loops = <(Curve, bool)>[
      if (paint.hasFill)
        for (final curve in data)
          (
            paint.hasStroke ? outsetLoop(curve, paint.strokeWidth.at(timeMs) / 2) : curve,
            fills || strokes,
          ),
      if (paint.hasStroke && !paint.hasFill)
        for (final curve in stroked) (_strokeBand(curve, paint.strokeWidth.at(timeMs)), strokes),
    ];
    out.add((
      loops: [
        for (final loop in loops)
          if (loop.$2)
            [for (final point in loop.$1) transform(local, point)]
          else
            [for (var i = 0; i < loop.$1.length; i++) transform(local, loop.$1.first)],
      ],
      sign: sign,
    ));
  }
}

Curve _lineLoop(List<Point> points) {
  if (points.length < 2) return const [];
  final loop = <Point>[points.first];
  for (var i = 0; i < points.length; i++) {
    final from = points[i], to = points[(i + 1) % points.length];
    loop.addAll([from + (to - from) * (1 / 3), from + (to - from) * (2 / 3), to]);
  }
  return loop;
}

Curve _strokeBand(Curve curve, double width) {
  const steps = 6;
  final line = <Point>[];
  for (var segment = 0; segment < (curve.length - 1) ~/ 3; segment++) {
    final p0 = curve[segment * 3], p1 = curve[segment * 3 + 1];
    final p2 = curve[segment * 3 + 2], p3 = curve[segment * 3 + 3];
    for (var step = segment == 0 ? 0 : 1; step <= steps; step++) {
      final t = step / steps, u = 1 - t;
      line.add(p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t));
    }
  }
  if (line.isEmpty) return const [];
  final half = width / 2;
  List<Point> side(double distance) {
    return [
      for (var i = 0; i < line.length; i++)
        () {
          var before = i, after = i;
          while (before > 0 && (line[before] - line[i]).length <= 1e-9) {
            before--;
          }
          while (after + 1 < line.length && (line[after] - line[i]).length <= 1e-9) {
            after++;
          }
          final run = line[after] - line[before], length = run.length;
          return length <= 1e-9
              ? line[i]
              : line[i] + Point(run.y / length, -run.x / length) * distance;
        }(),
    ];
  }

  return _lineLoop([...side(half), ...side(-half).reversed]);
}

/// A precomposition inside a matte: its own transform, its window, what it
/// covers, and what a matte of its own removes from it.
class _MatteNest implements _MattePart {
  _MatteNest(this.stack, this.window, this.content, this.remove);

  final List<Group> stack;
  final Track<double> window;
  final _Matte content;
  final _Matte? remove;

  @override
  void emit(int timeMs, Matrix parent, int sign, List<_Signed> out, {required bool live}) {
    var local = parent;
    for (final group in stack) {
      local = compose(local, group.matrixAt(timeMs));
    }
    final inside = live && window.at(timeMs) >= 0.5;
    for (final part in content.parts) {
      part.emit(timeMs, local, sign, out, live: inside);
    }
    for (final part in remove?.parts ?? const <_MattePart>[]) {
      part.emit(timeMs, local, -sign, out, live: inside);
    }
  }
}

/// Signed area of the widest loop in a set: which way the part turns.
double _outerArea(List<List<Point>> loops) {
  var widest = 0.0;
  for (final loop in loops) {
    final area = signedArea(flattenLoop(loop));
    if (area.abs() > widest.abs()) widest = area;
  }
  return widest;
}

/// A cubic read by arc length, the way Lottie walks a motion path.
///
/// A bezier's parameter is not its length: the same step in `t` covers more
/// ground where the curve is straight. Lottie measures the path and reads the
/// point at a fraction of its length, so the table here does the same.
class _Arc {
  _Arc(this.curve) {
    var last = curve.first;
    for (var i = 1; i <= _steps; i++) {
      final point = _at(i / _steps);
      _lengths.add(_lengths.last + (point - last).length);
      last = point;
    }
  }

  static const _steps = 64;
  final List<Point> curve;
  final List<double> _lengths = [0];

  Point at(double fraction) {
    final total = _lengths.last;
    if (total == 0) return curve.first;
    final target = (fraction * total).clamp(0.0, total);
    for (var i = 1; i < _lengths.length; i++) {
      if (target > _lengths[i]) continue;
      final span = _lengths[i] - _lengths[i - 1];
      final inside = span == 0 ? 0.0 : (target - _lengths[i - 1]) / span;
      return _at((i - 1 + inside) / _steps);
    }
    return curve.last;
  }

  Point _at(double t) {
    final u = 1 - t;
    return curve[0] * (u * u * u) +
        curve[1] * (3 * u * u * t) +
        curve[2] * (3 * u * t * t) +
        curve[3] * (t * t * t);
  }
}
