import 'dart:async';
import 'dart:io';

import 'package:android_avd_splash/android_avd_splash.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

final _parser = ArgParser()
  ..addOption('out', abbr: 'o', help: 'Android res directory to write into.')
  ..addOption('project', help: 'Project root; its res directory is found for you.')
  ..addOption('name', abbr: 'n', help: 'Resource name stem (default: the GIF file name).')
  ..addOption('canvas', defaultsTo: '288', help: 'Drawable size in dp.')
  ..addOption('safe', defaultsTo: '96', help: 'Radius in dp the artwork must stay inside.')
  ..addOption('background', help: 'Background colour override, #AARRGGBB.')
  ..addMultiOption('color', help: 'Paint colour override, #AARRGGBB. Repeatable, front to back.')
  ..addOption('smooth', help: 'Blur in pixels before tracing, GIF only (default: auto).')
  ..addOption('max-morph',
      defaultsTo: '400',
      help: 'Morphing Bezier segments allowed per frame; tolerances are tuned to fit. 0 lifts it.')
  ..addOption('curve-tolerance', defaultsTo: '0.15', help: 'Outline fit budget, in rendered dp.')
  ..addOption('rigid-tolerance', defaultsTo: '0.4', help: 'Rigid-motion budget, in rendered dp.')
  ..addOption('keyframe-tolerance', defaultsTo: '0.15', help: 'Keyframe drop budget, in dp.')
  ..addOption('min-area', defaultsTo: '2.0', help: 'Drop regions smaller than this, in dp squared.')
  ..addOption('min-thickness', defaultsTo: '0.4', help: 'Drop regions thinner than this, in dp.')
  ..addFlag('trim', defaultsTo: true, help: 'Drop blank lead-in and the static tail.')
  ..addFlag('gradients', defaultsTo: true, help: 'Fill a path with a gradient when it needs one.')
  ..addFlag('verify', defaultsTo: true, help: 'Replay the written XML against the GIF.')
  ..addFlag('dry-run', help: 'Report only; write nothing.')
  ..addFlag('help', abbr: 'h', negatable: false);

void main(List<String> arguments) {
  // Writing to a closed pipe (`avdgen … | head`) must not look like a crash,
  // and stdout reports that failure asynchronously.
  runZonedGuarded(() => _run(arguments), (error, stack) {
    if (error is FileSystemException) exit(0);
    Error.throwWithStackTrace(error, stack);
  });
}

void _say(String line) => stdout.writeln(line);

void _run(List<String> arguments) {
  final ArgResults args;
  try {
    args = _parser.parse(arguments);
  } on FormatException catch (e) {
    _fail(e.message);
  }
  if (args['help'] as bool || args.rest.length != 1) {
    _say('Usage: avdgen <animation.json|animation.gif> [--out <res>|--project <dir>]\n');
    _say(_parser.usage);
    exit(args['help'] as bool ? 0 : 64);
  }

  final source = File(args.rest.single);
  if (!source.existsSync()) _fail('no such file: ${source.path}');
  final isLottie = p.extension(source.path).toLowerCase() == '.json';

  final options = Options(
    name: _resourceName(args['name'] as String? ?? p.basenameWithoutExtension(source.path)),
    canvasDp: _number(args, 'canvas'),
    safeRadiusDp: _number(args, 'safe'),
    curveTolerance: _number(args, 'curve-tolerance'),
    rigidTolerance: _number(args, 'rigid-tolerance'),
    keyframeTolerance: _number(args, 'keyframe-tolerance'),
    maxMorphSegments: _number(args, 'max-morph').round(),
    minAreaDp: _number(args, 'min-area'),
    minThicknessDp: _number(args, 'min-thickness'),
    smooth: args['smooth'] == null ? null : _number(args, 'smooth'),
    trim: args['trim'] as bool,
    gradients: args['gradients'] as bool,
    background: _colour(args['background'] as String?),
    colors: (args['color'] as List<String>).isEmpty
        ? null
        : [for (final c in args['color'] as List<String>) _colour(c)!],
  );

  final Generated generated;
  try {
    final bytes = source.readAsBytesSync();
    generated =
        isLottie ? convertLottie(bytes, options: options) : generate(bytes, options: options);
  } on FormatException catch (e) {
    _fail('${source.path}: ${e.message}');
  } on StateError catch (e) {
    _fail('${source.path}: ${e.message}');
  }
  final drawable = generated.drawable;
  final avd = generated.avd;
  if (avd != null) {
    _say('${p.basename(source.path)}: ${avd.gif.width}x${avd.gif.height}, '
        '${avd.gif.frames.length} frames, ${avd.gif.durationMs} ms');
  } else {
    _say('${p.basename(source.path)}: Lottie, ${drawable.durationMs} ms');
  }
  _say('${options.name}: ${drawable.durationMs} ms, '
      '${avd == null ? '' : '${avd.frameTimes.length} source frames, '}'
      '${drawable.paths.length} ${drawable.paths.length == 1 ? 'path' : 'paths'} '
      '(${drawable.morphingPaths} morphing'
      '${drawable.paths.where((s) => s.paint.gradient != null).isEmpty ? '' : ', '
          '${drawable.paths.where((s) => s.paint.gradient != null).length} with gradients'}), '
      '${(generated.bytes / 1024).toStringAsFixed(1)} KiB');
  if (generated.unsupported.isNotEmpty) {
    _say('not converted: ${generated.unsupported.join(', ')}');
    exitCode = 1;
  }

  if (args['verify'] as bool) {
    final report = avd == null ? checkLottie(generated) : check(generated);
    _say('edge: mean ${report.meanDeviationDp.toStringAsFixed(3)}dp off the source outline, '
        '95% within ${report.typicalDeviationDp.toStringAsFixed(2)}dp, '
        'worst ${report.worstDeviationDp.toStringAsFixed(2)}dp');
    _say('pixels: overlap ${report.meanTolerant.toStringAsFixed(4)}, '
        'strict ${report.meanExact.toStringAsFixed(4)} of a '
        '${report.ceiling.toStringAsFixed(4)} ceiling '
        '= ${(report.ofCeiling * 100).toStringAsFixed(1)}% of what '
        '${avd == null ? 'the source asks for' : 'outlines can reach'}');
    _say('bounds: reaches ${report.maxRadiusDp.toStringAsFixed(1)}dp of the '
        '${report.safeRadiusDp.toStringAsFixed(0)}dp safe radius'
        '${report.insideSafeArea ? '' : ' - CLIPPED'}');
    if (!report.morphable) _say('morph: INCOMPATIBLE path structure');
    if (!report.insideSafeArea || !report.morphable) exitCode = 1;
  }

  _say('load: ${drawable.segments} Bezier segments, ${drawable.morphLoad} of them morphing '
      'every frame'
      '${options.maxMorphSegments > 0 && avd != null ? ' of ${options.maxMorphSegments} allowed' : ''}'
      '${avd != null && avd.droppedRegions > 0 ? ', ${avd.droppedRegions} invisible regions dropped' : ''}');
  if (options.maxMorphSegments > 0 && avd != null) {
    _say('quality: outlines held to ${generated.qualityDp.toStringAsFixed(2)}dp '
        '(tuned to the budget; --max-morph 0 to spend more)');
  }

  if (args['dry-run'] as bool) return;
  final res = args['out'] as String? ??
      (args['project'] == null ? null : findResDir(args['project'] as String)) ??
      findResDir(Directory.current.path);
  if (res == null) _fail('no res directory found; pass --out or --project');
  for (final file in write(generated, res)) {
    final shown = p.relative(file);
    _say('wrote ${shown.startsWith('..') ? file : shown}');
  }
}

String _resourceName(String raw) {
  final clean =
      raw.toLowerCase().replaceAll(RegExp('[^a-z0-9_]'), '_').replaceAll(RegExp('_+'), '_');
  final trimmed = clean.replaceAll(RegExp('^_+|_+\$'), '');
  return trimmed.isEmpty || !RegExp('^[a-z]').hasMatch(trimmed) ? 'avd_$trimmed' : trimmed;
}

double _number(ArgResults args, String option) {
  final value = double.tryParse(args[option] as String);
  if (value == null) _fail('--$option needs a number, got "${args[option]}"');
  return value;
}

int? _colour(String? raw) {
  if (raw == null) return null;
  final hex = raw.replaceFirst('#', '');
  final value = int.tryParse(hex, radix: 16);
  if (value == null || (hex.length != 6 && hex.length != 8)) {
    _fail('colours look like #RRGGBB or #AARRGGBB, got "$raw"');
  }
  return hex.length == 6 ? 0xFF000000 | value : value;
}

Never _fail(String message) {
  stderr.writeln('avdgen: $message');
  exit(64);
}
