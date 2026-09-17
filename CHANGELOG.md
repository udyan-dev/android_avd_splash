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
