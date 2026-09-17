import 'dart:async';
import 'dart:io';

import 'package:android_avd_splash/android_avd_splash.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('project', abbr: 'p', defaultsTo: '.', help: 'Project root.')
    ..addOption('config', abbr: 'c', help: 'Configuration file (default: $configFileName).')
    ..addFlag('dry-run', help: 'Report what would be written, and write nothing.', negatable: false)
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln('create: ${error.message}');
    exitCode = 64;
    return;
  }
  if (options['help'] as bool) {
    stdout.writeln('Usage: dart run android_avd_splash:create [options]\n\n'
        '${parser.usage}\n\n'
        'Reads $configFileName from the project root and writes the splash screen.');
    return;
  }

  // A closed pipe is not a failure: `create | head` must not print a crash.
  await runZonedGuarded(() async {
    try {
      _run(options);
    } on ConfigError catch (error) {
      stderr.writeln('create: $error');
      exitCode = 78;
    } on ProjectError catch (error) {
      stderr.writeln('create: $error');
      exitCode = 78;
    } on StateError catch (error) {
      stderr.writeln('create: ${error.message}');
      exitCode = 65;
    }
  }, (error, _) {
    if (error is! StdoutException && error is! SocketException) throw error;
  });
}

void _run(ArgResults options) {
  final root = options['project'] as String;
  final config = SplashConfig.read(root, file: options['config'] as String?);
  final dryRun = options['dry-run'] as bool;
  final result = createSplash(config, root: root, dryRun: dryRun);
  final drawable = result.generated.drawable;
  final report = result.report;

  stdout.writeln('${config.source} -> @drawable/${config.name} '
      '(${drawable.source}, ${result.durationMs} ms)');
  stdout.writeln('  ${drawable.paths.length} paths, '
      '${_kib(result.generated.bytes)}, '
      '${drawable.morphLoad} morphing Bezier segments per frame');
  if (report != null) {
    stdout.writeln('  accuracy ${(report.ofCeiling * 100).toStringAsFixed(1)}% of a '
        '${report.ceiling.toStringAsFixed(4)} ceiling, '
        'outline within ${report.typicalDeviationDp.toStringAsFixed(2)}dp');
  }
  stdout.writeln('  icon reaches ${report == null ? '?' : report.maxRadiusDp.toStringAsFixed(1)}'
      'dp of the ${config.platformSafeRadiusDp.toStringAsFixed(0)}dp the platform shows');

  for (final path in result.removed) {
    stdout.writeln('  removed ${p.relative(path, from: root)}');
  }
  stdout.writeln(dryRun
      ? '  ${result.written.length} files would be written'
      : '  ${result.written.length} files written');
  for (final warning in result.warnings) {
    stdout.writeln('  ! $warning');
  }

  final theme = '@style/${result.theme}';
  stdout.writeln('\nLauncher activity theme: $theme'
      '${config.patchManifest ? ' (set in AndroidManifest.xml)' : ' - set it yourself'}');
  if (config.patchActivity && result.project.activity != null) {
    stdout.writeln('Handover: AvdSplash.install(this) in '
        '${p.basename(result.project.activity!.path)}, '
        'beside ${p.basename(result.project.helper!.path)}');
  }
  if (result.warnings.any((w) => w.startsWith('not converted'))) exitCode = 1;
}

String _kib(int bytes) => '${(bytes / 1024).toStringAsFixed(1)} KiB';
