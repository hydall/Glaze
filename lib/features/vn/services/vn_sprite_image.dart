/// Turns what an image model drew into the engine's character sprites: the
/// flat background cut away, a sheet split into its figures, and every
/// emotion of one character placed on one canvas so they swap in place.
///
/// Image models do not return transparency, so they are asked for a flat
/// chroma background and it is removed here. Pure and synchronous: callers
/// run it on a background isolate.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// The emotions the engine shows, in the order a sheet draws them.
const List<String> kVnEmotions = [
  'normal',
  'smile',
  'angry',
  'sad',
  'surprised',
];

/// A flat background the model is asked to paint behind the figures.
class VnChroma {
  const VnChroma(this.name, this.r, this.g, this.b);

  final String name;
  final int r;
  final int g;
  final int b;

  String get hex =>
      '#${[r, g, b].map((c) => c.toRadixString(16).padLeft(2, '0')).join()}'
          .toUpperCase();

  static const green = VnChroma('green', 0, 255, 0);
  static const magenta = VnChroma('magenta', 255, 0, 255);

  /// Green unless the character's hair is green: a background the figure
  /// shares a color with would be cut out of the figure too.
  static VnChroma against(String? hairHex) {
    final rgb = _parseHex(hairHex);
    if (rgb == null) return green;
    final (r, g, b) = rgb;
    final greenish = g > 90 && g > r * 1.15 && g > b * 1.05;
    return greenish ? magenta : green;
  }
}

(int, int, int)? _parseHex(String? hex) {
  var h = (hex ?? '').replaceFirst('#', '').trim();
  if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
  if (h.length != 6) return null;
  final v = int.tryParse(h, radix: 16);
  if (v == null) return null;
  return ((v >> 16) & 255, (v >> 8) & 255, v & 255);
}

/// A guide the model draws over: [count] grey mannequins standing on
/// [chroma], evenly spaced. It fixes where each figure goes, which is what
/// lets the sheet be split reliably.
Uint8List buildVnLayoutGuide({
  required int width,
  required int height,
  required int count,
  required VnChroma chroma,
}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(chroma.r, chroma.g, chroma.b));
  final grey = img.ColorRgb8(150, 150, 150);
  final slot = width / count;
  final figure = height * 0.86;
  final top = (height - figure) / 2;
  final unit = figure / 8; // a figure is eight heads tall
  for (var i = 0; i < count; i++) {
    final cx = (slot * (i + 0.5)).round();
    int y(double heads) => (top + unit * heads).round();
    int x(double heads) => (cx + unit * heads).round();
    img.fillCircle(
      image,
      x: cx,
      y: y(0.5),
      radius: (unit * 0.48).round(),
      color: grey,
    );
    img.fillRect(
      image,
      x1: x(-0.2),
      y1: y(0.9),
      x2: x(0.2),
      y2: y(1.3),
      color: grey,
    );
    img.fillRect(
      image,
      x1: x(-0.85),
      y1: y(1.3),
      x2: x(0.85),
      y2: y(4.1),
      color: grey,
    );
    img.fillRect(
      image,
      x1: x(-1.15),
      y1: y(1.4),
      x2: x(-0.9),
      y2: y(4.0),
      color: grey,
    );
    img.fillRect(
      image,
      x1: x(0.9),
      y1: y(1.4),
      x2: x(1.15),
      y2: y(4.0),
      color: grey,
    );
    img.fillRect(
      image,
      x1: x(-0.7),
      y1: y(4.1),
      x2: x(-0.1),
      y2: y(8),
      color: grey,
    );
    img.fillRect(
      image,
      x1: x(0.1),
      y1: y(4.1),
      x2: x(0.7),
      y2: y(8),
      color: grey,
    );
  }
  return img.encodePng(image);
}

/// Distance in RGB at or below which a pixel is the background.
const double _near = 48;

/// Distance above which a pixel is the figure; between the two the edge is
/// partly transparent.
const double _far = 110;

/// How strongly a pixel carries a chroma background, as a share of how
/// strongly the background itself does: above [_keyClear] it is background,
/// below [_keySolid] it is figure, in between it is a soft edge.
const double _keyClear = 0.5;
const double _keySolid = 0.15;

/// [source] with its flat background made transparent.
///
/// The background color is read off the border, not assumed: models drift
/// from the exact color asked for. A green or magenta background is keyed by
/// how much its channel outweighs the others, which survives JPEG and holds
/// for gaps enclosed by the figure (between an arm and the body, under the
/// hair); the spill it leaves on edges is pulled back. Any other flat
/// background is flooded in from the border by color distance.
img.Image cutOutBackground(img.Image source) {
  final image = source.convert(numChannels: 4);
  final w = image.width, h = image.height;
  final px = image.getBytes(order: img.ChannelOrder.rgba);

  final (br, bg, bb) = _borderColor(px, w, h);
  final greenBg = bg - math.max(br, bb) > 120;
  final magentaBg = math.min(br, bb) - bg > 120;
  if (greenBg || magentaBg) {
    _chromaKey(
      px,
      w * h,
      green: greenBg,
      strength: greenBg ? bg - math.max(br, bb) : math.min(br, bb) - bg,
    );
  } else {
    _floodKey(px, w, h, (br, bg, bb));
  }
  return img.Image.fromBytes(
    width: w,
    height: h,
    bytes: px.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
}

void _chromaKey(
  Uint8List px,
  int count, {
  required bool green,
  required int strength,
}) {
  for (var i = 0; i < count; i++) {
    final o = i * 4;
    final r = px[o], g = px[o + 1], b = px[o + 2];
    final int excess = green ? g - math.max(r, b) : math.min(r, b) - g;
    if (excess <= 0) continue;
    final k = excess / strength;
    final a = k >= _keyClear
        ? 0.0
        : k <= _keySolid
        ? 1.0
        : 1 - (k - _keySolid) / (_keyClear - _keySolid);
    px[o + 3] = (px[o + 3] * a).round();
    // Despill: what is left of the background's tint on the edge goes.
    if (green) {
      px[o + 1] = g - excess;
    } else {
      px[o] = r - excess;
      px[o + 2] = b - excess;
    }
  }
}

void _floodKey(Uint8List px, int w, int h, (int, int, int) bgColor) {
  final (br, bg, bb) = bgColor;
  final dist = Float32List(w * h);
  for (var i = 0; i < w * h; i++) {
    final dr = px[i * 4] - br, dg = px[i * 4 + 1] - bg, db = px[i * 4 + 2] - bb;
    dist[i] = math.sqrt(dr * dr + dg * dg + db * db);
  }

  // 1 = background.
  final mask = Uint8List(w * h);
  final queue = Int32List(w * h);
  var head = 0, tail = 0;
  void seed(int i) {
    if (mask[i] == 0 && dist[i] <= _far) {
      mask[i] = 1;
      queue[tail++] = i;
    }
  }

  for (var x = 0; x < w; x++) {
    seed(x);
    seed((h - 1) * w + x);
  }
  for (var y = 0; y < h; y++) {
    seed(y * w);
    seed(y * w + w - 1);
  }
  while (head < tail) {
    final i = queue[head++];
    final x = i % w, y = i ~/ w;
    // Fill through the faded band only from pixels that are background for
    // sure; otherwise the fill leaks along anti-aliased outlines.
    if (dist[i] > _near) continue;
    if (x > 0) seed(i - 1);
    if (x < w - 1) seed(i + 1);
    if (y > 0) seed(i - w);
    if (y < h - 1) seed(i + w);
  }
  for (var i = 0; i < w * h; i++) {
    if (mask[i] == 0) continue;
    // Pixels in the faded band keep a little of the figure's outline.
    final a = dist[i] <= _near
        ? 0
        : ((dist[i] - _near) / (_far - _near) * 255).round();
    px[i * 4 + 3] = a.clamp(0, 255);
  }
}

/// Per-channel median of the border pixels.
(int, int, int) _borderColor(Uint8List px, int w, int h) {
  final rs = <int>[], gs = <int>[], bs = <int>[];
  void add(int x, int y) {
    final i = (y * w + x) * 4;
    rs.add(px[i]);
    gs.add(px[i + 1]);
    bs.add(px[i + 2]);
  }

  for (var x = 0; x < w; x += 2) {
    add(x, 0);
    add(x, h - 1);
  }
  for (var y = 0; y < h; y += 2) {
    add(0, y);
    add(w - 1, y);
  }
  int median(List<int> v) => (v..sort())[v.length ~/ 2];
  return (median(rs), median(gs), median(bs));
}

/// The alpha channel of [image], one byte per pixel.
Uint8List _alpha(img.Image image) {
  final px = image.getBytes(order: img.ChannelOrder.rgba);
  final out = Uint8List(image.width * image.height);
  for (var i = 0; i < out.length; i++) {
    out[i] = px[i * 4 + 3];
  }
  return out;
}

/// Splits a cut-out sheet into [count] figures, left to right.
///
/// Figures are found by the empty columns between them; when the columns do
/// not give exactly [count] figures, the sheet is cut in equal parts.
List<img.Image> splitSheet(img.Image sheet, int count) {
  final w = sheet.width, h = sheet.height;
  final alpha = _alpha(sheet);
  final filled = List<int>.filled(w, 0);
  for (var y = 0; y < h; y += 2) {
    for (var x = 0; x < w; x++) {
      if (alpha[y * w + x] > 128) filled[x]++;
    }
  }
  final min = math.max(2, (h / 2 * 0.004).round());
  final runs = <(int, int)>[];
  int? start;
  for (var x = 0; x <= w; x++) {
    final on = x < w && filled[x] >= min;
    if (on && start == null) start = x;
    if (!on && start != null) {
      runs.add((start, x));
      start = null;
    }
  }
  // Specks and loose strands are not figures.
  runs.removeWhere((r) => r.$2 - r.$1 < w / count * 0.12);

  final cuts = <int>[0];
  if (runs.length == count) {
    for (var i = 0; i < count - 1; i++) {
      cuts.add((runs[i].$2 + runs[i + 1].$1) ~/ 2);
    }
  } else {
    for (var i = 1; i < count; i++) {
      cuts.add((w * i / count).round());
    }
  }
  cuts.add(w);
  return [
    for (var i = 0; i < count; i++)
      img.copyCrop(
        sheet,
        x: cuts[i],
        y: 0,
        width: cuts[i + 1] - cuts[i],
        height: h,
      ),
  ];
}

/// [image] cropped to its opaque pixels, or null when it has none worth
/// keeping.
img.Image? trimToFigure(img.Image image) {
  final w = image.width, h = image.height;
  final alpha = _alpha(image);
  var x0 = w, y0 = h, x1 = -1, y1 = -1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (alpha[y * w + x] <= 128) continue;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
  if (x1 < 0 || y1 - y0 < h * 0.2) return null;
  return img.copyCrop(
    image,
    x: x0,
    y: y0,
    width: x1 - x0 + 1,
    height: y1 - y0 + 1,
  );
}

/// Every figure on one transparent canvas of the same size, feet on the
/// bottom edge and centered, scaled so the canvas is at most [maxHeight]
/// tall. The engine sizes a character's card from that canvas, so swapping
/// emotions never moves or resizes them.
List<Uint8List> alignFigures(List<img.Image> figures, {int maxHeight = 1024}) {
  final cw = figures.map((f) => f.width).reduce(math.max);
  final ch = figures.map((f) => f.height).reduce(math.max);
  final scale = ch > maxHeight ? maxHeight / ch : 1.0;
  final outW = math.max(1, (cw * scale).round());
  final outH = math.max(1, (ch * scale).round());
  return [
    for (final f in figures)
      () {
        final fw = math.max(1, (f.width * scale).round());
        final fh = math.max(1, (f.height * scale).round());
        final scaled = scale == 1.0
            ? f
            : img.copyResize(
                f,
                width: fw,
                height: fh,
                interpolation: img.Interpolation.average,
              );
        final canvas = img.Image(width: outW, height: outH, numChannels: 4);
        img.compositeImage(
          canvas,
          scaled,
          dstX: (outW - fw) ~/ 2,
          dstY: outH - fh,
          blend: img.BlendMode.direct,
        );
        return img.encodePng(canvas);
      }(),
  ];
}

/// A whole sheet of [count] figures, as drawn, into aligned sprite PNGs.
/// Throws [FormatException] when the image does not decode or a figure is
/// missing.
List<Uint8List> spritesFromSheet(Uint8List bytes, int count) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('Sheet does not decode');
  final cut = cutOutBackground(decoded);
  final figures = [
    for (final part in splitSheet(cut, count)) trimToFigure(part),
  ];
  if (figures.any((f) => f == null)) {
    throw const FormatException('A figure is missing from the sheet');
  }
  return alignFigures(figures.cast<img.Image>());
}

/// Separate pictures, one figure each, into aligned sprite PNGs. A picture
/// with no figure in it comes back as null.
List<Uint8List?> spritesFromSingles(List<Uint8List> pictures) {
  final figures = <img.Image?>[
    for (final bytes in pictures)
      () {
        final decoded = img.decodeImage(bytes);
        return decoded == null ? null : trimToFigure(cutOutBackground(decoded));
      }(),
  ];
  final present = figures.whereType<img.Image>().toList();
  if (present.isEmpty) return List.filled(pictures.length, null);
  final aligned = alignFigures(present);
  var next = 0;
  return [for (final f in figures) f == null ? null : aligned[next++]];
}
