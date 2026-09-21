import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'contour.dart';
import 'fit.dart';
import 'model.dart';
import 'place.dart';
import 'winding.dart';

/// Reads an animated SVG - SMIL, which is what a vector tool exports and what
/// a browser plays without script - and rebuilds it as an
/// `AnimatedVectorDrawable`, structure for structure.
///
/// The two formats are closer than they look: both are a tree of transforms
/// over cubic outlines, and `<animate>` carries the same cubic timing that
/// `<pathInterpolator>` does. So a path stays the author's beziers, a `<g>`
/// stays a `<group>`, `keySplines` become interpolators, and nothing is traced.
class Svg {
  Svg._(this._root, this._byId, this._origin, this.width, this.height, this.durationMs);

  final XmlElement _root;
  final Map<String, XmlElement> _byId;

  /// The top left of the `viewBox`, which everything is measured from.
  final Point _origin;
  final double width;
  final double height;

  /// As long as the longest animation runs, which is the length a splash
  /// screen plays for. A still SVG is given a second, the most the guidelines
  /// allow, because a splash that never redraws still has to be on screen.
  final int durationMs;

  static Svg parse(Uint8List bytes) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(utf8.decode(bytes));
    } on XmlException catch (error) {
      throw FormatException('not an SVG: $error');
    } on FormatException {
      throw const FormatException('not an SVG: the file is not text');
    }
    final root = document.rootElement;
    if (root.name.local != 'svg') throw const FormatException('not an SVG: no <svg> element');

    final box = _numbers(root.getAttribute('viewBox') ?? '');
    final origin = box.length == 4 ? Point(box[0], box[1]) : const Point(0, 0);
    final width = box.length == 4 ? box[2] : _length(root.getAttribute('width')) ?? 0;
    final height = box.length == 4 ? box[3] : _length(root.getAttribute('height')) ?? 0;
    if (width <= 0 || height <= 0) {
      throw const FormatException('not an SVG: no viewBox and no width and height in pixels');
    }

    final byId = <String, XmlElement>{};
    for (final element in root.descendants.whereType<XmlElement>()) {
      final id = element.getAttribute('id');
      if (id != null) byId.putIfAbsent(id, () => element);
    }
    return Svg._(root, byId, origin, width, height, _duration(root));
  }

  /// Converts to the drawable model, laid out on a [canvasDp] canvas with the
  /// artwork inside [safeRadiusDp] of its centre.
  Drawable toDrawable(String name, double canvasDp, double safeRadiusDp,
      {double toleranceDp = 0.15, bool trim = true}) {
    final unsupported = <String>{};
    var index = 0;
    String id(String kind) => '${name}_$kind${index++}';
    // The root `<svg>` carries painting properties of its own - `fill="none"`
    // on it is what keeps an exporter's bounding boxes invisible - so the tree
    // starts from its style, not from the defaults.
    final roots =
        _children(_root, _Style.of(_root, _Style.root, this, unsupported), unsupported, id, 0);
    if (roots.isEmpty) {
      throw StateError('nothing convertible in the SVG'
          '${unsupported.isEmpty ? '' : ': it uses ${unsupported.join(', ')}'}');
    }
    _unsupported = unsupported;
    // The viewBox can start anywhere; the drawable's box starts at zero, so
    // the artwork moves by the difference once, above everything.
    final shifted = _origin.x == 0 && _origin.y == 0
        ? roots
        : [
            Group('${name}_viewbox',
                translateX: Track.constant(-_origin.x),
                translateY: Track.constant(-_origin.y),
                groups: roots),
          ];
    return place(
      name: name,
      source: 'SVG',
      roots: shifted,
      width: width,
      height: height,
      durationMs: durationMs,
      // SMIL is continuous, so the sampling rate is ours to choose: 60 a
      // second is the fastest a phone will draw.
      samples: [for (var f = 0; f * 1000 <= durationMs * 60; f++) (f * 1000 / 60).round()],
      canvasDp: canvasDp,
      safeRadiusDp: safeRadiusDp,
      toleranceDp: toleranceDp,
      trim: trim,
    );
  }

  /// Features found in the file that this converter does not reproduce.
  Set<String> get unsupported => _unsupported;
  Set<String> _unsupported = const {};

  /// Everything a container draws, in document order - which is paint order in
  /// both SVG and a `<vector>`, so the order is kept as it comes.
  List<Group> _children(XmlElement parent, _Style inherited, Set<String> unsupported,
      String Function(String) id, int depth) {
    final out = <Group>[];
    for (final child in parent.childElements) {
      final group = _element(child, inherited, unsupported, id, depth);
      if (group != null) out.add(group);
    }
    return out;
  }

  /// One element: its own transforms as nested `<group>`s, its clip, and either
  /// the shapes it draws or the children it contains.
  Group? _element(XmlElement element, _Style inherited, Set<String> unsupported,
      String Function(String) id, int depth) {
    final tag = element.name.local;
    // Definitions are drawn where they are referenced, never where they stand.
    if (const {
      'defs',
      'clipPath',
      'mask',
      'symbol',
      'marker',
      'pattern',
      'linearGradient',
      'radialGradient',
      'title',
      'desc',
      'metadata',
      'filter',
      'style',
      'script'
    }.contains(tag)) {
      if (tag == 'mask' || tag == 'pattern' || tag == 'filter') unsupported.add('$tag elements');
      if (tag == 'style') unsupported.add('CSS rules');
      return null;
    }
    // An animation drives the element it sits in; it draws nothing itself.
    if (const {'animate', 'animateTransform', 'set', 'animateMotion', 'discard'}.contains(tag)) {
      if (tag == 'animateMotion') unsupported.add('motion path animations');
      return null;
    }
    if (element.getAttribute('display') == 'none') return null;
    if (const {'text', 'tspan', 'image', 'foreignObject', 'switch'}.contains(tag)) {
      unsupported.add(tag == 'tspan' ? 'text' : '$tag elements');
      return null;
    }
    if (element.getAttribute('mask') != null) unsupported.add('mask elements');
    if (element.getAttribute('filter') != null) unsupported.add('filter elements');

    final style = _Style.of(element, inherited, this, unsupported);
    final List<Group> groups;
    final List<PathItem> paths;
    switch (tag) {
      case 'g' || 'a' || 'svg':
        groups = _children(element, style, unsupported, id, depth);
        paths = const [];
      case 'use':
        if (depth > 8) return null; // a reference that leads back to itself
        final target =
            _reference(element.getAttribute('href') ?? element.getAttribute('xlink:href'));
        if (target == null) return null;
        final placed = _element(target, style, unsupported, id, depth + 1);
        if (placed == null) return null;
        final x = _length(element.getAttribute('x')) ?? 0;
        final y = _length(element.getAttribute('y')) ?? 0;
        groups = [
          if (x == 0 && y == 0)
            placed
          else
            Group(id('use'),
                translateX: Track.constant(x), translateY: Track.constant(y), groups: [placed]),
        ];
        paths = const [];
      default:
        final shape = _outline(element, unsupported);
        if (shape == null) {
          unsupported.add('<$tag> elements');
          return null;
        }
        final paint = _paint(element, style, shape, unsupported);
        if (paint == null) return null; // nothing painted, so nothing to draw
        groups = const [];
        paths = [PathItem(id('path'), _morph(element, shape, unsupported), paint)];
    }
    if (groups.isEmpty && paths.isEmpty) return null;

    final clip = _clip(element, unsupported);
    var group = Group(id(tag == 'g' ? 'group' : 'shape'), groups: groups, paths: paths);
    // A transform list applies left to right, outermost first, and a `<group>`
    // carries one transform - so a list becomes a stack of them.
    for (final op in _transforms(element, unsupported, id).reversed) {
      group = op(group);
    }
    return clip == null ? group : Group(id('clip'), clip: clip, groups: [group]);
  }

  XmlElement? _reference(String? href) {
    if (href == null || !href.startsWith('#')) return null;
    return _byId[href.substring(1)];
  }

  /// The outline of a shape element, as the cubics a `<path>` is written from.
  /// Every SVG shape has an exact cubic form, so nothing here is approximated
  /// beyond the quarter-arc constant a circle is drawn with everywhere.
  List<Curve>? _outline(XmlElement element, Set<String> unsupported) {
    double at(String name, [double fallback = 0]) =>
        _length(element.getAttribute(name)) ?? fallback;
    switch (element.name.local) {
      case 'path':
        final data = element.getAttribute('d');
        if (data == null) return const [];
        return parsePathData(data, unsupported);
      case 'rect':
        final w = at('width'), h = at('height');
        if (w <= 0 || h <= 0) return const [];
        final rx = math.min(element.getAttribute('rx') == null ? at('ry') : at('rx'), w / 2);
        final ry = math.min(element.getAttribute('ry') == null ? at('rx') : at('ry'), h / 2);
        return [_rounded(at('x'), at('y'), w, h, rx, ry)];
      case 'circle':
        final r = at('r');
        return r <= 0 ? const [] : [_ellipse(at('cx'), at('cy'), r, r)];
      case 'ellipse':
        final rx = at('rx'), ry = at('ry');
        return rx <= 0 || ry <= 0 ? const [] : [_ellipse(at('cx'), at('cy'), rx, ry)];
      case 'line':
        return [
          _polyline([Point(at('x1'), at('y1')), Point(at('x2'), at('y2'))])
        ];
      case 'polyline' || 'polygon':
        final numbers = _numbers(element.getAttribute('points') ?? '');
        if (numbers.length < 4) return const [];
        return [
          _polyline([
            for (var i = 0; i + 1 < numbers.length; i += 2) Point(numbers[i], numbers[i + 1]),
          ]),
        ];
      default:
        return null;
    }
  }

  /// An `<animate attributeName="d">` turns the outline into a morph. Android
  /// morphs two paths only when their commands match one for one, so a set of
  /// keyframes that does not is reported rather than written.
  Track<List<Curve>> _morph(XmlElement element, List<Curve> still, Set<String> unsupported) {
    for (final animation in _animations(element, 'd')) {
      final keys = _timeline<List<Curve>>(
        animation,
        (text) => parsePathData(text, unsupported),
        still,
        unsupported,
      );
      if (keys == null) continue;
      final shape = _structure(still);
      if (keys.any((key) => _structure(key.value) != shape)) {
        unsupported.add('a path morph whose keyframes have different commands');
        continue;
      }
      return Track(keys);
    }
    return Track.constant(still);
  }

  static String _structure(List<Curve> curves) => curves.map((c) => c.length).join(',');

  /// How a shape is painted, with the group opacities above it folded in - a
  /// `<group>` cannot carry alpha, so this is where it has to land.
  Paint? _paint(XmlElement element, _Style style, List<Curve> outline, Set<String> unsupported) {
    final fill = style.fill;
    final stroke = style.stroke;
    final width = style.strokeWidth;
    final fillColour = fill == null ? null : _colour(fill);
    final gradient = fill == null ? null : _gradientOf(fill, outline, unsupported);
    final strokeColour = stroke == null ? null : _colour(stroke);
    if (fillColour == null && gradient == null && strokeColour == null) return null;
    if (_animations(element, 'fill').isNotEmpty || _animations(element, 'stroke').isNotEmpty) {
      // `AnimatedVectorDrawable` can animate a colour, but the model behind
      // this converter keeps one paint per path, so this is reported instead
      // of quietly showing the first colour as if it never changed.
      unsupported.add('animated colours');
    }
    final opaque = fillColour != null || gradient != null;
    return Paint(
      color: gradient == null ? fillColour : null,
      gradient: gradient,
      alpha: opaque ? multiplyTracks(style.alpha, style.fillOpacity) : null,
      strokeColor: strokeColour,
      strokeAlpha: strokeColour == null ? null : multiplyTracks(style.alpha, style.strokeOpacity),
      strokeWidth: strokeColour == null ? null : width,
      cap: style.cap,
      join: style.join,
      evenOdd: style.evenOdd,
    );
  }

  /// A `clip-path="url(#id)"`, as the clip a `<group>` carries.
  ///
  /// The loops are wound rather than declared even-odd, because
  /// `VectorDrawableClipPath` has no fill type and always fills by winding.
  Track<List<Curve>>? _clip(XmlElement element, Set<String> unsupported) {
    final reference = element.getAttribute('clip-path');
    if (reference == null) return null;
    final clip = _reference(_url(reference));
    if (clip == null || clip.name.local != 'clipPath') {
      unsupported.add('clip paths that are not a <clipPath>');
      return null;
    }
    final loops = <Curve>[];
    for (final shape in clip.childElements) {
      final outline = _outline(shape, unsupported);
      if (outline == null) continue;
      final transforms = _transforms(shape, unsupported, (_) => 'clip');
      if (transforms.isEmpty) {
        loops.addAll(outline);
        continue;
      }
      // A transform on a clip shape is baked in: there is no group to hang it
      // on, and a clip's own geometry is the only place it can go.
      var group = Group('clip', paths: [PathItem('clip', Track.constant(outline), Paint())]);
      for (final op in transforms.reversed) {
        group = op(group);
      }
      final matrix = _flatten(group);
      for (final loop in outline) {
        loops.add([for (final point in loop) transform(matrix, point)]);
      }
    }
    if (loops.isEmpty) return null;
    if (clip.getAttribute('clipPathUnits') == 'objectBoundingBox') {
      unsupported.add('clip paths measured in bounding box units');
    }
    return Track.constant(Winding.of([loops]).apply(loops));
  }

  /// The transform of a group stack collapsed into one matrix, for the places
  /// that have no group to put it on.
  Matrix _flatten(Group group) {
    var matrix = group.matrixAt(0);
    for (final child in group.groups) {
      matrix = compose(matrix, _flatten(child));
    }
    return matrix;
  }

  /// The transforms an element carries, outermost first, as functions that wrap
  /// what they transform. A `<animateTransform>` replaces the static transform
  /// unless it says `additive="sum"`, which is what SMIL does.
  List<Group Function(Group)> _transforms(
      XmlElement element, Set<String> unsupported, String Function(String) id) {
    final animated = [
      for (final animation in element.childElements)
        if (animation.name.local == 'animateTransform') animation,
    ];
    final replaces = animated.any((a) => (a.getAttribute('additive') ?? 'replace') == 'replace');
    final out = <Group Function(Group)>[];
    if (!replaces) {
      out.addAll(_static(element.getAttribute('transform'), unsupported, id));
    }
    for (final animation in animated) {
      final op = _animatedTransform(animation, unsupported, id);
      if (op != null) out.add(op);
    }
    return out;
  }

  /// A `transform` attribute: a list of operations, each its own group.
  List<Group Function(Group)> _static(
      String? transform, Set<String> unsupported, String Function(String) id) {
    if (transform == null || transform.trim().isEmpty) return const [];
    final out = <Group Function(Group)>[];
    for (final match in _operation.allMatches(transform)) {
      final kind = match.group(1)!;
      final values = _numbers(match.group(2)!);
      switch (kind) {
        case 'translate':
          if (values.isEmpty) continue;
          final x = values[0], y = values.length > 1 ? values[1] : 0.0;
          out.add((child) => Group(id('translate'),
              translateX: Track.constant(x), translateY: Track.constant(y), groups: [child]));
        case 'scale':
          if (values.isEmpty) continue;
          final x = values[0], y = values.length > 1 ? values[1] : values[0];
          out.add((child) => Group(id('scale'),
              scaleX: Track.constant(x), scaleY: Track.constant(y), groups: [child]));
        case 'rotate':
          if (values.isEmpty) continue;
          final pivot = values.length > 2 ? Point(values[1], values[2]) : const Point(0, 0);
          out.add((child) => Group(id('rotate'),
              pivot: pivot, rotation: Track.constant(values[0]), groups: [child]));
        case 'matrix':
          if (values.length < 6) continue;
          final op = _decompose(values, unsupported, id);
          if (op != null) out.add(op);
        case 'skewX' || 'skewY':
          // A `<group>` has no shear, and there is no pair of scales and
          // rotations that makes one.
          unsupported.add('skewed transforms');
      }
    }
    return out;
  }

  /// A static `matrix(a,b,c,d,e,f)` as a group: translation, rotation and
  /// scale, which is every matrix a drawing tool writes.
  Group Function(Group)? _decompose(
      List<double> m, Set<String> unsupported, String Function(String) id) {
    final a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5];
    final scaleX = math.sqrt(a * a + b * b);
    final determinant = a * d - b * c;
    final scaleY = scaleX == 0 ? 0.0 : determinant / scaleX;
    final shear = scaleX == 0 ? 0.0 : (a * c + b * d) / (scaleX * scaleX);
    if (shear.abs() > 1e-6) unsupported.add('skewed transforms');
    final rotation = math.atan2(b, a) * 180 / math.pi;
    return (child) => Group(
          id('matrix'),
          translateX: Track.constant(e),
          translateY: Track.constant(f),
          scaleX: Track.constant(scaleX),
          scaleY: Track.constant(scaleY),
          rotation: Track.constant(rotation),
          groups: [child],
        );
  }

  /// One `<animateTransform>` as an animated group.
  Group Function(Group)? _animatedTransform(
      XmlElement animation, Set<String> unsupported, String Function(String) id) {
    if ((animation.getAttribute('attributeName') ?? 'transform') != 'transform') return null;
    final type = animation.getAttribute('type') ?? 'translate';
    List<double> pair(String text) {
      final values = _numbers(text);
      return values.isEmpty ? const [0, 0] : values;
    }

    switch (type) {
      case 'translate':
        final keys = _timeline<List<double>>(animation, pair, const [0, 0], unsupported);
        if (keys == null) return null;
        return (child) => Group(id('translate'),
            translateX: Track([for (final k in keys) Key(k.timeMs, k.value[0], k.easing)]),
            translateY: Track([
              for (final k in keys) Key(k.timeMs, k.value.length > 1 ? k.value[1] : 0, k.easing),
            ]),
            groups: [child]);
      case 'scale':
        final keys = _timeline<List<double>>(animation, pair, const [1, 1], unsupported);
        if (keys == null) return null;
        return (child) => Group(id('scale'),
            scaleX: Track([for (final k in keys) Key(k.timeMs, k.value[0], k.easing)]),
            scaleY: Track([
              for (final k in keys)
                Key(k.timeMs, k.value.length > 1 ? k.value[1] : k.value[0], k.easing),
            ]),
            groups: [child]);
      case 'rotate':
        final keys = _timeline<List<double>>(animation, pair, const [0, 0, 0], unsupported);
        if (keys == null) return null;
        final centres = {
          for (final k in keys)
            if (k.value.length > 2) '${k.value[1]},${k.value[2]}',
        };
        if (centres.length > 1) unsupported.add('a rotation whose centre moves');
        final first = keys.first.value;
        return (child) => Group(id('rotate'),
            pivot: first.length > 2 ? Point(first[1], first[2]) : const Point(0, 0),
            rotation: Track([for (final k in keys) Key(k.timeMs, k.value[0], k.easing)]),
            groups: [child]);
      default:
        unsupported.add('skewed transforms');
        return null;
    }
  }

  /// Every `<animate>` or `<set>` on [element] that drives [attribute].
  List<XmlElement> _animations(XmlElement element, String attribute) => [
        for (final child in element.childElements)
          if ((child.name.local == 'animate' || child.name.local == 'set') &&
              child.getAttribute('attributeName') == attribute)
            child,
      ];

  /// A property that an `<animate>` drives, or its still value.
  Track<double> _animatedNumber(
      XmlElement element, String attribute, double still, Set<String> unsupported) {
    for (final animation in _animations(element, attribute)) {
      final keys =
          _timeline<double>(animation, (text) => _length(text) ?? still, still, unsupported);
      if (keys != null) return Track(keys);
    }
    return Track.constant(still);
  }

  /// One SMIL animation as keys on our own timeline.
  ///
  /// `keyTimes` are fractions of one run, `keySplines` is the cubic easing of
  /// each interval - the same curve `<pathInterpolator>` takes - and a run that
  /// repeats is laid out again after itself, because Android has no repeat
  /// count on a keyframe set. A run that does not freeze snaps back to the
  /// value the document declares, which is a key of its own.
  List<Key<T>>? _timeline<T>(
      XmlElement animation, T Function(String) read, T still, Set<String> unsupported) {
    final begin = animation.getAttribute('begin');
    if (begin != null && begin.trim().isNotEmpty && _seconds(begin) == null) {
      unsupported.add('animations that start on an event');
      return null;
    }
    final start = (_seconds(begin) ?? 0) * 1000;
    final length = (_seconds(animation.getAttribute('dur')) ?? 0) * 1000;
    final raw = animation.getAttribute('values');
    final values = <T>[];
    if (raw != null) {
      values.addAll([
        for (final part in raw.split(';'))
          if (part.trim().isNotEmpty) read(part)
      ]);
    } else {
      final from = animation.getAttribute('from'), to = animation.getAttribute('to');
      final by = animation.getAttribute('by');
      if (by != null) {
        unsupported.add('animations that count by a step');
        return null;
      }
      if (animation.name.local == 'set') {
        final value = animation.getAttribute('to');
        if (value == null) return null;
        return [
          if (start > 0) Key(0, still, _hold),
          Key(start.round(), read(value)),
        ];
      }
      if (to == null) return null;
      values
        ..add(from == null ? still : read(from))
        ..add(read(to));
    }
    if (values.isEmpty) return null;
    if (values.length == 1) return [Key(start.round(), values.first)];

    final times = _numbers(animation.getAttribute('keyTimes') ?? '');
    final fractions = times.length == values.length
        ? times
        : [for (var i = 0; i < values.length; i++) i / (values.length - 1)];
    final discrete = animation.getAttribute('calcMode') == 'discrete';
    final splines = animation.getAttribute('calcMode') == 'spline'
        ? [
            for (final part in (animation.getAttribute('keySplines') ?? '').split(';'))
              if (part.trim().isNotEmpty) _numbers(part),
          ]
        : const <List<double>>[];

    final repeat = animation.getAttribute('repeatCount');
    final runs = repeat == null
        ? 1
        : repeat == 'indefinite'
            ? (length <= 0 ? 1 : (durationMs - start) / length).ceil()
            : (double.tryParse(repeat) ?? 1).ceil();
    final keys = <Key<T>>[];
    if (start > 0) keys.add(Key(0, values.first, _hold));
    for (var run = 0; run < math.max(1, runs); run++) {
      final base = start + run * length;
      if (base > durationMs) break;
      for (var i = 0; i < values.length; i++) {
        final easing = discrete
            ? _hold
            : i < splines.length && splines[i].length == 4
                ? Easing(splines[i][0], splines[i][1], splines[i][2], splines[i][3])
                : Easing.linear;
        keys.add(Key((base + fractions[i] * length).round(), values[i], easing));
      }
    }
    if ((animation.getAttribute('fill') ?? 'remove') != 'freeze') {
      final ends = start + math.max(1, runs) * length;
      if (ends < durationMs) keys.add(Key(ends.round(), still, _hold));
    }
    return _tidy(keys);
  }

  /// Keys in order, with a repeated instant left with its last value: a run
  /// that is laid out again after itself ends where the next one begins.
  List<Key<T>> _tidy<T>(List<Key<T>> keys) {
    keys.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    final out = <Key<T>>[];
    for (final key in keys) {
      if (out.isNotEmpty && out.last.timeMs == key.timeMs) out.removeLast();
      out.add(key);
    }
    return out;
  }

  /// A `fill="url(#id)"` as the gradient it names, fitted to the outline it
  /// paints, because `AnimatedVectorDrawable` cannot animate a gradient and an
  /// SVG measures one against the shape by default.
  Gradient? _gradientOf(String paint, List<Curve> outline, Set<String> unsupported) {
    final id = _url(paint);
    if (id == null) return null;
    var element = _reference(id);
    if (element == null) return null;
    final type = element.name.local;
    if (type != 'linearGradient' && type != 'radialGradient') {
      unsupported.add('$type paints');
      return null;
    }
    // A gradient may take its stops, or any attribute, from another one.
    final chain = <XmlElement>[element];
    for (var depth = 0; depth < 8; depth++) {
      final next = _reference(element!.getAttribute('href') ?? element.getAttribute('xlink:href'));
      if (next == null) break;
      chain.add(next);
      element = next;
    }
    String? attribute(String name) {
      for (final node in chain) {
        final value = node.getAttribute(name);
        if (value != null) return value;
      }
      return null;
    }

    if (attribute('gradientTransform') != null) unsupported.add('transformed gradients');
    if ((attribute('spreadMethod') ?? 'pad') != 'pad') unsupported.add('gradients that repeat');

    final stops = <(double, int)>[];
    for (final node in chain) {
      for (final stop in node.childElements.where((e) => e.name.local == 'stop')) {
        final offset = _fraction(stop.getAttribute('offset')) ?? 0;
        final colour = _colour(_declared(stop, 'stop-color') ?? '#000000') ?? 0xFF000000;
        final alpha = _fraction(_declared(stop, 'stop-opacity')) ?? 1;
        stops.add((offset, (colour & 0x00FFFFFF) | ((alpha * 255).round().clamp(0, 255) << 24)));
      }
      if (stops.isNotEmpty) break;
    }
    if (stops.isEmpty) return null;

    // Fractions of the shape's own box, unless the file says user space.
    final bounds = _bounds(outline);
    final user = attribute('gradientUnits') == 'userSpaceOnUse';
    double x(String? value, double fallback) {
      final f = _fraction(value) ?? fallback;
      return user ? (_length(value) ?? fallback) : bounds.left + f * bounds.width;
    }

    double y(String? value, double fallback) {
      final f = _fraction(value) ?? fallback;
      return user ? (_length(value) ?? fallback) : bounds.top + f * bounds.height;
    }

    if (type == 'linearGradient') {
      return Gradient(
        'linear',
        Point(x(attribute('x1'), 0), y(attribute('y1'), 0)),
        Point(x(attribute('x2'), 1), y(attribute('y2'), 0)),
        stops,
      );
    }
    if (attribute('fx') != null || attribute('fy') != null) {
      unsupported.add('gradients with an off-centre focus');
    }
    final centre = Point(x(attribute('cx'), 0.5), y(attribute('cy'), 0.5));
    final radius = user
        ? (_length(attribute('r')) ?? 0)
        : (_fraction(attribute('r')) ?? 0.5) *
            math.sqrt(bounds.width * bounds.width + bounds.height * bounds.height) /
            math.sqrt2;
    return Gradient('radial', centre, centre, stops, radius);
  }

  static _Bounds _bounds(List<Curve> curves) {
    var left = double.infinity, top = double.infinity;
    var right = -double.infinity, bottom = -double.infinity;
    for (final curve in curves) {
      for (final point in curve) {
        left = math.min(left, point.x);
        top = math.min(top, point.y);
        right = math.max(right, point.x);
        bottom = math.max(bottom, point.y);
      }
    }
    return left.isFinite
        ? (left: left, top: top, width: right - left, height: bottom - top)
        : (left: 0.0, top: 0.0, width: 1.0, height: 1.0);
  }

  /// How long the whole file runs: the last instant any animation reaches.
  static int _duration(XmlElement root) {
    var end = 0.0;
    for (final element in root.descendants.whereType<XmlElement>()) {
      if (!const {'animate', 'animateTransform', 'animateMotion', 'set'}
          .contains(element.name.local)) {
        continue;
      }
      final begin = _seconds(element.getAttribute('begin')) ?? 0;
      final length = _seconds(element.getAttribute('dur')) ?? 0;
      final repeat = element.getAttribute('repeatCount');
      // An animation that repeats for ever sets the length of one run; the
      // splash screen plays once, so one run is what there is to play.
      final runs = repeat == null || repeat == 'indefinite' ? 1.0 : double.tryParse(repeat) ?? 1.0;
      final stop = _seconds(element.getAttribute('end'));
      final finish = stop == null ? begin + length * runs : math.min(begin + length * runs, stop);
      if (finish > end) end = finish;
    }
    return end > 0 ? (end * 1000).round() : 1000;
  }
}

/// The painting properties in force at one point in the tree.
///
/// SVG inherits them as text, so they are carried as text and resolved at the
/// shape that uses them - which is also what makes `currentColor` and a
/// `url(#id)` fill behave the way the format says they do.
class _Style {
  const _Style({
    this.fill,
    this.stroke,
    required this.alpha,
    required this.fillOpacity,
    required this.strokeOpacity,
    required this.strokeWidth,
    this.cap,
    this.join,
    this.evenOdd = false,
  });

  static final root = _Style(
    fill: '#000000',
    alpha: Track.constant(1),
    fillOpacity: Track.constant(1),
    strokeOpacity: Track.constant(1),
    strokeWidth: Track.constant(1),
  );

  final String? fill;
  final String? stroke;

  /// The opacity of every group above this point, folded together.
  final Track<double> alpha;
  final Track<double> fillOpacity;
  final Track<double> strokeOpacity;
  final Track<double> strokeWidth;
  final String? cap;
  final String? join;
  final bool evenOdd;

  static _Style of(XmlElement element, _Style parent, Svg svg, Set<String> unsupported) {
    if (element.getAttribute('class') != null) unsupported.add('CSS classes');
    String? declared(String name) => _declared(element, name);
    final fill = declared('fill');
    final stroke = declared('stroke');
    final rule = declared('fill-rule') ?? declared('clip-rule');
    final cap = declared('stroke-linecap');
    final join = declared('stroke-linejoin');
    // `opacity` applies to the group as a whole. A `<group>` cannot carry it,
    // so it is folded into the paints below - which is exact for artwork that
    // does not overlap itself, and the closest a `<vector>` can come when it
    // does.
    final own =
        svg._animatedNumber(element, 'opacity', _fraction(declared('opacity')) ?? 1, unsupported);
    return _Style(
      fill: fill == null ? parent.fill : (fill == 'none' ? null : fill),
      stroke: stroke == null ? parent.stroke : (stroke == 'none' ? null : stroke),
      alpha: multiplyTracks(parent.alpha, own),
      fillOpacity: declared('fill-opacity') == null && _isStill(svg, element, 'fill-opacity')
          ? parent.fillOpacity
          : svg._animatedNumber(
              element, 'fill-opacity', _fraction(declared('fill-opacity')) ?? 1, unsupported),
      strokeOpacity: declared('stroke-opacity') == null && _isStill(svg, element, 'stroke-opacity')
          ? parent.strokeOpacity
          : svg._animatedNumber(
              element, 'stroke-opacity', _fraction(declared('stroke-opacity')) ?? 1, unsupported),
      strokeWidth: declared('stroke-width') == null && _isStill(svg, element, 'stroke-width')
          ? parent.strokeWidth
          : svg._animatedNumber(
              element, 'stroke-width', _length(declared('stroke-width')) ?? 1, unsupported),
      cap: cap ?? parent.cap,
      join: join ?? parent.join,
      evenOdd: rule == null ? parent.evenOdd : rule == 'evenodd',
    );
  }

  static bool _isStill(Svg svg, XmlElement element, String attribute) =>
      svg._animations(element, attribute).isEmpty;
}

typedef _Bounds = ({double left, double top, double width, double height});

/// A property as the document declares it: the attribute, or the `style`
/// attribute, which wins over it.
String? _declared(XmlElement element, String name) {
  final inline = element.getAttribute('style');
  if (inline != null) {
    for (final part in inline.split(';')) {
      final colon = part.indexOf(':');
      if (colon < 0) continue;
      if (part.substring(0, colon).trim() == name) return part.substring(colon + 1).trim();
    }
  }
  return element.getAttribute(name);
}

const _hold = Easing(1, 0, 1, 0);

final _operation = RegExp(r'(matrix|translate|scale|rotate|skewX|skewY)\s*\(([^)]*)\)');
final _numberPattern = RegExp(r'[-+]?(\d*\.\d+|\d+\.?)([eE][-+]?\d+)?');

List<double> _numbers(String text) =>
    [for (final match in _numberPattern.allMatches(text)) double.parse(match[0]!)];

/// A length in user units. Only absolute units mean anything here: a
/// percentage of the viewport would need a layout, and a splash icon has none.
double? _length(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  final match = _numberPattern.firstMatch(trimmed);
  if (match == null || match.start != 0) return null;
  final value = double.parse(match[0]!);
  return switch (trimmed.substring(match.end).trim()) {
    '' || 'px' => value,
    'pt' => value * 4 / 3,
    'pc' => value * 16,
    'mm' => value * 96 / 25.4,
    'cm' => value * 96 / 2.54,
    'in' => value * 96,
    _ => null,
  };
}

/// A number that may be written as a percentage, as offsets and opacities are.
double? _fraction(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  if (trimmed.endsWith('%')) {
    final value = double.tryParse(trimmed.substring(0, trimmed.length - 1));
    return value == null ? null : value / 100;
  }
  return double.tryParse(trimmed);
}

/// An SMIL clock value in seconds: `4.583s`, `250ms`, `1min`, or a bare number.
double? _seconds(String? text) {
  if (text == null) return null;
  if (text.trim().isEmpty) return 0;
  final trimmed = text.trim();
  final match = _numberPattern.firstMatch(trimmed);
  if (match == null || match.start != 0) return null;
  final value = double.parse(match[0]!);
  return switch (trimmed.substring(match.end).trim()) {
    '' || 's' => value,
    'ms' => value / 1000,
    'min' => value * 60,
    'h' => value * 3600,
    _ => null,
  };
}

String? _url(String paint) {
  final match = RegExp(r'url\(\s*#([^)\s]+)\s*\)').firstMatch(paint);
  return match == null ? null : '#${match[1]}';
}

/// A colour in any form an SVG may write one.
int? _colour(String text) {
  var value = text.trim().toLowerCase();
  if (value.isEmpty || value == 'none' || value.startsWith('url(')) return null;
  // `currentColor` inherits from a CSS property no drawable has; black is what
  // a browser shows when nothing sets it.
  if (value == 'currentcolor') return 0xFF000000;
  if (value == 'transparent') return 0x00000000;
  if (value.startsWith('#')) {
    value = value.substring(1);
    if (value.length == 3 || value.length == 4) {
      value = [for (final digit in value.split('')) '$digit$digit'].join();
    }
    final number = int.tryParse(value, radix: 16);
    if (number == null) return null;
    if (value.length == 6) return 0xFF000000 | number;
    if (value.length == 8) {
      // CSS writes the alpha last; Android writes it first.
      return ((number & 0xFF) << 24) | (number >> 8);
    }
    return null;
  }
  final call = RegExp(r'^rgba?\(([^)]*)\)').firstMatch(value);
  if (call != null) {
    final parts = call[1]!.split(',');
    if (parts.length < 3) return null;
    int channel(int i) {
      final part = parts[i].trim();
      final number = part.endsWith('%')
          ? (double.parse(part.substring(0, part.length - 1)) * 255 / 100)
          : double.parse(part);
      return number.round().clamp(0, 255);
    }

    final alpha = parts.length > 3 ? ((_fraction(parts[3]) ?? 1) * 255).round().clamp(0, 255) : 255;
    return (alpha << 24) | (channel(0) << 16) | (channel(1) << 8) | channel(2);
  }
  return _named[value];
}

/// A rectangle, with the corner radii SVG allows, as one cubic loop.
Curve _rounded(double x, double y, double w, double h, double rx, double ry) {
  if (rx <= 0 || ry <= 0) {
    return _closed([Point(x, y), Point(x + w, y), Point(x + w, y + h), Point(x, y + h)]);
  }
  final cx = rx * _kappa, cy = ry * _kappa;
  final loop = <Point>[Point(x + rx, y)];
  void line(Point to) => loop.addAll([loop.last, to, to]);
  void arc(Point handle1, Point handle2, Point to) => loop.addAll([handle1, handle2, to]);
  line(Point(x + w - rx, y));
  arc(Point(x + w - rx + cx, y), Point(x + w, y + ry - cy), Point(x + w, y + ry));
  line(Point(x + w, y + h - ry));
  arc(Point(x + w, y + h - ry + cy), Point(x + w - rx + cx, y + h), Point(x + w - rx, y + h));
  line(Point(x + rx, y + h));
  arc(Point(x + rx - cx, y + h), Point(x, y + h - ry + cy), Point(x, y + h - ry));
  line(Point(x, y + ry));
  arc(Point(x, y + ry - cy), Point(x + rx - cx, y), Point(x + rx, y));
  return loop;
}

/// An ellipse as the four cubics every renderer draws one with.
Curve _ellipse(double cx, double cy, double rx, double ry) {
  final hx = rx * _kappa, hy = ry * _kappa;
  return [
    Point(cx + rx, cy),
    Point(cx + rx, cy + hy),
    Point(cx + hx, cy + ry),
    Point(cx, cy + ry),
    Point(cx - hx, cy + ry),
    Point(cx - rx, cy + hy),
    Point(cx - rx, cy),
    Point(cx - rx, cy - hy),
    Point(cx - hx, cy - ry),
    Point(cx, cy - ry),
    Point(cx + hx, cy - ry),
    Point(cx + rx, cy - hy),
    Point(cx + rx, cy),
  ];
}

/// Straight segments as cubics, which is the only segment a `<vector>` morph
/// can hold beside a curve.
Curve _polyline(List<Point> points) => _closed(points);

Curve _closed(List<Point> points) {
  final loop = <Point>[points.first];
  for (var i = 1; i < points.length; i++) {
    loop.addAll([points[i - 1], points[i], points[i]]);
  }
  loop.addAll([points.last, points.first, points.first]);
  return loop;
}

/// The handle length that turns a quarter circle into a cubic, to within a
/// thousandth of the radius - the constant every vector renderer uses.
const _kappa = 0.5522847498307933;

/// An SVG `d` attribute as cubic loops.
///
/// Every command is converted to the one form a `<vector>` path and an
/// `AnimatedVectorDrawable` morph can both carry: a cubic. Lines become cubics
/// with their handles on their ends, quadratics are raised a degree exactly,
/// the shorthands are resolved against the previous segment, and an elliptical
/// arc becomes the quarter-or-less cubics it is drawn with.
List<Curve> parsePathData(String data, Set<String> unsupported) {
  final curves = <Curve>[];
  final tokens = _tokens(data);
  Curve? current;
  var at = 0;
  var point = const Point(0, 0);
  var start = const Point(0, 0);
  Point? lastCubic, lastQuadratic;
  var command = '';

  void push(Point handle1, Point handle2, Point to) {
    current ??= [point];
    current!.addAll([handle1, handle2, to]);
    point = to;
  }

  void line(Point to) => push(point, to, to);

  while (at < tokens.length) {
    final token = tokens[at];
    if (token is String) {
      command = token;
      at++;
      if (command.toUpperCase() == 'Z') {
        if (current != null) {
          if (point != start) line(start);
          curves.add(current!);
          current = null;
        }
        point = start;
        lastCubic = lastQuadratic = null;
        continue;
      }
    } else if (command.isEmpty) {
      break; // numbers before any command: nothing to do with them
    }
    final relative = command.toLowerCase() == command;
    final base = relative ? point : const Point(0, 0);
    double next() {
      final value = at < tokens.length && tokens[at] is num ? tokens[at] as double : 0.0;
      at++;
      return value;
    }

    Point nextPoint() {
      final x = next(), y = next();
      return Point(base.x + x, base.y + y);
    }

    switch (command.toUpperCase()) {
      case 'M':
        if (current != null) {
          curves.add(current!);
          current = null;
        }
        point = nextPoint();
        start = point;
        current = [point];
        // Every pair after the first is a line, which is what the format says.
        command = relative ? 'l' : 'L';
        lastCubic = lastQuadratic = null;
      case 'L':
        line(nextPoint());
        lastCubic = lastQuadratic = null;
      case 'H':
        line(Point(base.x + next(), point.y));
        lastCubic = lastQuadratic = null;
      case 'V':
        line(Point(point.x, base.y + next()));
        lastCubic = lastQuadratic = null;
      case 'C':
        final handle1 = nextPoint(), handle2 = nextPoint(), to = nextPoint();
        push(handle1, handle2, to);
        lastCubic = handle2;
        lastQuadratic = null;
      case 'S':
        final mirror = lastCubic == null ? point : point * 2 - lastCubic;
        final handle2 = nextPoint(), to = nextPoint();
        push(mirror, handle2, to);
        lastCubic = handle2;
        lastQuadratic = null;
      case 'Q':
        final control = nextPoint(), to = nextPoint();
        push(point + (control - point) * (2 / 3), to + (control - to) * (2 / 3), to);
        lastQuadratic = control;
        lastCubic = null;
      case 'T':
        final control = lastQuadratic == null ? point : point * 2 - lastQuadratic;
        final to = nextPoint();
        push(point + (control - point) * (2 / 3), to + (control - to) * (2 / 3), to);
        lastQuadratic = control;
        lastCubic = null;
      case 'A':
        final rx = next(), ry = next(), rotation = next();
        final large = next() != 0, sweep = next() != 0;
        final to = nextPoint();
        for (final segment in _arc(point, to, rx, ry, rotation, large, sweep)) {
          push(segment[0], segment[1], segment[2]);
        }
        lastCubic = lastQuadratic = null;
      default:
        unsupported.add('the path command "$command"');
        at = tokens.length;
    }
  }
  if (current != null && current!.length > 1) curves.add(current!);
  return curves;
}

/// Path data split into commands and numbers, which is all its grammar is.
List<Object> _tokens(String data) {
  final out = <Object>[];
  var i = 0;
  while (i < data.length) {
    final code = data.codeUnitAt(i);
    if (code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D || code == 0x2C) {
      i++;
      continue;
    }
    if ('MmLlHhVvCcSsQqTtAaZz'.contains(data[i])) {
      out.add(data[i]);
      i++;
      continue;
    }
    final match = _numberPattern.matchAsPrefix(data, i);
    if (match == null) {
      i++;
      continue;
    }
    out.add(double.parse(match[0]!));
    i = match.end;
  }
  return out;
}

/// An elliptical arc as cubics: the endpoint form the format writes, turned
/// into the centre form, then split into segments of at most a quarter turn -
/// where a cubic is within a thousandth of a true ellipse.
List<List<Point>> _arc(
    Point from, Point to, double rx, double ry, double rotation, bool large, bool sweep) {
  if (rx == 0 || ry == 0 || from == to) {
    return [
      [from, to, to],
    ];
  }
  rx = rx.abs();
  ry = ry.abs();
  final radians = rotation * math.pi / 180;
  final cos = math.cos(radians), sin = math.sin(radians);
  final dx = (from.x - to.x) / 2, dy = (from.y - to.y) / 2;
  final x1 = cos * dx + sin * dy, y1 = -sin * dx + cos * dy;
  // An arc whose radii cannot span the two ends is scaled up until it can,
  // which is what the specification asks for rather than an error.
  final oversize = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
  if (oversize > 1) {
    final grow = math.sqrt(oversize);
    rx *= grow;
    ry *= grow;
  }
  final numerator = math.max(0.0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1);
  final denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1;
  final factor = (large == sweep ? -1 : 1) * math.sqrt(numerator / denominator);
  final cxr = factor * rx * y1 / ry, cyr = -factor * ry * x1 / rx;
  final centre = Point(
    cos * cxr - sin * cyr + (from.x + to.x) / 2,
    sin * cxr + cos * cyr + (from.y + to.y) / 2,
  );
  double angle(double x, double y) => math.atan2((y - cyr) / ry, (x - cxr) / rx);
  final startAngle = angle(x1, y1);
  var sweepAngle = angle(-x1, -y1) - startAngle;
  if (!sweep && sweepAngle > 0) sweepAngle -= 2 * math.pi;
  if (sweep && sweepAngle < 0) sweepAngle += 2 * math.pi;

  final segments = math.max(1, (sweepAngle.abs() / (math.pi / 2)).ceil());
  final step = sweepAngle / segments;
  final handle = 4 / 3 * math.tan(step / 4);
  final out = <List<Point>>[];
  var current = startAngle;
  Point on(double t) {
    final x = rx * math.cos(t), y = ry * math.sin(t);
    return Point(cos * x - sin * y + centre.x, sin * x + cos * y + centre.y);
  }

  Point tangent(double t) {
    final x = -rx * math.sin(t), y = ry * math.cos(t);
    return Point(cos * x - sin * y, sin * x + cos * y);
  }

  for (var i = 0; i < segments; i++) {
    final end = current + step;
    final p0 = on(current), p1 = on(end);
    out.add([
      p0 + tangent(current) * handle,
      p1 - tangent(end) * handle,
      p1,
    ]);
    current = end;
  }
  return out;
}

/// The CSS colour names an SVG may use instead of a hex triplet.
const _named = <String, int>{
  'aliceblue': 0xFFF0F8FF,
  'antiquewhite': 0xFFFAEBD7,
  'aqua': 0xFF00FFFF,
  'aquamarine': 0xFF7FFFD4,
  'azure': 0xFFF0FFFF,
  'beige': 0xFFF5F5DC,
  'bisque': 0xFFFFE4C4,
  'black': 0xFF000000,
  'blanchedalmond': 0xFFFFEBCD,
  'blue': 0xFF0000FF,
  'blueviolet': 0xFF8A2BE2,
  'brown': 0xFFA52A2A,
  'burlywood': 0xFFDEB887,
  'cadetblue': 0xFF5F9EA0,
  'chartreuse': 0xFF7FFF00,
  'chocolate': 0xFFD2691E,
  'coral': 0xFFFF7F50,
  'cornflowerblue': 0xFF6495ED,
  'cornsilk': 0xFFFFF8DC,
  'crimson': 0xFFDC143C,
  'cyan': 0xFF00FFFF,
  'darkblue': 0xFF00008B,
  'darkcyan': 0xFF008B8B,
  'darkgoldenrod': 0xFFB8860B,
  'darkgray': 0xFFA9A9A9,
  'darkgreen': 0xFF006400,
  'darkgrey': 0xFFA9A9A9,
  'darkkhaki': 0xFFBDB76B,
  'darkmagenta': 0xFF8B008B,
  'darkolivegreen': 0xFF556B2F,
  'darkorange': 0xFFFF8C00,
  'darkorchid': 0xFF9932CC,
  'darkred': 0xFF8B0000,
  'darksalmon': 0xFFE9967A,
  'darkseagreen': 0xFF8FBC8F,
  'darkslateblue': 0xFF483D8B,
  'darkslategray': 0xFF2F4F4F,
  'darkslategrey': 0xFF2F4F4F,
  'darkturquoise': 0xFF00CED1,
  'darkviolet': 0xFF9400D3,
  'deeppink': 0xFFFF1493,
  'deepskyblue': 0xFF00BFFF,
  'dimgray': 0xFF696969,
  'dimgrey': 0xFF696969,
  'dodgerblue': 0xFF1E90FF,
  'firebrick': 0xFFB22222,
  'floralwhite': 0xFFFFFAF0,
  'forestgreen': 0xFF228B22,
  'fuchsia': 0xFFFF00FF,
  'gainsboro': 0xFFDCDCDC,
  'ghostwhite': 0xFFF8F8FF,
  'gold': 0xFFFFD700,
  'goldenrod': 0xFFDAA520,
  'gray': 0xFF808080,
  'green': 0xFF008000,
  'greenyellow': 0xFFADFF2F,
  'grey': 0xFF808080,
  'honeydew': 0xFFF0FFF0,
  'hotpink': 0xFFFF69B4,
  'indianred': 0xFFCD5C5C,
  'indigo': 0xFF4B0082,
  'ivory': 0xFFFFFFF0,
  'khaki': 0xFFF0E68C,
  'lavender': 0xFFE6E6FA,
  'lavenderblush': 0xFFFFF0F5,
  'lawngreen': 0xFF7CFC00,
  'lemonchiffon': 0xFFFFFACD,
  'lightblue': 0xFFADD8E6,
  'lightcoral': 0xFFF08080,
  'lightcyan': 0xFFE0FFFF,
  'lightgoldenrodyellow': 0xFFFAFAD2,
  'lightgray': 0xFFD3D3D3,
  'lightgreen': 0xFF90EE90,
  'lightgrey': 0xFFD3D3D3,
  'lightpink': 0xFFFFB6C1,
  'lightsalmon': 0xFFFFA07A,
  'lightseagreen': 0xFF20B2AA,
  'lightskyblue': 0xFF87CEFA,
  'lightslategray': 0xFF778899,
  'lightslategrey': 0xFF778899,
  'lightsteelblue': 0xFFB0C4DE,
  'lightyellow': 0xFFFFFFE0,
  'lime': 0xFF00FF00,
  'limegreen': 0xFF32CD32,
  'linen': 0xFFFAF0E6,
  'magenta': 0xFFFF00FF,
  'maroon': 0xFF800000,
  'mediumaquamarine': 0xFF66CDAA,
  'mediumblue': 0xFF0000CD,
  'mediumorchid': 0xFFBA55D3,
  'mediumpurple': 0xFF9370DB,
  'mediumseagreen': 0xFF3CB371,
  'mediumslateblue': 0xFF7B68EE,
  'mediumspringgreen': 0xFF00FA9A,
  'mediumturquoise': 0xFF48D1CC,
  'mediumvioletred': 0xFFC71585,
  'midnightblue': 0xFF191970,
  'mintcream': 0xFFF5FFFA,
  'mistyrose': 0xFFFFE4E1,
  'moccasin': 0xFFFFE4B5,
  'navajowhite': 0xFFFFDEAD,
  'navy': 0xFF000080,
  'oldlace': 0xFFFDF5E6,
  'olive': 0xFF808000,
  'olivedrab': 0xFF6B8E23,
  'orange': 0xFFFFA500,
  'orangered': 0xFFFF4500,
  'orchid': 0xFFDA70D6,
  'palegoldenrod': 0xFFEEE8AA,
  'palegreen': 0xFF98FB98,
  'paleturquoise': 0xFFAFEEEE,
  'palevioletred': 0xFFDB7093,
  'papayawhip': 0xFFFFEFD5,
  'peachpuff': 0xFFFFDAB9,
  'peru': 0xFFCD853F,
  'pink': 0xFFFFC0CB,
  'plum': 0xFFDDA0DD,
  'powderblue': 0xFFB0E0E6,
  'purple': 0xFF800080,
  'rebeccapurple': 0xFF663399,
  'red': 0xFFFF0000,
  'rosybrown': 0xFFBC8F8F,
  'royalblue': 0xFF4169E1,
  'saddlebrown': 0xFF8B4513,
  'salmon': 0xFFFA8072,
  'sandybrown': 0xFFF4A460,
  'seagreen': 0xFF2E8B57,
  'seashell': 0xFFFFF5EE,
  'sienna': 0xFFA0522D,
  'silver': 0xFFC0C0C0,
  'skyblue': 0xFF87CEEB,
  'slateblue': 0xFF6A5ACD,
  'slategray': 0xFF708090,
  'slategrey': 0xFF708090,
  'snow': 0xFFFFFAFA,
  'springgreen': 0xFF00FF7F,
  'steelblue': 0xFF4682B4,
  'tan': 0xFFD2B48C,
  'teal': 0xFF008080,
  'thistle': 0xFFD8BFD8,
  'tomato': 0xFFFF6347,
  'turquoise': 0xFF40E0D0,
  'violet': 0xFFEE82EE,
  'wheat': 0xFFF5DEB3,
  'white': 0xFFFFFFFF,
  'whitesmoke': 0xFFF5F5F5,
  'yellow': 0xFFFFFF00,
  'yellowgreen': 0xFF9ACD32
};
