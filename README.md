# android_avd_splash

Turns a Lottie animation or an animated GIF into an Android 12+ splash screen:
an `AnimatedVectorDrawable`, every resource the platform needs around it, and
the two edits that connect them to your launcher activity. One configuration
file, one command.

```sh
dart pub add dev:android_avd_splash
dart run android_avd_splash:create
```

```yaml
# android_avd_splash.yaml
android_avd_splash:
  source: assets/splash.json
  background: "#FF102030"
  duration_ms: 1000
```

```
assets/splash.json -> @drawable/splash (Lottie, 1000 ms)
  2 paths, 63.8 KiB, 26 morphing Bezier segments per frame
  accuracy 100.0% of a 1.0000 ceiling, outline within 0.00dp
  icon reaches 95.9dp of the 96dp the platform shows
  33 files written

Launcher activity theme: @style/Theme.Splash (set in AndroidManifest.xml)
Handover: AvdSplash.install(this) in MainActivity.kt, beside AvdSplash.kt
```

No runtime dependency is added to your app: the output is platform XML plus one
generated Kotlin (or Java) file. Nothing is left at runtime to go wrong on a
device you have not tested.

## Why a drawable and not a GIF or a Lottie view

The platform splash screen draws `windowSplashScreenAnimatedIcon`, and it only
accepts an `AnimatedVectorDrawable`. Anything else - a Lottie view, an image, a
splash `Activity` - can only run *after* the window is already up, which is the
flash the splash screen API exists to remove.

## Accuracy

Lottie is vector in, vector out, so the conversion is structural and exact:
paths stay the author's Beziers, groups stay `<group>` transforms with the
author's anchor as the pivot, keyframe easing becomes `<pathInterpolator>`, and
opacity becomes `fillAlpha`. Three Lottie features have no Android equivalent
and are converted rather than declared: an alpha track matte becomes a
`<clip-path>` with the matte wound out of a box around the layer; a trim on a
*filled* shape is cut into the geometry with de Casteljau, because Android trims
only strokes; and group opacity is folded into the paints below it, because a
`<group>` cannot carry any.

A GIF has to be traced, and strict pixel agreement with one has a ceiling below
1.0 - a GIF edge owns whole pixels, a vector edge cuts through them. So the run
measures that ceiling (the GIF's own contours rasterised straight back) and
reports the share of it reached. Chase the percentage, not the raw number.

| Source | Accuracy | Paths | Size | Morph load |
| --- | --- | --- | --- | --- |
| Lottie, track mattes | 100.0% of 1.0000 | 2 | 65 KiB | 26 |
| Lottie, gradients and trim | 100.0% of 1.0000 | 8 | 182 KiB | 34 |
| GIF, flat colour | 100.0% of 1.0000 | 11 | 499 KiB | 293 |
| GIF, photographic | 97.6% of 0.9902 | 22 | 1.8 MiB | 400 |

Every run replays the XML it wrote - parsing it back, evaluating the animators
and the interpolators, rasterising the result - and reports the overlap, the
outline deviation in dp, and how far the artwork reaches. The measurement is
taken from the written files, not from the model that produced them.

## Guidelines it enforces

- The icon is drawn on a 288dp canvas and the artwork is kept inside the 192dp
  circle the platform shows; the outer third is masked. Geometry that would be
  clipped is scaled to fit, and measured after fitting rather than before.
- The theme is written whole in `values/`, `values-v31/` and `values-v33/`,
  because Android resolves a style from one configuration and styles never
  merge. Night is a colour resource, so it needs no version qualifier of its
  own - and a missing `values-night-v31` is exactly how an API 31 device in dark
  mode loses its animated icon.
- An animation longer than 1000ms is reported, because the guidelines ask for
  one second or less on phones. `duration_ms:` replays it faster; every keyframe
  moves by one factor, so the motion is unchanged.
- No splash `Activity` is generated. Android 12 and up hand the screen over
  through `setOnExitAnimationListener`, held for the drawable's own length
  because the platform caps the duration it reports. Below API 31, where there
  is no platform splash screen, the generated helper plays the same drawable
  over the launch theme's background, so one animation covers every version.

## Configuration

`android_avd_splash.yaml` in the project root. Only `source:` is required.

| Option | Default | What it does |
| --- | --- | --- |
| `source` | - | `.json` Lottie or `.gif`, relative to the project root |
| `name` | `splash` | resource stem: `@drawable/splash`, `@style/Theme.Splash` |
| `background` | GIF's own, else white | one opaque colour, `#RRGGBB` or `#AARRGGBB` |
| `background_night` | - | the same under `values-night` |
| `icon_background` | - | optional circle behind the icon |
| `duration_ms` | the animation's own | replays it over this long |
| `canvas_dp` | `288` | drawable canvas; the outer third is masked |
| `safe_radius_dp` | `96` | how far the artwork may reach from the centre |
| `max_morph` | `400` | morphing Bezier segments allowed per frame; `0` lifts it |
| `icon_preferred` | `true` | ask Android 13+ to show the icon regardless of entry point |
| `android_dir` | `android` | the Android module inside the project |
| `patch_manifest` | `true` | set `android:theme` on the launcher activity |
| `patch_activity` | `true` | write the handover call into the activity |
| `verify` | `true` | replay the written XML and report |
| `gradients` | `true` | fill a region with a gradient when it needs one |
| `trim` | `true` | drop a blank lead-in and a static tail |
| `smooth` | measured | GIF only: blur in source pixels before tracing |
| `colors` | the GIF's own | GIF only: paint colours, front to back |

`create` also takes `--project <dir>`, `--config <path>` and `--dry-run`.

## What it writes

Into `android/app/src/main/`:

```
res/drawable/splash.xml              the <animated-vector>
res/drawable/splash_vector.xml       its <vector>: groups, clip paths, paths
res/animator/splash_*.xml            one animator per animated property
res/interpolator/splash_ease*.xml    one <pathInterpolator> per distinct easing
res/values/splash.xml                background colour, icon size, duration
res/values-night/splash.xml          the night background
res/values/splash_styles.xml         launch theme below API 31
res/values-v31/splash_styles.xml     the platform splash screen theme
res/values-v33/splash_styles.xml     the same, asking for the icon explicitly
kotlin/.../AvdSplash.kt              the handover, generated and commented
```

and edits two files: `android:theme` on the launcher activity in
`AndroidManifest.xml`, and one marked block in `MainActivity`. Both edits are
textual and idempotent - the manifest is not reserialised, and the activity
block is delimited by comment markers, so a second run replaces exactly what
the first one wrote and nothing you added. Resources from an earlier run that
this one no longer needs are deleted rather than left to ship in the APK.

## Converting without a project

```sh
dart run android_avd_splash:avdgen logo.json --out path/to/res
dart run android_avd_splash:avdgen logo.gif --dry-run
```

`avdgen` writes the drawable, its animators and its interpolators, and nothing
else: no theme, no colours, no edits.

## As a library

```dart
import 'package:android_avd_splash/android_avd_splash.dart';

final result = createSplash(SplashConfig.read('.'));
print(result.report?.ofCeiling);

final drawable = convertLottie(File('logo.json').readAsBytesSync());
print(drawable.files['drawable/splash.xml']);
```

## Limits

- Lottie repeaters, merge paths, star shapes, luma mattes, masks, text, image
  and solid layers are reported, not silently dropped.
- `AnimatedVectorDrawable` cannot animate a gradient, so a gradient is fitted
  once, from the frame that shows its region most fully.
- A `<clip-path>` is not anti-aliased and has no fill type, so a matte edge is
  harder than Lottie draws it, and a self-intersecting matte outline - one the
  even-odd rule would hollow out - cannot be expressed. Nested outlines, which
  is what mattes are in practice, can.
- A GIF that crops its own artwork produces cropped outlines, faithfully. On a
  small source one GIF pixel covers several dp once blown up to icon size, so
  trace from the largest source you have - or convert the vector artwork
  instead.
- iOS is out of scope. This generates Android platform resources.
