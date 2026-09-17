import 'dart:io';

import 'package:android_avd_splash/android_avd_splash.dart';
import 'package:test/test.dart';

void main() {
  final gif = decodeGif(File('test/fixtures/shapes.gif').readAsBytesSync());

  test('decodes every frame of an optimised, disposal-using GIF', () {
    expect(gif.width, 48);
    expect(gif.height, 48);
    expect(gif.frames.length, 6);
    expect([for (final f in gif.frames) f.delayMs], [50, 50, 50, 50, 50, 150]);
    expect(gif.durationMs, 400);
  });

  test('composites frames onto the canvas', () {
    int at(int frame, int x, int y) {
      final rgba = gif.frames[frame].rgba;
      final i = (y * gif.width + x) * 4;
      return (rgba[i + 3] << 24) | (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2];
    }

    expect(at(0, 24, 24), 0, reason: 'the first frame is blank and transparent');
    expect(at(5, 32, 10), 0xFFDC2828, reason: 'the square ends on the right');
    expect(at(5, 24, 20), 0xFF2850DC, reason: 'the ring is filled at its top');
    expect(at(5, 24, 32), 0, reason: 'the hole shows the transparent background');
  });

  test('rejects data that is not a GIF', () {
    expect(
        () => decodeGif(File('pubspec.yaml').readAsBytesSync()), throwsA(isA<FormatException>()));
  });
}
