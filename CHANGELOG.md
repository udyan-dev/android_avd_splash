## 1.1.2

- Re-recorded the Lottie, animated SVG and animated GIF splash demos at the
  device's native 1440x2960 resolution and 60 fps.
- Added animated previews to the package README, linked to the full-resolution
  recordings.

## 1.1.0

Animated SVG joins Lottie and GIF as a source, and the output is now checked
against the platform rather than against the emitter. Every accuracy figure
below is the written XML replayed and rasterised, then confirmed frame by frame
against the renderer the format came from and against a real device.

| Source | Accuracy | Paths | Size | Morph load |
| --- | --- | --- | --- | --- |
| Lottie, nested precomps and track mattes | 100.0% of 1.0000 | 40 | 541 KiB | 0 |
| Lottie, stroked arcs and trims | 100.0% of 1.0000 | 13 | 83 KiB | 8 |
| Lottie, gradients and trim | 100.0% of 1.0000 | 8 | 162 KiB | 34 |
| Lottie, track mattes | 100.0% of 1.0000 | 2 | 72 KiB | 26 |
| SVG, SMIL transforms | 100.0% of 1.0000 | 10 | 80 KiB | 0 |
| GIF, flat colour | 99.5% of 0.9987 | 7 | 778 KiB | 264 |
| GIF, photographic | 97.7% of 0.9902 | 22 | 5.2 MiB | 400 |

A GIF is traced, so strict agreement with one has a ceiling below 1.0: the run
measures that ceiling and reports the share of it reached.

### New

- Animated SVG: `source: logo.svg`, or `avdgen logo.svg`. `<animateTransform>`
  becomes the `<group>` it drives, `keySplines` a `<pathInterpolator>`, an
  `<animate>` on `d` a path morph, `<clipPath>` a wound `<clip-path>`. The whole
  path grammar, paint inheritance, gradients and CSS colour names are read; CSS
  animation, masks, filters, patterns, text, images, skews and animating colours
  are reported rather than dropped.
- `checkVector` replaces `checkLottie`, which forwards to it and is deprecated.

### What the device plays, not what the file says

The verifier agreed with the emitter instead of with Android, so none of these
could be seen. It now reads a written file the way `AnimatorInflater`,
`KeyframeSet` and `VectorDrawable` do, and `test/animator_test.dart` holds each
rule.

- A trim is written in order. Lottie draws the arc between the lower and the
  higher of start and end; `VectorDrawable` wraps a start that has run past its
  end and draws the rest of the outline - the complement. A wordmark that
  should have been a moving dot came out as the whole letter.
- A contour is closed only when it returns to its start. `z` on an open one
  draws a chord and a miter join across it, which the device showed as spikes
  off the artwork.
- Every `<objectAnimator>` names the linear interpolator. Left out, the default
  is accelerate-decelerate, applied to the whole track before a keyframe is
  read: a layer that should leave at 200ms left at 641ms.
- A step is a change one millisecond wide, not two keyframes at one fraction -
  `KeyframeSet` divides by the gap between them.
- A `<path>` and a `<group>` declare the value at time zero, not a track's
  first key, which is elsewhere once a precomposition has shifted it.
- A shortened keyframe interval keeps its own easing, split at the cut.
- The splash is held for the drawable's own length; the duration
  `SplashScreenView` reports is capped by the platform.
- One `<pathInterpolator>` per distinct curve: `Easing` had no value equality,
  so twelve curves wrote sixty-two files.
- No `<path>` is longer than a compiled resource string, whose length is
  fifteen bits; a longer one comes back broken and the platform silently shows
  the launcher icon instead.

### Fit and colour

- The artwork is measured after its own clips, and centred on what it actually
  covers. A matte or a composition box counted as artwork before, so the icon
  was scaled down to make room for geometry nobody sees: the Google logo now
  reaches 95.7dp of the 96dp the platform shows, up from 77.8dp.
- A plate the artwork sits on becomes the splash background. The platform masks
  the icon to a circle, so a square behind the artwork could only be drawn with
  its corners cut, at the artwork's expense.
- A traced region whose colour plainly belongs to another paint is dropped, so
  a seam between two GIF colours no longer leaves a sliver of a third.
- A fold that reads as two flat tones is fitted as a hard-step gradient rather
  than a ramp, at no cost in size.
- A stroke is part of the artwork: its half width is measured into the fit, and
  both verifiers rasterise the band it covers.
- Lottie primitives animate - a rectangle's size, an ellipse's centre, a corner
  radius - and a motion path is walked by arc length rather than cut across.
- A trim cuts where it says it does, and a window that wraps past the end of a
  path is two arcs, which is what a stroke draws.
- A matte layer's stroke counts towards what it mattes; an invisible layer
  mattes nothing; added and subtracted masks nest as clips instead of being
  flattened; fills keep Lottie's non-zero rule.
- A vector animation no longer opens or closes on an empty screen: blank time
  at either end is trimmed, measured by what the artwork covers.
- Animators that hold one value are not written, and neighbouring morph steps
  that hold one shape are one step - a GIF is mostly held shapes.
- A gradient fill no longer also writes `android:fillColor` on the same path,
  which failed the build whenever the Android Gradle plugin had to unroll the
  inline resource itself.
- `create` no longer crashes when its output is piped into a command that
  closes early.

## 1.0.0

First release.

- `dart run android_avd_splash:create` reads `android_avd_splash.yaml` and
  writes the whole Android 12+ splash screen: an `AnimatedVectorDrawable`, its
  animators and interpolators, the colour, dimension and theme resources for
  day, night, API 31 and API 33, the activity helper, and the manifest and
  activity edits that connect them.
- Lottie is converted structurally and exactly: paths stay the author's
  Beziers, keyframe easing becomes `<pathInterpolator>`, opacity becomes
  `fillAlpha`, a track matte becomes a `<clip-path>`, a trim on a filled shape
  is cut into the geometry, and group opacity is folded into the paints below.
- GIF is traced: colour separation, sub-pixel contours, shared knots, rigid
  motion factored into `<group>` transforms, keyframes thinned in dp.
- Every run replays the XML it wrote against the source and reports the
  accuracy, the outline deviation in dp, and whether the artwork stays inside
  the area the platform shows.
- `avdgen` converts a single file without touching a project.
