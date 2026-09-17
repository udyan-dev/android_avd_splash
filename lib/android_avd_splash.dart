/// Generates an Android 12+ splash screen from a Lottie animation or an
/// animated GIF.
///
/// [createSplash] is the whole tool: it reads a [SplashConfig], converts the
/// animation into an `AnimatedVectorDrawable`, writes every resource the
/// platform's splash screen needs, and connects them to the launcher activity.
/// [generate] and [convertLottie] are the conversion on its own, for callers
/// that only want the drawable.
library;

export 'src/build.dart' show Avd, Options;
export 'src/config.dart' show ConfigError, SplashConfig, configFileName;
export 'src/convert.dart'
    show Generated, check, checkLottie, convertLottie, findResDir, generate, write;
export 'src/gif.dart' show Gif, GifFrame, decodeGif;
export 'src/integration.dart' show IntegrationError;
export 'src/lottie.dart' show Lottie;
export 'src/model.dart' show Drawable, Drawn, Easing, Group, Key, Paint, PathItem, Track;
export 'src/project.dart' show AndroidProject, ProjectError;
export 'src/resources.dart' show splashTheme;
export 'src/splash.dart' show SplashResult, createSplash;
export 'src/verify.dart' show Playback, Report, verify;
