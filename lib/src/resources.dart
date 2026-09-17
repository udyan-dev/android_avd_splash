import 'config.dart';
import 'stamp.dart';

/// The colour, dimension and theme resources that go with an animated splash
/// icon, keyed by path under `res/`.
///
/// The theme is written three times because Android resolves a style from one
/// configuration only - styles never merge - so every variant has to be whole:
/// `values/` for the window before API 31, `values-v31/` for the platform
/// splash screen, and `values-v33/` when the icon is asked for explicitly.
/// Night is a colour, not a theme, so it needs no version qualifier of its own:
/// a night qualifier outranks a version qualifier, and a `values-night-v31`
/// omission would otherwise cost an API 31 device in dark mode its icon.
Map<String, String> splashResources(SplashConfig config, int durationMs, int background) {
  final name = config.name;
  final night = config.backgroundNight;
  return {
    'values/$name.xml': _values(config, durationMs, background),
    'values/${name}_styles.xml': _style(config, durationMs, platform: false, behavior: false),
    'values-v31/${name}_styles.xml': _style(config, durationMs, platform: true, behavior: false),
    if (config.iconPreferred)
      'values-v33/${name}_styles.xml': _style(config, durationMs, platform: true, behavior: true),
    if (night != null) 'values-night/$name.xml': _nightValues(name, night),
  };
}

/// The theme the launcher activity has to use, named after the resource:
/// `splash` gives `Theme.Splash`, `brand` gives `Theme.Brand.Splash`.
String splashTheme(String name) {
  final words = name.split(RegExp('[_-]+')).where((w) => w.isNotEmpty).toList();
  final camel = words.map((w) => w[0].toUpperCase() + w.substring(1)).join();
  return words.last == 'splash' ? 'Theme.$camel' : 'Theme.$camel.Splash';
}

String _values(SplashConfig config, int durationMs, int background) {
  final out = StringBuffer(xmlHeader)
    ..writeln('<resources>')
    ..writeln('    <color name="${config.name}_background">${hex(background)}</color>');
  final icon = config.iconBackground;
  if (icon != null) {
    out.writeln('    <color name="${config.name}_icon_background">${hex(icon)}</color>');
  }
  return (out
        ..writeln('    <dimen name="${config.name}_icon_size">'
            '${_n(config.canvasDp)}dp</dimen>')
        ..writeln('    <integer name="${config.name}_duration">$durationMs</integer>')
        ..writeln('</resources>'))
      .toString();
}

String _nightValues(String name, int background) => '$xmlHeader'
    '<resources>\n'
    '    <color name="${name}_background">${hex(background)}</color>\n'
    '</resources>\n';

/// Below API 31 there is no platform splash screen: the theme only paints the
/// window, and the activity plays the drawable over it.
String _style(SplashConfig config, int durationMs,
    {required bool platform, required bool behavior}) {
  final name = config.name;
  final out = StringBuffer(xmlHeader)
    ..writeln('<resources>')
    ..writeln('    <style name="${splashTheme(name)}"'
        ' parent="@android:style/Theme.Material.NoActionBar">')
    ..writeln('        <item name="android:windowBackground">@color/${name}_background</item>');
  if (platform) {
    out
      ..writeln('        <item name="android:windowSplashScreenBackground">'
          '@color/${name}_background</item>')
      ..writeln('        <item name="android:windowSplashScreenAnimatedIcon">'
          '@drawable/$name</item>')
      // Android 12 reads the length from here; Android 13 and up read it from
      // the drawable, and cap what it reports back to the app either way.
      ..writeln('        <item name="android:windowSplashScreenAnimationDuration">'
          '$durationMs</item>');
    if (config.iconBackground != null) {
      out.writeln('        <item name="android:windowSplashScreenIconBackgroundColor">'
          '@color/${name}_icon_background</item>');
    }
    if (behavior) {
      out.writeln('        <item name="android:windowSplashScreenBehavior">'
          'icon_preferred</item>');
    }
  }
  return (out
        ..writeln('    </style>')
        ..writeln('</resources>'))
      .toString();
}

/// `0xAARRGGBB` as Android writes it in a resource file.
String hex(int argb) => '#${(argb & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase()}';

String _n(num value) {
  final s = value.toStringAsFixed(2);
  return s.endsWith('.00') ? s.substring(0, s.length - 3) : s.replaceAll(RegExp(r'0+$'), '');
}
