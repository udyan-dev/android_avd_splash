import 'dart:typed_data';

/// One fully composited frame of an animated GIF.
class GifFrame {
  GifFrame(this.rgba, this.delayMs);

  /// Composited canvas, 4 bytes per pixel, row major.
  final Uint8List rgba;

  /// Display duration in milliseconds.
  final int delayMs;
}

/// A decoded animated GIF.
class Gif {
  Gif(this.width, this.height, this.frames);

  final int width;
  final int height;
  final List<GifFrame> frames;

  int get durationMs => frames.fold(0, (a, f) => a + f.delayMs);
}

/// Decodes GIF87a/GIF89a, including interlace, transparency, local colour
/// tables and all four disposal methods, into fully composited RGBA frames.
Gif decodeGif(Uint8List data) {
  final r = _Reader(data);
  final sig = r.string(6);
  if (sig != 'GIF87a' && sig != 'GIF89a') throw const FormatException('not a GIF');

  final width = r.u16(), height = r.u16();
  final packed = r.u8();
  r.skip(2); // background colour index, pixel aspect ratio
  final global = (packed & 0x80) != 0 ? r.palette(2 << (packed & 7)) : null;

  final canvas = Uint8List(width * height * 4);
  Uint8List? saved;
  final frames = <GifFrame>[];
  var delay = 0, transparent = -1, disposal = 0;

  loop:
  while (r.remaining > 0) {
    switch (r.u8()) {
      case 0x21: // extension
        final label = r.u8();
        if (label == 0xF9) {
          r.u8(); // block size
          final flags = r.u8();
          delay = r.u16() * 10;
          final index = r.u8();
          r.u8(); // block terminator
          disposal = (flags >> 2) & 7;
          transparent = (flags & 1) != 0 ? index : -1;
        } else {
          r.skipBlocks();
        }
      case 0x2C: // image descriptor
        final fx = r.u16(), fy = r.u16(), fw = r.u16(), fh = r.u16();
        final f = r.u8();
        final local = (f & 0x80) != 0 ? r.palette(2 << (f & 7)) : null;
        final palette = local ?? global;
        if (palette == null) throw const FormatException('GIF frame has no palette');
        final pixels = _lzw(r, fw * fh);
        if ((f & 0x40) != 0) _deinterlace(pixels, fw, fh);
        if (disposal == 3) saved = Uint8List.fromList(canvas);

        for (var y = 0; y < fh; y++) {
          final cy = fy + y;
          if (cy < 0 || cy >= height) continue;
          var src = y * fw;
          var dst = (cy * width + fx) * 4;
          for (var x = 0; x < fw; x++, src++, dst += 4) {
            final cx = fx + x;
            if (cx < 0 || cx >= width) continue;
            final index = pixels[src];
            if (index == transparent) continue;
            final p = index * 3;
            canvas[dst] = palette[p];
            canvas[dst + 1] = palette[p + 1];
            canvas[dst + 2] = palette[p + 2];
            canvas[dst + 3] = 255;
          }
        }
        frames.add(GifFrame(Uint8List.fromList(canvas), delay));

        if (disposal == 2) {
          for (var y = fy; y < fy + fh && y < height; y++) {
            final row = (y * width + fx) * 4;
            canvas.fillRange(row, row + fw.clamp(0, width - fx) * 4, 0);
          }
        } else if (disposal == 3 && saved != null) {
          canvas.setAll(0, saved);
        }
      case 0x3B: // trailer
        break loop;
      default:
        throw const FormatException('corrupt GIF block');
    }
  }
  if (frames.isEmpty) throw const FormatException('GIF has no frames');
  return Gif(width, height, frames);
}

void _deinterlace(Uint8List pixels, int w, int h) {
  final out = Uint8List(pixels.length);
  var src = 0;
  for (final pass in const [
    [0, 8],
    [4, 8],
    [2, 4],
    [1, 2]
  ]) {
    for (var y = pass[0]; y < h; y += pass[1], src += w) {
      out.setRange(y * w, y * w + w, pixels, src);
    }
  }
  pixels.setAll(0, out);
}

/// GIF variable-width LZW: emits [count] palette indices.
Uint8List _lzw(_Reader r, int count) {
  final minCodeSize = r.u8();
  final clear = 1 << minCodeSize, eoi = clear + 1;
  final prefix = Int32List(4096), suffix = Uint8List(4096), first = Uint8List(4096);
  for (var i = 0; i < clear; i++) {
    suffix[i] = first[i] = i;
  }
  final out = Uint8List(count), stack = Uint8List(4096), buffer = Uint8List(255);
  var next = eoi + 1, codeSize = minCodeSize + 1, mask = (1 << codeSize) - 1;
  var previous = -1, written = 0, bits = 0, acc = 0, block = 0, offset = 0;

  while (true) {
    while (bits < codeSize) {
      if (offset == block) {
        block = r.u8();
        if (block == 0) return out;
        r.bytes(buffer, block);
        offset = 0;
      }
      acc |= buffer[offset++] << bits;
      bits += 8;
    }
    final code = acc & mask;
    acc >>= codeSize;
    bits -= codeSize;

    if (code == eoi) break;
    if (code == clear) {
      next = eoi + 1;
      codeSize = minCodeSize + 1;
      mask = (1 << codeSize) - 1;
      previous = -1;
      continue;
    }
    if (previous < 0) {
      if (code >= clear) throw const FormatException('corrupt LZW stream');
      if (written < count) out[written++] = code;
      previous = code;
      continue;
    }

    var walk = code, top = 0;
    if (code >= next) {
      stack[top++] = first[previous];
      walk = previous;
    }
    while (walk >= clear) {
      stack[top++] = suffix[walk];
      walk = prefix[walk];
    }
    stack[top++] = walk;
    for (var i = top - 1; i >= 0 && written < count; i--) {
      out[written++] = stack[i];
    }

    if (next < 4096) {
      prefix[next] = previous;
      suffix[next] = stack[top - 1];
      first[next] = first[previous];
      next++;
      if (next > mask && codeSize < 12) {
        codeSize++;
        mask = (1 << codeSize) - 1;
      }
    }
    previous = code;
  }
  r.skipBlocks();
  return out;
}

class _Reader {
  _Reader(this.data);

  final Uint8List data;
  int at = 0;

  int get remaining => data.length - at;
  int u8() => data[at++];
  int u16() => data[at++] | (data[at++] << 8);
  void skip(int n) => at += n;
  String string(int n) => String.fromCharCodes(data, at, at += n);
  Uint8List palette(int colors) => Uint8List.sublistView(data, at, at += colors * 3);

  void bytes(Uint8List into, int n) {
    into.setRange(0, n, data, at);
    at += n;
  }

  void skipBlocks() {
    while (true) {
      final n = u8();
      if (n == 0) return;
      at += n;
    }
  }
}
