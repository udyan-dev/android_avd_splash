import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'convert.dart';
import 'integration.dart';
import 'project.dart';
import 'resources.dart';
import 'stamp.dart';
import 'verify.dart';

/// What one `create` run did.
class SplashResult {
  SplashResult({
    required this.config,
    required this.project,
    required this.generated,
    required this.report,
    required this.theme,
    required this.background,
    required this.written,
    required this.removed,
    required this.warnings,
  });

  /// The configuration the run was given.
  final SplashConfig config;

  /// The module that was written into.
  final AndroidProject project;

  /// The converted drawable and its resource files.
  final Generated generated;

  /// The replay of the written XML against the source, unless it was skipped.
  final Report? report;

  /// The theme the launcher activity now uses.
  final String theme;

  /// The splash background that was written, as `0xAARRGGBB`.
  final int background;

  /// Every file written, absolute and sorted.
  final List<String> written;

  /// Resources left over from an earlier run under the same name, deleted.
  final List<String> removed;

  /// Things the person should know: guidelines the animation is outside of,
  /// and features of the source that were not converted.
  final List<String> warnings;

  /// The animation's length as written, in milliseconds.
  int get durationMs => generated.drawable.durationMs;
}

/// Converts the animation named in [config] and writes the whole splash screen
/// into the project at [root]: the drawable, its animators and interpolators,
/// the colour, dimension and theme resources, the activity helper, and the two
/// edits that connect them.
///
/// Nothing is written when [dryRun] is set, so a run can be inspected first.
SplashResult createSplash(SplashConfig config, {String root = '.', bool dryRun = false}) {
  final project = AndroidProject.find(root, config.androidDir);
  final source = File(p.join(root, config.source));
  if (!source.existsSync()) throw ConfigError('no ${source.path} - check `source:`');
  if (!config.isLottie && p.extension(config.source).toLowerCase() != '.gif') {
    throw ConfigError('${config.source} is neither a .json Lottie nor a .gif');
  }

  final bytes = source.readAsBytesSync();
  final options = config.toOptions();
  final generated =
      config.isLottie ? convertLottie(bytes, options: options) : generate(bytes, options: options);
  final report = !config.verify
      ? null
      : config.isLottie
          ? checkLottie(generated)
          : check(generated);

  final background = config.background ?? generated.avd?.separation.background ?? 0xFFFFFFFF;
  final theme = splashTheme(config.name);
  final files = {
    ...generated.files,
    ...splashResources(config, generated.drawable.durationMs, background),
  };

  final written = <String>[];
  final removed = _stale(project.res, files.keys.toSet());
  if (!dryRun) {
    for (final path in removed) {
      File(path).deleteSync();
    }
    files.forEach((relative, content) {
      final file = File(p.join(project.res, relative));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content);
      written.add(file.path);
    });
  } else {
    written.addAll(files.keys.map((relative) => p.join(project.res, relative)));
  }

  final warnings = _warnings(config, generated, report);
  written.addAll(
      _integrate(project, config, generated.drawable.durationMs, theme, warnings, dryRun: dryRun));
  written.sort();
  return SplashResult(
    config: config,
    project: project,
    generated: generated,
    report: report,
    theme: theme,
    background: background,
    written: written,
    removed: removed,
    warnings: warnings,
  );
}

/// Writes the helper, points the manifest at the theme and calls the helper
/// from the activity. Returns the files it touched.
List<String> _integrate(
  AndroidProject project,
  SplashConfig config,
  int durationMs,
  String theme,
  List<String> warnings, {
  required bool dryRun,
}) {
  final touched = <String>[];
  if (config.patchManifest) {
    try {
      final before = project.manifest.readAsStringSync();
      final after = patchManifest(before, theme);
      if (after != before) {
        if (!dryRun) project.manifest.writeAsStringSync(after);
        touched.add(project.manifest.path);
      }
    } on IntegrationError catch (error) {
      warnings.add('$error');
    }
  }

  final activity = project.activity;
  final helper = project.helper;
  if (!config.patchActivity) return touched;
  if (activity == null || helper == null || project.activityPackage == null) {
    warnings.add('no launcher activity source found under '
        '${p.join(project.module, 'src', 'main')} - add the AvdSplash call yourself, '
        'or turn off patch_activity');
    return touched;
  }

  final source = splashSource(project.activityPackage!, config, durationMs, kotlin: project.kotlin);
  if (!dryRun) helper.writeAsStringSync(source);
  touched.add(helper.path);

  try {
    final before = activity.readAsStringSync();
    final after = patchActivity(before, kotlin: project.kotlin);
    if (after != before) {
      if (!dryRun) activity.writeAsStringSync(after);
      touched.add(activity.path);
    }
  } on IntegrationError catch (error) {
    warnings.add('$error');
  }
  return touched;
}

/// Resources an earlier run wrote and this one does not.
///
/// Every generated file carries [stamp], so this finds them whatever they are
/// called - which is what makes renaming the drawable safe. Files the project
/// owns are never touched, because they do not carry it.
List<String> _stale(String res, Set<String> keep) {
  final root = Directory(res);
  if (!root.existsSync()) return const [];
  final stale = <String>[];
  for (final dir in root.listSync().whereType<Directory>()) {
    final folder = p.basename(dir.path);
    for (final file in dir.listSync().whereType<File>()) {
      if (p.extension(file.path) != '.xml') continue;
      if (keep.contains('$folder/${p.basename(file.path)}')) continue;
      if (file.readAsStringSync().contains(stamp)) stale.add(file.path);
    }
  }
  stale.sort();
  return stale;
}

/// Everything the run should say out loud: a guideline the animation is
/// outside, artwork the platform will clip, and source features that did not
/// convert.
List<String> _warnings(SplashConfig config, Generated generated, Report? report) {
  final warnings = <String>[];
  final duration = generated.drawable.durationMs;
  if (duration > 1000) {
    warnings.add('the animation runs for ${duration}ms; the platform guidelines ask for '
        '1000ms or less on phones - set `duration_ms: 1000` to play it faster');
  }
  if (config.safeRadiusDp > config.platformSafeRadiusDp) {
    warnings.add('`safe_radius_dp: ${_n(config.safeRadiusDp)}` is outside the '
        '${_n(config.platformSafeRadiusDp)}dp the platform shows of a '
        '${_n(config.canvasDp)}dp icon; the outer third is masked');
  }
  if (report != null && !report.insideSafeArea) {
    warnings.add('the artwork reaches ${_n(report.maxRadiusDp)}dp, past the '
        '${_n(config.platformSafeRadiusDp)}dp the platform shows');
  }
  if (generated.unsupported.isNotEmpty) {
    warnings.add('not converted: ${generated.unsupported.join(', ')}');
  }
  return warnings;
}

String _n(double value) => value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1);
