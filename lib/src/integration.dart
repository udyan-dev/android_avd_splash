import 'config.dart';

const _open = '// >>> android_avd_splash';
const _close = '// <<< android_avd_splash';

/// The activity source file the generator writes next to `MainActivity`.
String splashSource(String package, SplashConfig config, int durationMs, {required bool kotlin}) =>
    kotlin ? _kotlin(package, config, durationMs) : _java(package, config, durationMs);

/// File name of that source, in the language the activity is written in.
String splashSourceName({required bool kotlin}) => kotlin ? 'AvdSplash.kt' : 'AvdSplash.java';

/// Points the launcher activity at [theme], leaving the rest of the manifest
/// byte for byte as it was.
///
/// The manifest is edited textually rather than reserialised: an XML round trip
/// would reformat a file the project owns, and the only thing that has to
/// change is one attribute of one element.
String patchManifest(String manifest, String theme) {
  final opening = _launcherTag(manifest);
  if (opening == null) {
    throw IntegrationError('no launcher activity in AndroidManifest.xml - '
        'set android:theme="@style/$theme" on it yourself, or turn off patch_manifest');
  }
  final tag = manifest.substring(opening.start, opening.end);
  final existing = RegExp(r'android:theme\s*=\s*"[^"]*"').firstMatch(tag);
  final patched = existing != null
      ? tag.replaceRange(existing.start, existing.end, 'android:theme="@style/$theme"')
      : _withTheme(tag, theme);
  return manifest.replaceRange(opening.start, opening.end, patched);
}

/// The theme the launcher activity currently names, if any.
String? manifestTheme(String manifest) {
  final opening = _launcherTag(manifest);
  if (opening == null) return null;
  final tag = manifest.substring(opening.start, opening.end);
  return RegExp(r'android:theme\s*=\s*"([^"]*)"').firstMatch(tag)?.group(1);
}

/// Writes the handover call into an activity, or updates the one already there.
///
/// The insertion is delimited by comment markers, so running the generator
/// again replaces exactly what it wrote before and nothing a person added.
String patchActivity(String source, {required bool kotlin}) {
  final stripped = _stripBlock(source);
  final call = kotlin ? 'AvdSplash.install(this)' : 'AvdSplash.install(this);';
  final hasCreate =
      RegExp(kotlin ? r'fun\s+onCreate\s*\(' : r'void\s+onCreate\s*\(').firstMatch(stripped);

  if (hasCreate != null) {
    final superCall = RegExp(r'[ \t]*super\.onCreate\([^)]*\);?[ \t]*\r?\n').firstMatch(stripped);
    if (superCall == null) {
      throw IntegrationError('onCreate in this activity does not call super.onCreate - '
          'add `$call` after it yourself, or turn off patch_activity');
    }
    final indent = RegExp(r'^[ \t]*').firstMatch(superCall.group(0)!)!.group(0)!;
    final block = '$indent$_open\n'
        '$indent// Plays the generated splash animation and hands the screen over when it ends.\n'
        '$indent$call\n'
        '$indent$_close\n';
    return _withBundle(stripped.replaceRange(superCall.end, superCall.end, block), kotlin: kotlin);
  }

  final body = kotlin
      ? '    $_open\n'
          '    // Plays the generated splash animation and hands the screen over when it ends.\n'
          '    override fun onCreate(savedInstanceState: Bundle?) {\n'
          '        super.onCreate(savedInstanceState)\n'
          '        $call\n'
          '    }\n'
          '    $_close'
      : '    $_open\n'
          '    // Plays the generated splash animation and hands the screen over when it ends.\n'
          '    @Override\n'
          '    protected void onCreate(Bundle savedInstanceState) {\n'
          '        super.onCreate(savedInstanceState);\n'
          '        $call\n'
          '    }\n'
          '    $_close';

  final declaration = RegExp(r'class\s+\w+[^{;]*').firstMatch(stripped);
  if (declaration == null) throw IntegrationError('no class found in the activity source');
  // Kotlin allows a class with no body at all, which is how Flutter writes
  // MainActivity. Giving it an empty one first means there is a single
  // insertion point, so a second run produces the same file as the first.
  final text = stripped.substring(declaration.end).trimLeft().startsWith('{')
      ? stripped
      : '${stripped.substring(0, declaration.end).trimRight()} {\n}\n';
  return _withBundle(text.replaceFirst('{', '{\n$body', declaration.end), kotlin: kotlin);
}

/// True when the activity already carries the generated call.
bool activityPatched(String source) => source.contains(_open);

/// An integration step that cannot be done safely. The message names what to
/// do by hand instead.
class IntegrationError implements Exception {
  IntegrationError(this.message);

  final String message;

  @override
  String toString() => message;
}

String _stripBlock(String source) {
  final start = source.indexOf(_open);
  if (start < 0) return source;
  final end = source.indexOf(_close, start);
  if (end < 0) return source;
  final lineStart = source.lastIndexOf('\n', start) + 1;
  final lineEnd = source.indexOf('\n', end);
  return source.replaceRange(lineStart, lineEnd < 0 ? source.length : lineEnd + 1, '');
}

String _withBundle(String source, {required bool kotlin}) {
  if (source.contains('android.os.Bundle')) return source;
  final imports = RegExp(r'^import .*$', multiLine: true).allMatches(source).toList();
  final line = kotlin ? 'import android.os.Bundle' : 'import android.os.Bundle;';
  if (imports.isNotEmpty) {
    return source.replaceRange(imports.first.start, imports.first.start, '$line\n');
  }
  final package = RegExp(r'^package .*$', multiLine: true).firstMatch(source);
  if (package == null) return '$line\n\n$source';
  return source.replaceRange(package.end, package.end, '\n\n$line');
}

/// The opening tag of the activity that answers `MAIN`/`LAUNCHER`.
({int start, int end})? _launcherTag(String manifest) {
  for (final match in RegExp(r'<activity[\s>]').allMatches(manifest)) {
    final open = _tagEnd(manifest, match.start);
    if (open < 0) continue;
    final close = manifest.indexOf('</activity>', open);
    final block = manifest.substring(open, close < 0 ? manifest.length : close);
    if (block.contains('android.intent.action.MAIN') &&
        block.contains('android.intent.category.LAUNCHER')) {
      return (start: match.start, end: open);
    }
  }
  return null;
}

/// End of the opening tag, skipping any `>` inside an attribute value.
int _tagEnd(String manifest, int from) {
  var quoted = false;
  for (var i = from; i < manifest.length; i++) {
    final c = manifest[i];
    if (c == '"') quoted = !quoted;
    if (c == '>' && !quoted) return i + 1;
  }
  return -1;
}

String _withTheme(String tag, String theme) {
  final selfClosing = tag.endsWith('/>');
  final head = tag.substring(0, tag.length - (selfClosing ? 2 : 1)).trimRight();
  final indent = RegExp(r'\n([ \t]*)android:').firstMatch(tag)?.group(1) ?? '    ';
  return '$head\n$indent    android:theme="@style/$theme"${selfClosing ? '/>' : '>'}';
}

String _kotlin(String package, SplashConfig config, int durationMs) => '''
package $package

import android.app.Activity
import android.graphics.drawable.AnimatedVectorDrawable
import android.os.Build
import android.os.SystemClock
import android.view.Gravity
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView

/**
 * Splash screen handover, generated by android_avd_splash from
 * `${config.source}`. Running `dart run android_avd_splash:create` overwrites
 * this file, so keep your own code in the activity.
 */
internal object AvdSplash {
    /**
     * Length of `@drawable/${config.name}`. The platform caps the duration it
     * reports back through `SplashScreenView`, so the animation's own length is
     * the only reliable one.
     */
    private const val DURATION_MS = ${durationMs}L

    fun install(activity: Activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12 and up draw the splash screen themselves, then dismiss
            // it as soon as the app draws its first frame - usually before the
            // icon has finished. Holding the view is the documented way to let
            // the animation play out, and it must end with remove().
            val shown = SystemClock.uptimeMillis()
            activity.splashScreen.setOnExitAnimationListener { view ->
                val left = DURATION_MS - (SystemClock.uptimeMillis() - shown)
                if (left > 0L) view.postDelayed({ view.remove() }, left) else view.remove()
            }
        } else {
            overlay(activity)
        }
    }

    // Below Android 12 there is no platform splash screen. The launch theme has
    // already painted the background, so playing the same drawable over it gives
    // every version the same animation.
    private fun overlay(activity: Activity) {
        val size = activity.resources.getDimensionPixelSize(R.dimen.${config.name}_icon_size)
        val icon = ImageView(activity)
        icon.setImageResource(R.drawable.${config.name})
        icon.scaleType = ImageView.ScaleType.FIT_CENTER
        val view = FrameLayout(activity)
        view.setBackgroundResource(R.color.${config.name}_background)
        view.isClickable = true
        view.addView(icon, FrameLayout.LayoutParams(size, size, Gravity.CENTER))
        activity.addContentView(
            view,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )
        val animation = icon.drawable as AnimatedVectorDrawable
        // A drawable only runs once it is attached, and its length is known, so
        // the overlay leaves exactly when the animation ends.
        icon.post {
            animation.start()
            view.postDelayed({ (view.parent as? ViewGroup)?.removeView(view) }, DURATION_MS)
        }
    }
}
''';

String _java(String package, SplashConfig config, int durationMs) => '''
package $package;

import android.app.Activity;
import android.graphics.drawable.AnimatedVectorDrawable;
import android.os.Build;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.window.SplashScreen;
import android.window.SplashScreenView;

/**
 * Splash screen handover, generated by android_avd_splash from
 * `${config.source}`. Running `dart run android_avd_splash:create` overwrites
 * this file, so keep your own code in the activity.
 */
final class AvdSplash {

    /**
     * Length of `@drawable/${config.name}`. The platform caps the duration it
     * reports back through `SplashScreenView`, so the animation's own length is
     * the only reliable one.
     */
    private static final long DURATION_MS = ${durationMs}L;

    private AvdSplash() {}

    static void install(final Activity activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12 and up draw the splash screen themselves, then dismiss
            // it as soon as the app draws its first frame - usually before the
            // icon has finished. Holding the view is the documented way to let
            // the animation play out, and it must end with remove().
            final long shown = SystemClock.uptimeMillis();
            activity.getSplashScreen().setOnExitAnimationListener(
                    new SplashScreen.OnExitAnimationListener() {
                        @Override
                        public void onSplashScreenExit(final SplashScreenView view) {
                            final long left = DURATION_MS - (SystemClock.uptimeMillis() - shown);
                            if (left <= 0L) {
                                view.remove();
                                return;
                            }
                            view.postDelayed(new Runnable() {
                                @Override
                                public void run() {
                                    view.remove();
                                }
                            }, left);
                        }
                    });
        } else {
            overlay(activity);
        }
    }

    // Below Android 12 there is no platform splash screen. The launch theme has
    // already painted the background, so playing the same drawable over it gives
    // every version the same animation.
    private static void overlay(final Activity activity) {
        final int size =
                activity.getResources().getDimensionPixelSize(R.dimen.${config.name}_icon_size);
        final ImageView icon = new ImageView(activity);
        icon.setImageResource(R.drawable.${config.name});
        icon.setScaleType(ImageView.ScaleType.FIT_CENTER);
        final FrameLayout view = new FrameLayout(activity);
        view.setBackgroundResource(R.color.${config.name}_background);
        view.setClickable(true);
        view.addView(icon, new FrameLayout.LayoutParams(size, size, Gravity.CENTER));
        activity.addContentView(
                view,
                new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        final AnimatedVectorDrawable animation = (AnimatedVectorDrawable) icon.getDrawable();
        // A drawable only runs once it is attached, and its length is known, so
        // the overlay leaves exactly when the animation ends.
        icon.post(new Runnable() {
            @Override
            public void run() {
                animation.start();
                view.postDelayed(new Runnable() {
                    @Override
                    public void run() {
                        final ViewGroup parent = (ViewGroup) view.getParent();
                        if (parent != null) {
                            parent.removeView(view);
                        }
                    }
                }, DURATION_MS);
            }
        });
    }
}
''';
