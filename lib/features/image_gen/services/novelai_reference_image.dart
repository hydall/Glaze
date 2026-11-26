import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../image_gen_models.dart';

/// Turns a picture into what NovelAI's Precise Reference takes, the way
/// NovelAI's site does it (ported from
/// https://github.com/Guppy779/NovelAI-Krita-plugin, `references.py`):
///
/// - V4.5 ([padNovelAiReference]) — scaled to fit the closest of three
///   canvases, centred, black around it and behind its transparent pixels.
/// - V5 ([cutNovelAiReference]) — scaled to cover the closest of 97 sizes and
///   cut evenly on both sides; transparency stays. A picture that already has
///   one of the sizes goes as it is.
///
/// Both first take out the settings NovelAI hides in a generated image's
/// alpha channel, which would otherwise leave it a shade transparent. The
/// site scales with pica's Lanczos3; this uses the image package's cubic
/// filter, so the pixels are close to, not identical with, the site's.
///
/// Every function returns null when the bytes cannot be decoded, so the caller
/// can fall back to sending them unchanged. Meant to run through `compute`.
Uint8List? padNovelAiReference(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final src = _rgba(decoded);
    scrubNovelAiHiddenData(src);

    final (canvasWidth, canvasHeight) = NovelAIConstants.referenceCanvas(
      src.width,
      src.height,
    );
    final ratio = src.width / src.height;
    final (fitWidth, fitHeight) = ratio > canvasWidth / canvasHeight
        ? (canvasWidth, max(1, _round(canvasWidth / ratio)))
        : (max(1, _round(canvasHeight * ratio)), canvasHeight);
    final left = _round((canvasWidth - fitWidth) / 2);
    final top = _round((canvasHeight - fitHeight) / 2);

    final resized = img.copyResize(
      src,
      width: fitWidth,
      height: fitHeight,
      interpolation: img.Interpolation.cubic,
    );

    final canvas = img.Image(
      width: canvasWidth,
      height: canvasHeight,
      numChannels: 4,
    );
    img.fill(canvas, color: img.ColorRgba8(0, 0, 0, 255));
    // The site drops the alpha channel onto black: fully clear pixels turn
    // black, the rest keep their colour.
    for (final pixel in resized) {
      final opaque = pixel.a > 0;
      canvas.setPixelRgba(
        pixel.x + left,
        pixel.y + top,
        opaque ? pixel.r : 0,
        opaque ? pixel.g : 0,
        opaque ? pixel.b : 0,
        255,
      );
    }
    return Uint8List.fromList(img.encodePng(canvas));
  } catch (_) {
    return null;
  }
}

/// The V5 reference for [bytes]; see [padNovelAiReference].
Uint8List? cutNovelAiReference(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final src = _rgba(decoded);
    final scrubbed = scrubNovelAiHiddenData(src);

    final (sizeWidth, sizeHeight) = NovelAIConstants.referenceCutSize(
      src.width,
      src.height,
    );
    if (sizeWidth == src.width && sizeHeight == src.height) {
      if (!scrubbed) return bytes;
      return Uint8List.fromList(img.encodePng(src));
    }

    final scale = max(sizeWidth / src.width, sizeHeight / src.height);
    final scaledWidth = max(_round(src.width * scale), sizeWidth);
    final scaledHeight = max(_round(src.height * scale), sizeHeight);
    final resized = img.copyResize(
      src,
      width: scaledWidth,
      height: scaledHeight,
      interpolation: img.Interpolation.cubic,
    );
    final cut = img.copyCrop(
      resized,
      x: (scaledWidth - sizeWidth) ~/ 2,
      y: (scaledHeight - sizeHeight) ~/ 2,
      width: sizeWidth,
      height: sizeHeight,
    );
    return Uint8List.fromList(img.encodePng(cut));
  } catch (_) {
    return null;
  }
}

/// Pictures larger than this keep their hidden data, as on the site.
const _maxScrubbedPixels = 0x1000000;

/// The marker NovelAI's hidden data starts with, one bit per pixel in the
/// lowest bit of alpha, running down the columns from the top-left.
final _hiddenDataMarker = 'stealth_pngcomp'.codeUnits;

/// Whether [image]'s alpha channel starts with NovelAI's hidden-data marker.
bool hasNovelAiHiddenData(img.Image image) {
  final width = image.width;
  final height = image.height;
  if (width * height < _hiddenDataMarker.length * 8) return false;
  for (var index = 0; index < _hiddenDataMarker.length; index++) {
    var value = 0;
    for (var bit = index * 8; bit < index * 8 + 8; bit++) {
      final alpha = image.getPixel(bit ~/ height, bit % height).a.toInt();
      value = value << 1 | alpha & 1;
    }
    if (value != _hiddenDataMarker[index]) return false;
  }
  return true;
}

/// Takes NovelAI's hidden data out of [image] in place: alpha 254 goes back
/// to 255 and 1 to 0. Returns whether there was any.
bool scrubNovelAiHiddenData(img.Image image) {
  if (image.width * image.height > _maxScrubbedPixels ||
      !hasNovelAiHiddenData(image)) {
    return false;
  }
  for (final pixel in image) {
    final alpha = pixel.a;
    if (alpha == 254) {
      pixel.a = 255;
    } else if (alpha == 1) {
      pixel.a = 0;
    }
  }
  return true;
}

/// [image] as 8-bit RGBA, so alpha reads the same for every source format.
img.Image _rgba(img.Image image) {
  if (image.format == img.Format.uint8 &&
      image.numChannels == 4 &&
      !image.hasPalette) {
    return image;
  }
  return image.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
}

/// Halves go up, as the site rounds.
int _round(double value) => (value + 0.5).floor();
