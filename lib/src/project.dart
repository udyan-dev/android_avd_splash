import 'dart:io';

import 'package:path/path.dart' as p;

import 'integration.dart';

/// The Android module of a Flutter or Android project: the four places the
/// generator has to touch, found once and validated before anything is written.
class AndroidProject {
  AndroidProject._(this.root, this.module, this.manifest, this.activity, this.activityPackage);

  /// Locates the module inside [root], where [androidDir] is the Android
  /// directory relative to it - `android` in a Flutter project.
  ///
  /// Throws [ProjectError] naming what is missing, because every one of these
  /// is a project that has not been set up rather than a bug.
  factory AndroidProject.find(String root, String androidDir) {
    final android = Directory(p.join(root, androidDir));
    if (!android.existsSync()) {
      throw ProjectError('no ${p.join(root, androidDir)} - '
          'run this from the project root, or set `android_dir:`');
    }
    final module = [
      p.join(android.path, 'app'),
      android.path,
    ].firstWhere((dir) => File(p.join(dir, 'src', 'main', 'AndroidManifest.xml')).existsSync(),
        orElse: () => throw ProjectError('no src/main/AndroidManifest.xml under ${android.path}'));

    final manifest = File(p.join(module, 'src', 'main', 'AndroidManifest.xml'));
    final activity = _activity(module, manifest.readAsStringSync());
    return AndroidProject._(root, module, manifest, activity,
        activity == null ? null : _packageOf(activity.readAsStringSync()));
  }

  /// Project root, as given.
  final String root;

  /// The Gradle module that owns the resources: `android/app` in Flutter.
  final String module;

  /// The manifest whose launcher activity names the splash theme.
  final File manifest;

  /// The launcher activity's source file, when it could be found.
  final File? activity;

  /// The package that activity declares, which is also the package the
  /// generated helper must join to see `R`.
  final String? activityPackage;

  /// Where resources go.
  String get res => p.join(module, 'src', 'main', 'res');

  /// True when the activity is Kotlin rather than Java.
  bool get kotlin => p.extension(activity?.path ?? '.kt') == '.kt';

  /// The file the generated helper is written to, beside the activity.
  File? get helper {
    final source = activity;
    return source == null
        ? null
        : File(p.join(source.parent.path, splashSourceName(kotlin: kotlin)));
  }

  /// The launcher activity's class, from the manifest: `.MainActivity` or a
  /// fully qualified name.
  static File? _activity(String module, String manifest) {
    final name =
        RegExp(r'android:name\s*=\s*"([^"]*Activity[^"]*)"').firstMatch(manifest)?.group(1);
    final simple = name == null ? 'MainActivity' : name.split('.').last;
    for (final language in const ['kotlin', 'java']) {
      final dir = Directory(p.join(module, 'src', 'main', language));
      if (!dir.existsSync()) continue;
      for (final entry in dir.listSync(recursive: true).whereType<File>()) {
        final base = p.basenameWithoutExtension(entry.path);
        if (base == simple && const ['.kt', '.java'].contains(p.extension(entry.path))) {
          return entry;
        }
      }
    }
    return null;
  }

  static String? _packageOf(String source) =>
      RegExp(r'^package\s+([\w.]+)', multiLine: true).firstMatch(source)?.group(1);
}

/// A project the generator cannot act on. The message names the missing piece.
class ProjectError implements Exception {
  ProjectError(this.message);

  final String message;

  @override
  String toString() => message;
}
