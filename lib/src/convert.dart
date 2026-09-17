import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'build.dart';
import 'contour.dart';
import 'gif.dart';
import 'lottie.dart';
import 'model.dart';
import 'raster.dart';
import 'verify.dart';
import 'write.dart';

class Generated {
  Generated(this.drawable, this.files, this.qualityDp,
      {this.avd, this.unsupported = const {}, this.timeScale = 1});

  /// The drawable that was written, whichever front end produced it.
  final Drawable drawable;

  /// Set when the artwork came from a GIF: what the tracer measured.
  final Avd? avd;

  /// Features of the source this converter does not reproduce.
  final Set<String> unsupported;

  /// The tolerance the run settled on, in dp. With a morph budget in force
  /// this is the finest the drawable could be and still fit it. Zero when the
  /// source was already vector and nothing had to be approximated.
  final double qualityDp;

  /// How far the animation's own length was stretched to reach the length that
  /// was asked for. One when it plays at its own speed.
  final double timeScale;

  /// Resource files, keyed by path relative to `res/`.
  final Map<String, String> files;

  int get bytes => files.values.fold(0, (a, f) => a + f.length);
}

/// Traces [gifBytes] and renders the resources, without touching the disk.
///
/// With [Options.maxMorphSegments] in force the tolerances are searched rather
/// than taken as given: the GIF is traced once, then re-fitted at finer and
/// finer tolerances, and the finest fit that still stays inside the morph
/// budget wins. Accuracy is spent right up to the point where the renderer
/// would start to feel it, and no further.
Generated generate(Uint8List gifBytes, {Options options = const Options()}) {
  final traced = Traced.of(decodeGif(gifBytes), options);
  var quality = options.curveTolerance;
  var avd = assemble(traced, options);
  if (options.maxMorphSegments > 0) {
    const finest = 0.02, coarsest = 0.6;
    var low = finest, high = coarsest;
    Avd? best;
    var bestQuality = coarsest;
    // Bisect on the one tolerance dial: smaller is more accurate and more
    // work, so keep the smallest value whose load fits.
    for (var step = 0; step < 7; step++) {
      final middle = step == 0 ? finest : (low + high) / 2;
      final candidate = assemble(traced, options.atQuality(middle));
      if (candidate.drawable.morphLoad <= options.maxMorphSegments) {
        best = candidate;
        bestQuality = middle;
        if (step == 0) break; // nothing is more accurate than the finest fit
        high = middle;
      } else {
        low = middle;
      }
    }
    avd = best ?? assemble(traced, options.atQuality(coarsest));
    quality = best == null ? coarsest : bestQuality;
  }
  final played = avd.drawable;
  final drawable = played.retimed(options.durationMs ?? played.durationMs);
  return Generated(drawable, render(drawable), quality,
      avd: avd, timeScale: drawable.durationMs / played.durationMs);
}

/// Converts a Lottie animation, structure for structure. Nothing is traced and
/// nothing is fitted, so a file whose features Android can express converts
/// exactly - which no raster source can.
Generated convertLottie(Uint8List jsonBytes, {Options options = const Options()}) {
  final lottie = Lottie.parse(jsonBytes);
  final played = lottie.toDrawable(options.name, options.canvasDp, options.safeRadiusDp);
  final drawable = played.retimed(options.durationMs ?? played.durationMs);
  return Generated(drawable, render(drawable), 0,
      unsupported: lottie.unsupported, timeScale: drawable.durationMs / played.durationMs);
}

/// Replays the generated XML against the GIF frames it came from.
Report check(Generated generated) {
  final avd = generated.avd;
  if (avd == null) throw StateError('this drawable did not come from a GIF');
  final width = avd.gif.width, height = avd.gif.height;
  final scale = avd.scale, offset = avd.offset;
  // The contours were traced during the build, in canvas dp; reading them back
  // is the same work as tracing the frames again, without doing it twice.
  Point toPixels(Point p) => Point((p.x - offset.x) / scale, (p.y - offset.y) / scale);

  final masks = <Uint8List>[];
  final contours = <List<Point>>[];
  var ceiling = 0.0;
  for (var f = 0; f < avd.frameIndices.length; f++) {
    final mask = Uint8List(width * height);
    final ideal = Uint8List(width * height);
    final outline = <Point>[];
    for (var l = 0; l < avd.separation.layers.length; l++) {
      final field = avd.separation.layers[l].fields[avd.frameIndices[f]];
      for (var i = 0; i < mask.length; i++) {
        if (field[i] > 0.5) mask[i] = 1;
      }
      for (final shape in avd.traced.shapes[l][f]) {
        final loops = [
          for (final loop in [shape.outer, ...shape.holes]) [for (final p in loop) toPixels(p)],
        ];
        for (final loop in loops) {
          outline.addAll(loop);
        }
        // What the GIF's own contours score when rasterised straight back: the
        // ceiling for anything made of outlines rather than whole pixels.
        final painted = rasterise(loops, width, height);
        for (var i = 0; i < ideal.length; i++) {
          if (painted[i] != 0) ideal[i] = 1;
        }
      }
    }
    masks.add(mask);
    contours.add(outline);
    ceiling += iou(ideal, mask);
  }
  final scaled = [for (final t in avd.frameTimes) (t * generated.timeScale).round()];
  return verify(generated.files, masks, contours, ceiling / masks.length, scaled,
      generated.drawable.durationMs, width, height, scale, offset);
}

/// Writes the resources under [resDir], creating `drawable/`, `animator/`,
/// `interpolator/` and the `values/` folders as needed. Returns the paths
/// written.
List<String> write(Generated generated, String resDir) {
  final written = <String>[];
  generated.files.forEach((relative, content) {
    final file = File(p.join(resDir, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    written.add(file.path);
  });
  written.sort();
  return written;
}

/// Replays the generated XML against the animation it was converted from.
///
/// Both sides are vector here, so there is no pixel ceiling to fall short of:
/// anything below 1.0000 is a conversion fault, not a limit of the format.
Report checkLottie(Generated generated, {int samplesPerSecond = 30, double pixelsPerDp = 2}) {
  final drawable = generated.drawable;
  final size = (drawable.canvasDp * pixelsPerDp).round();
  final times = <int>[];
  final step = (1000 / samplesPerSecond).round();
  for (var t = 0; t <= drawable.durationMs; t += step) {
    times.add(t);
  }
  if (times.last != drawable.durationMs) times.add(drawable.durationMs);

  final masks = <Uint8List>[];
  final contours = <List<Point>>[];
  for (final t in times) {
    final mask = Uint8List(size * size);
    final outline = <Point>[];
    for (final path in drawable.at(t)) {
      List<List<Point>> scaled(List<List<Point>> loops) => [
            for (final loop in loops)
              [for (final p in loop) Point(p.x * pixelsPerDp, p.y * pixelsPerDp)],
          ];
      final loops = scaled(path.loops);
      for (final loop in loops) {
        outline.addAll(loop);
      }
      final painted = rasterise(loops, size, size);
      for (final clip in path.clips) {
        // Non-zero because that is the only rule a `<clip-path>` has.
        final allowed = rasterise(scaled(clip), size, size, nonZero: true);
        for (var i = 0; i < painted.length; i++) {
          if (allowed[i] == 0) painted[i] = 0;
        }
      }
      for (var i = 0; i < mask.length; i++) {
        if (painted[i] != 0) mask[i] = 1;
      }
    }
    masks.add(mask);
    contours.add(outline);
  }
  return verify(generated.files, masks, contours, 1, times, drawable.durationMs, size, size,
      1 / pixelsPerDp, const Point(0, 0));
}

/// Finds the `res` directory of a Flutter or Android project.
String? findResDir(String root) {
  for (final candidate in const [
    'android/app/src/main/res',
    'app/src/main/res',
    'src/main/res',
    'res',
  ]) {
    final dir = Directory(p.join(root, candidate));
    if (dir.existsSync()) return dir.path;
  }
  return null;
}
