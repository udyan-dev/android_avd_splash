import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'build.dart';

/// Name of the configuration file read from the project root.
const configFileName = 'android_avd_splash.yaml';

/// What kind of animation the source is, which decides how it is converted:
/// the two vector forms are rebuilt structurally, a GIF has to be traced.
enum SourceKind { lottie, svg, gif }

/// Everything `create` needs, as read from [configFileName].
///
/// Every field has a default that satisfies the platform's splash screen
/// guidelines, so a usable file is one line long:
///
/// ```yaml
/// android_avd_splash:
///   source: assets/splash.json
/// ```
class SplashConfig {
  SplashConfig({
    required this.source,
    this.name = 'splash',
    this.background,
    this.backgroundNight,
    this.iconBackground,
    this.durationMs,
    this.canvasDp = 288,
    this.safeRadiusDp = 96,
    this.maxMorphSegments = 400,
    this.gradients = true,
    this.trim = true,
    this.smooth,
    this.colors = const [],
    this.androidDir = 'android',
    this.patchManifest = true,
    this.patchActivity = true,
    this.iconPreferred = true,
    this.verify = true,
  });

  /// Reads [configFileName] from [root], or [file] when given.
  factory SplashConfig.read(String root, {String? file}) {
    final path = file ?? p.join(root, configFileName);
    final handle = File(path);
    if (!handle.existsSync()) {
      throw ConfigError('no $configFileName in ${p.absolute(root)} - '
          'write one, or pass --config');
    }
    final document = loadYaml(handle.readAsStringSync());
    if (document is! Map || document[_section] is! Map) {
      throw ConfigError('$path has no `$_section:` section');
    }
    return SplashConfig.fromMap(
        {for (final e in (document[_section] as Map).entries) e.key.toString(): e.value});
  }

  /// Builds a configuration from the `android_avd_splash:` mapping itself.
  factory SplashConfig.fromMap(Map<String, dynamic> yaml) {
    const known = {
      'source', 'name', 'background', 'background_night', 'icon_background', 'duration_ms',
      'canvas_dp', 'safe_radius_dp', 'max_morph', 'gradients', 'trim', 'smooth', 'colors',
      'android_dir', 'patch_manifest', 'patch_activity', 'icon_preferred', 'verify', //
    };
    final unknown = yaml.keys.where((key) => !known.contains(key));
    if (unknown.isNotEmpty) {
      throw ConfigError('unknown option${unknown.length > 1 ? 's' : ''}: ${unknown.join(', ')}');
    }
    final source = yaml['source'];
    if (source is! String || source.isEmpty) {
      throw ConfigError('`source:` is required - the .json, .svg or .gif to convert');
    }
    final name = _string(yaml, 'name') ?? 'splash';
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
      throw ConfigError('`name: $name` is not a resource name - '
          'lower case, digits and underscores, starting with a letter');
    }
    final duration = _int(yaml, 'duration_ms');
    if (duration != null && duration <= 0) throw ConfigError('`duration_ms:` must be positive');
    return SplashConfig(
      source: source,
      name: name,
      background: _colour(yaml, 'background'),
      backgroundNight: _colour(yaml, 'background_night'),
      iconBackground: _colour(yaml, 'icon_background'),
      durationMs: duration,
      canvasDp: _double(yaml, 'canvas_dp') ?? 288,
      safeRadiusDp: _double(yaml, 'safe_radius_dp') ?? 96,
      maxMorphSegments: _int(yaml, 'max_morph') ?? 400,
      gradients: _bool(yaml, 'gradients') ?? true,
      trim: _bool(yaml, 'trim') ?? true,
      smooth: _double(yaml, 'smooth'),
      colors: [
        for (final value in (yaml['colors'] as YamlList? ?? const []))
          _parseColour('colors', value.toString()),
      ],
      androidDir: _string(yaml, 'android_dir') ?? 'android',
      patchManifest: _bool(yaml, 'patch_manifest') ?? true,
      patchActivity: _bool(yaml, 'patch_activity') ?? true,
      iconPreferred: _bool(yaml, 'icon_preferred') ?? true,
      verify: _bool(yaml, 'verify') ?? true,
    );
  }

  static const _section = 'android_avd_splash';

  /// The animation to convert, relative to the project root: `.json` for
  /// Lottie, `.svg` for an animated SVG, `.gif` for an animated GIF.
  final String source;

  /// Resource name stem: the drawable becomes `@drawable/<name>`.
  final String name;

  /// Splash background, as `0xAARRGGBB`. The platform requires one opaque
  /// colour, which is also what the window shows before API 31. Left out, a
  /// GIF's own background colour is used and a vector source gets white.
  final int? background;

  /// Background under `values-night`. Left out, night uses [background].
  final int? backgroundNight;

  /// Optional circle behind the icon, for contrast against the background.
  final int? iconBackground;

  /// Overrides the animation's own length, in milliseconds.
  final int? durationMs;

  /// Drawable canvas in dp. The platform masks the outer third of it.
  final double canvasDp;

  /// How far from the centre the artwork may reach, in dp.
  final double safeRadiusDp;

  /// Morphing Bezier segments allowed per frame. Zero lifts the budget.
  final int maxMorphSegments;

  /// Whether a region may be filled with a gradient.
  final bool gradients;

  /// Whether to drop a blank lead-in and a static tail.
  final bool trim;

  /// Blur in source pixels before tracing a GIF. Null measures the artwork.
  final double? smooth;

  /// Paint colours to use instead of the GIF's own, front to back.
  final List<int> colors;

  /// The Android module inside the project.
  final String androidDir;

  /// Whether to point the launcher activity's theme at the generated one.
  final bool patchManifest;

  /// Whether to write the splash handover into the activity.
  final bool patchActivity;

  /// Whether to ask Android 13+ to show the icon even when the app is opened
  /// from a shortcut or a notification.
  final bool iconPreferred;

  /// Whether to replay the written XML against the source and report.
  final bool verify;

  /// What the source is, from its extension.
  SourceKind get kind => switch (p.extension(source).toLowerCase()) {
        '.json' => SourceKind.lottie,
        '.svg' => SourceKind.svg,
        _ => SourceKind.gif,
      };

  /// True when the source is a Lottie animation.
  bool get isLottie => kind == SourceKind.lottie;

  /// True when the source is vector in as well as vector out, and so converts
  /// exactly rather than being traced.
  bool get isVector => kind != SourceKind.gif;

  /// The safe radius the platform actually allows: two thirds of the canvas,
  /// halved, which is the 192dp circle in a 288dp icon and the 160dp circle in
  /// a 240dp one.
  double get platformSafeRadiusDp => canvasDp / 3;

  /// The tracer and emitter options this configuration implies.
  Options toOptions() => Options(
        name: name,
        canvasDp: canvasDp,
        safeRadiusDp: safeRadiusDp,
        maxMorphSegments: maxMorphSegments,
        gradients: gradients,
        trim: trim,
        smooth: smooth,
        colors: colors.isEmpty ? null : colors,
        durationMs: durationMs,
      );

  static String? _string(Map<String, dynamic> yaml, String key) {
    final value = yaml[key];
    if (value == null) return null;
    if (value is! String) throw ConfigError('`$key:` must be text');
    return value;
  }

  static bool? _bool(Map<String, dynamic> yaml, String key) {
    final value = yaml[key];
    if (value == null) return null;
    if (value is! bool) throw ConfigError('`$key:` must be true or false');
    return value;
  }

  static int? _int(Map<String, dynamic> yaml, String key) {
    final value = yaml[key];
    if (value == null) return null;
    if (value is! int) throw ConfigError('`$key:` must be a whole number');
    return value;
  }

  static double? _double(Map<String, dynamic> yaml, String key) {
    final value = yaml[key];
    if (value == null) return null;
    if (value is! num) throw ConfigError('`$key:` must be a number');
    return value.toDouble();
  }

  static int? _colour(Map<String, dynamic> yaml, String key) {
    final value = _string(yaml, key);
    return value == null ? null : _parseColour(key, value);
  }

  /// `#RRGGBB` or `#AARRGGBB`, the form Android resource files use.
  static int _parseColour(String key, String value) {
    final digits = value.startsWith('#') ? value.substring(1) : value;
    final parsed = int.tryParse(digits, radix: 16);
    if (parsed == null || (digits.length != 6 && digits.length != 8)) {
      throw ConfigError('`$key: $value` is not a colour - use #RRGGBB or #AARRGGBB');
    }
    return digits.length == 6 ? 0xFF000000 | parsed : parsed;
  }
}

/// A configuration file that cannot be acted on. The message is written for
/// the person who has to fix the file.
class ConfigError implements Exception {
  ConfigError(this.message);

  final String message;

  @override
  String toString() => message;
}
