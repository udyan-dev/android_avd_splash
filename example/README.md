# Example

`android_avd_splash.yaml` in this directory is a fully commented configuration
file. Copy it to the root of your Flutter or Android project, point `source:` at
a Lottie file or an animated GIF, and run:

```sh
dart pub add dev:android_avd_splash
dart run android_avd_splash:create
```

That writes, into `android/app/src/main/`:

| Path | What it is |
| --- | --- |
| `res/drawable/splash.xml` | the `<animated-vector>` |
| `res/drawable/splash_vector.xml` | its `<vector>`: groups, clip paths, paths |
| `res/animator/splash_*.xml` | one animator per animated property |
| `res/interpolator/splash_ease*.xml` | one `<pathInterpolator>` per distinct easing |
| `res/values/splash.xml` | background colour, icon size, duration |
| `res/values-night/splash.xml` | the night background |
| `res/values/splash_styles.xml` | launch theme below API 31 |
| `res/values-v31/splash_styles.xml` | the platform splash screen theme |
| `res/values-v33/splash_styles.xml` | the same, asking for the icon explicitly |
| `kotlin/.../AvdSplash.kt` | the handover, generated and commented |

and makes two edits: `android:theme` on the launcher activity, and one marked
call in `MainActivity`. Both are idempotent - run it again after changing the
animation and only the generated parts move.

Re-run `create` whenever the animation or the configuration changes; it replaces
what it wrote last time, including resources that are no longer needed.
