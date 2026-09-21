/// Generates an Android 12+ splash screen from a Lottie animation, an animated
/// SVG or an animated GIF.
///
/// [createSplash] is the whole tool: it reads a [SplashConfig], converts the
/// animation into an `AnimatedVectorDrawable`, writes every resource the
/// platform's splash screen needs, and connects them to the launcher activity.
/// [convertLottie], [convertSvg] and [generate] are the conversion on its own,
/// for callers that only want the drawable.
library;

export 'src/build.dart' show Avd, Options;
export 'src/config.dart' show ConfigError, SourceKind, SplashConfig, configFileName;
export 'src/convert.dart'
    show
        Generated,
        check,
        checkLottie,
        checkVector,
        convertLottie,
        convertSvg,
        findResDir,
        generate,
        write;
export 'src/gif.dart' show Gif, GifFrame, decodeGif;
export 'src/integration.dart' show IntegrationError;
export 'src/lottie.dart' show Lottie;
export 'src/model.dart' show Drawable, Drawn, Easing, Group, Key, Paint, PathItem, Track;
export 'src/project.dart' show AndroidProject, ProjectError;
export 'src/resources.dart' show splashTheme;
export 'src/splash.dart' show SplashResult, createSplash;
export 'src/svg.dart' show Svg;
export 'src/verify.dart' show Playback, Report, verify;
export 'src/write.dart' show resourceStringLimit, withinStringLimit;
