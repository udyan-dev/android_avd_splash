import 'dart:io';

import 'package:android_avd_splash/android_avd_splash.dart';
import 'package:android_avd_splash/src/stamp.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _manifest = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:label="demo" android:icon="@mipmap/ic_launcher">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:theme="@style/LaunchTheme">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
    </application>
</manifest>
''';

const _activity = '''
package com.example.demo

import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity()
''';

/// A Flutter project laid out the way `flutter create` leaves it.
Directory _project(String source, {String extra = ''}) {
  final root = Directory.systemTemp.createTempSync('android_avd_splash_test');
  final main = p.join(root.path, 'android', 'app', 'src', 'main');
  File(p.join(main, 'AndroidManifest.xml'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(_manifest);
  File(p.join(main, 'kotlin', 'com', 'example', 'demo', 'MainActivity.kt'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(_activity);
  File(p.join(root.path, 'assets', p.basename(source)))
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(File(source).readAsBytesSync());
  File(p.join(root.path, configFileName)).writeAsStringSync('android_avd_splash:\n'
      '  source: assets/${p.basename(source)}\n'
      '  background: "#FF102030"\n'
      '  background_night: "#FF000000"\n$extra');
  addTearDown(() => root.deleteSync(recursive: true));
  return root;
}

void main() {
  group('configuration', () {
    test('needs a source and nothing else', () {
      final config = SplashConfig.fromMap({'source': 'a.json'});
      expect(config.isLottie, isTrue);
      expect(config.name, 'splash');
      expect(config.canvasDp, 288);
      expect(config.platformSafeRadiusDp, 96, reason: 'the platform shows two thirds of the icon');
    });

    test('rejects what Android would reject', () {
      expect(() => SplashConfig.fromMap({}), throwsA(isA<ConfigError>()));
      expect(() => SplashConfig.fromMap({'source': 'a.json', 'name': 'My Splash'}),
          throwsA(isA<ConfigError>()));
      expect(() => SplashConfig.fromMap({'source': 'a.json', 'background': 'blue'}),
          throwsA(isA<ConfigError>()));
      expect(() => SplashConfig.fromMap({'source': 'a.json', 'duration_ms': 0}),
          throwsA(isA<ConfigError>()));
      expect(() => SplashConfig.fromMap({'source': 'a.json', 'duration': 500}),
          throwsA(isA<ConfigError>()),
          reason: 'a misspelled option is not silently ignored');
    });

    test('reads both colour forms', () {
      expect(SplashConfig.fromMap({'source': 'a.json', 'background': '#123456'}).background,
          0xFF123456);
      expect(SplashConfig.fromMap({'source': 'a.json', 'background': '#80123456'}).background,
          0x80123456);
    });
  });

  group('create', () {
    test('writes the drawable, the resources and the integration', () {
      final root = _project('test/fixtures/matte.json');
      final result = createSplash(SplashConfig.read(root.path), root: root.path);
      final res = p.join(root.path, 'android', 'app', 'src', 'main', 'res');

      expect(File(p.join(res, 'drawable', 'splash.xml')).existsSync(), isTrue);
      expect(File(p.join(res, 'drawable', 'splash_vector.xml')).existsSync(), isTrue);
      expect(Directory(p.join(res, 'animator')).listSync(), isNotEmpty);
      expect(File(p.join(res, 'values', 'splash.xml')).readAsStringSync(), contains('#FF102030'));
      expect(File(p.join(res, 'values-night', 'splash.xml')).readAsStringSync(),
          contains('#FF000000'));

      final v31 = File(p.join(res, 'values-v31', 'splash_styles.xml')).readAsStringSync();
      expect(v31, contains('windowSplashScreenAnimatedIcon">@drawable/splash'));
      expect(v31, contains('windowSplashScreenAnimationDuration">${result.durationMs}'));
      expect(v31, contains('name="Theme.Splash"'));
      final v33 = File(p.join(res, 'values-v33', 'splash_styles.xml')).readAsStringSync();
      expect(v33, contains('windowSplashScreenBehavior">icon_preferred'));
      // A style never merges across configurations, so each one has to be whole.
      expect(v33, contains('windowSplashScreenAnimatedIcon'));
      expect(File(p.join(res, 'values', 'splash_styles.xml')).readAsStringSync(),
          isNot(contains('windowSplashScreen')),
          reason: 'below API 31 the theme only paints the window');

      final manifest =
          File(p.join(root.path, 'android/app/src/main/AndroidManifest.xml')).readAsStringSync();
      expect(manifest, contains('android:theme="@style/${result.theme}"'));
      expect(manifest, contains('android:launchMode="singleTop"'), reason: 'nothing else moved');

      final activity =
          File(p.join(root.path, 'android/app/src/main/kotlin/com/example/demo/MainActivity.kt'))
              .readAsStringSync();
      expect(activity, contains('AvdSplash.install(this)'));
      expect(activity, contains('import android.os.Bundle'));
      expect(activity, contains('override fun onCreate'));
      final helper =
          File(p.join(root.path, 'android/app/src/main/kotlin/com/example/demo/AvdSplash.kt'))
              .readAsStringSync();
      expect(helper, contains('package com.example.demo'));
      expect(helper, contains('R.drawable.splash'));
      expect(helper, contains('${result.durationMs}L'));
    });

    test('is idempotent, and clears what an earlier run left behind', () {
      final root = _project('test/fixtures/matte.json');
      final config = SplashConfig.read(root.path);
      final first = createSplash(config, root: root.path);
      final activity =
          File(p.join(root.path, 'android/app/src/main/kotlin/com/example/demo/MainActivity.kt'));
      final once = activity.readAsStringSync();

      final res = p.join(root.path, 'android/app/src/main/res');
      final orphan = File(p.join(res, 'animator', 'splash_gone.xml'))
        ..writeAsStringSync('$stamp\n<set/>');
      final theirs = File(p.join(res, 'values', 'strings.xml'))..writeAsStringSync('<resources/>');
      final second = createSplash(config, root: root.path);

      expect(activity.readAsStringSync(), once,
          reason: 'the marked block is replaced, not stacked');
      expect(orphan.existsSync(), isFalse);
      expect(second.removed, contains(orphan.path));
      expect(theirs.existsSync(), isTrue, reason: 'files the project owns carry no stamp');
      bool resource(String path) => path.contains('${p.separator}res${p.separator}');
      expect(second.written.where(resource).length, first.written.where(resource).length);
      expect(second.written, isNot(contains(activity.path)),
          reason: 'an activity that is already wired is left alone');
    });

    test('clears the resources of an earlier name', () {
      final root = _project('test/fixtures/matte.json');
      createSplash(SplashConfig.read(root.path), root: root.path);
      final res = p.join(root.path, 'android', 'app', 'src', 'main', 'res');
      expect(File(p.join(res, 'drawable', 'splash.xml')).existsSync(), isTrue);

      File(p.join(root.path, configFileName))
          .writeAsStringSync('android_avd_splash:\n  source: assets/matte.json\n  name: brand\n');
      final renamed = createSplash(SplashConfig.read(root.path), root: root.path);

      expect(File(p.join(res, 'drawable', 'brand.xml')).existsSync(), isTrue);
      expect(File(p.join(res, 'drawable', 'splash.xml')).existsSync(), isFalse,
          reason: 'the stamp finds an earlier run whatever it was called');
      expect(renamed.theme, 'Theme.Brand.Splash');
    });

    test('plays the animation over the duration that was asked for', () {
      final root = _project('test/fixtures/matte.json', extra: '  duration_ms: 800\n');
      final result = createSplash(SplashConfig.read(root.path), root: root.path);
      expect(result.durationMs, 800);
      expect(result.warnings.where((w) => w.contains('1000ms or less')), isEmpty);
      expect(
          File(p.join(root.path, 'android/app/src/main/res/values-v31/splash_styles.xml'))
              .readAsStringSync(),
          contains('windowSplashScreenAnimationDuration">800'));
    });

    test('says when the animation is longer than the guidelines allow', () {
      final root = _project('test/fixtures/matte.json');
      final result = createSplash(SplashConfig.read(root.path), root: root.path, dryRun: true);
      expect(result.durationMs, greaterThan(1000));
      expect(result.warnings.single, contains('1000ms or less'));
      expect(File(p.join(root.path, 'android/app/src/main/res/drawable/splash.xml')).existsSync(),
          isFalse,
          reason: 'a dry run writes nothing');
    });

    test('converts an animated SVG the same way', () {
      final root = _project('test/fixtures/logo.svg');
      final result = createSplash(SplashConfig.read(root.path), root: root.path);
      expect(result.generated.drawable.source, 'SVG');
      expect(result.config.kind, SourceKind.svg);
      expect(result.report!.meanExact, greaterThan(0.999));
      expect(
          File(p.join(root.path, 'android/app/src/main/res/drawable/splash_vector.xml'))
              .existsSync(),
          isTrue);
    });

    test('paints the background the plate the artwork sits on gave it', () {
      final root = _project('test/fixtures/plate.json');
      File(p.join(root.path, configFileName))
          .writeAsStringSync('android_avd_splash:\n  source: assets/plate.json\n');
      final result = createSplash(SplashConfig.read(root.path), root: root.path);
      // The platform masks the icon to a circle, so the plate cannot be drawn
      // behind the artwork - the splash background is where it belongs.
      expect(result.generated.plate, 0xFF2196F3);
      expect(result.background, 0xFF2196F3);
      expect(
          File(p.join(root.path, 'android/app/src/main/res/values/splash.xml')).readAsStringSync(),
          contains('#FF2196F3'));
      expect(result.warnings, isEmpty);
    });

    test('converts a GIF the same way', () {
      final root = _project('test/fixtures/shapes.gif');
      final result = createSplash(SplashConfig.read(root.path), root: root.path);
      expect(result.generated.drawable.source, 'GIF');
      expect(result.report!.ofCeiling, greaterThan(0.95));
    });

    test('writes Java into a Java project', () {
      final root = _project('test/fixtures/matte.json');
      final kotlin = Directory(p.join(root.path, 'android/app/src/main/kotlin'));
      final java = p.join(root.path, 'android/app/src/main/java/com/example/demo');
      kotlin.deleteSync(recursive: true);
      File(p.join(java, 'MainActivity.java'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('package com.example.demo;\n\n'
            'import io.flutter.embedding.android.FlutterActivity;\n\n'
            'public class MainActivity extends FlutterActivity {\n}\n');

      createSplash(SplashConfig.read(root.path), root: root.path);
      final activity = File(p.join(java, 'MainActivity.java')).readAsStringSync();
      expect(activity, contains('import android.os.Bundle;'));
      expect(activity, contains('protected void onCreate(Bundle savedInstanceState)'));
      expect(activity, contains('AvdSplash.install(this);'));
      final helper = File(p.join(java, 'AvdSplash.java')).readAsStringSync();
      expect(helper, contains('final class AvdSplash'));
      expect(helper, contains('activity.getSplashScreen()'));
      expect(File(p.join(java, 'AvdSplash.kt')).existsSync(), isFalse);
    });

    test('keeps a hand-written onCreate and adds one line to it', () {
      final root = _project('test/fixtures/matte.json');
      final activity =
          File(p.join(root.path, 'android/app/src/main/kotlin/com/example/demo/MainActivity.kt'))
            ..writeAsStringSync('package com.example.demo\n\n'
                'import android.os.Bundle\n'
                'import io.flutter.embedding.android.FlutterActivity\n\n'
                'class MainActivity : FlutterActivity() {\n'
                '    override fun onCreate(savedInstanceState: Bundle?) {\n'
                '        super.onCreate(savedInstanceState)\n'
                '        doMyOwnThing()\n'
                '    }\n'
                '}\n');

      createSplash(SplashConfig.read(root.path), root: root.path);
      final patched = activity.readAsStringSync();
      expect(patched, contains('doMyOwnThing()'), reason: 'their code stays');
      expect(patched.indexOf('AvdSplash.install(this)'),
          greaterThan(patched.indexOf('super.onCreate')));
      expect('override fun onCreate'.allMatches(patched).length, 1);
    });

    test('reports a project it cannot write into', () {
      final root = Directory.systemTemp.createTempSync('android_avd_splash_empty');
      addTearDown(() => root.deleteSync(recursive: true));
      expect(() => SplashConfig.read(root.path), throwsA(isA<ConfigError>()));
      expect(() => createSplash(SplashConfig(source: 'a.json'), root: root.path),
          throwsA(isA<ProjectError>()));
    });
  });
}
