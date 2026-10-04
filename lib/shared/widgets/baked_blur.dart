import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// One Gaussian-blurred copy of an image, rasterised once and shared app-wide.
///
/// Both users of this are the same trade: a blur that would otherwise be
/// re-applied on the raster thread every frame is paid for once and afterwards
/// only sampled. [BlurredImage] draws the result as the app background;
/// [CardBackdrop] hands it to glass surfaces that sit over that background so
/// they can skip their own `BackdropFilter`.
///
/// Bakes are keyed by everything that changes their pixels, so the per-screen
/// copies of [GlazeBackground] share one texture instead of each baking its
/// own, and a screen that is pushed and popped does not re-blur.
abstract final class BakedBlurCache {
  /// One live background plus the one it is replacing (a theme switch, a
  /// rotation) is all that is ever needed at once.
  static const int _maxEntries = 3;

  static final Map<BakedBlurKey, ui.Image> _entries = {};

  /// Bakes performed since the last [debugResetBakeCount]. Test-only hook
  /// asserting that a steady-state repaint does not re-blur.
  @visibleForTesting
  static int bakeCount = 0;

  @visibleForTesting
  static int get size => _entries.length;

  @visibleForTesting
  static void debugResetBakeCount() => bakeCount = 0;

  @visibleForTesting
  static void clear() {
    for (final image in _entries.values) {
      image.dispose();
    }
    _entries.clear();
  }

  /// Returns an owned clone of the bake for [key], creating it from [source]
  /// when it is not cached yet. Callers dispose what they get back; the cache
  /// keeps its own handle, so an eviction never pulls pixels out from under a
  /// widget that is still painting them.
  static ui.Image obtain(BakedBlurKey key, ui.Image source) {
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached; // refresh LRU order
      return cached.clone();
    }
    final baked = _bake(key, source);
    bakeCount++;
    _entries[key] = baked;
    while (_entries.length > _maxEntries) {
      final oldest = _entries.keys.first;
      _entries.remove(oldest)!.dispose();
    }
    return baked.clone();
  }

  static ui.Image _bake(BakedBlurKey key, ui.Image source) {
    final bounds = Rect.fromLTWH(
      0,
      0,
      key.width.toDouble(),
      key.height.toDouble(),
    );
    final logical = Rect.fromLTWH(0, 0, key.size.width, key.size.height);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, bounds);
    // Draw in logical units under the bake scale, exactly as the widget layer
    // would have been rasterised: the image is resampled at the same net scale
    // and the blur sigma stays in the units the engine would have applied it
    // in. Matching the transform rather than pre-multiplying by hand is what
    // keeps this interchangeable with an [ImageFiltered] of the same sigma.
    // Scale per axis from the *rounded* raster size, not from `scale` itself:
    // rounding width and height independently makes the two axes differ by a
    // fraction of a percent, and a texture that does not map exactly onto its
    // box gets re-cropped when it is drawn back.
    canvas.scale(key.width / key.size.width, key.height / key.size.height);
    // `saveLayer` + an image filter is what [ImageFiltered] compiles down to:
    // the child is rendered into a layer whose bounds are its paint bounds,
    // then the filter is applied with the edges clamped.
    canvas.saveLayer(
      logical,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: key.sigma,
          sigmaY: key.sigma,
          tileMode: TileMode.clamp,
        ),
    );
    paintImage(
      canvas: canvas,
      rect: logical,
      image: source,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
    );
    canvas.restore();
    // A flat black wash commutes with the blur (a constant-weight lerp towards
    // black is affine, and a Gaussian is linear), so dimming after the blur is
    // the same picture as dimming the image and blurring that. Baking it in
    // lets a sampled backdrop carry the dim the app background paints over the
    // image, which the sample would otherwise cover up.
    if (key.dim > 0) {
      canvas.drawRect(
        logical,
        Paint()..color = const Color(0xFF000000).withValues(alpha: key.dim),
      );
    }
    final picture = recorder.endRecording();
    // Sync so the texture stays on the GPU: this is drawn again every frame,
    // and a readback would trade the per-frame blur for a per-frame upload.
    final image = picture.toImageSync(key.width, key.height);
    picture.dispose();
    return image;
  }
}

/// Identity of one baked blur: everything that changes its pixels.
@immutable
class BakedBlurKey {
  /// Source image. Must implement value equality — all of Flutter's built-in
  /// providers do.
  final ImageProvider provider;

  /// Blur sigma in logical pixels.
  final double sigma;

  /// Flat black wash applied after the blur, 0..1.
  final double dim;

  /// Logical size the image is fitted to with `BoxFit.cover`.
  final Size size;

  /// Baked pixels per logical pixel. Usually well below the device pixel
  /// ratio — see [scaleFor].
  final double scale;

  final int width;
  final int height;

  BakedBlurKey._({
    required this.provider,
    required this.sigma,
    required this.dim,
    required this.size,
    required this.scale,
  }) : width = (size.width * scale).round().clamp(1, 1 << 15),
       height = (size.height * scale).round().clamp(1, 1 << 15);

  factory BakedBlurKey({
    required ImageProvider provider,
    required double sigma,
    required double dim,
    required Size size,
    required double devicePixelRatio,
  }) => BakedBlurKey._(
    provider: provider,
    sigma: sigma,
    dim: dim,
    size: size,
    scale: scaleFor(
      sigma: sigma,
      size: size,
      devicePixelRatio: devicePixelRatio,
    ),
  );

  /// Texels kept per sigma. A Gaussian leaves essentially nothing below a
  /// wavelength of 2σ (a component there comes out at under 1% of its
  /// amplitude), so sampling the result three times per sigma is already well
  /// past what it can carry. Baking at that resolution instead of the device's
  /// turns a ~10 MB full-screen texture into tens of kilobytes and makes the
  /// bake itself proportionally cheaper, with nothing visible to lose.
  static const double _texelsPerSigma = 3;

  /// Never bake a texture smaller than this on its short side. What the sigma
  /// rule above does not account for is the *edge*: [TileMode.clamp] resolves
  /// the border at one texel, so too coarse a bake shows a visible step there.
  /// Measured against a full-resolution bake of a deliberately hard-edged
  /// image, 96 texels leaves the outermost pixels ~7% off; 160 brings that to
  /// ~2% with the interior under half a percent, for ~200 KB of texture
  /// instead of ~10 MB.
  static const double _minShortSide = 160;

  /// A 4K bake is already 32 MB of texture; nothing is allowed past that even
  /// if the sigma is tiny.
  static const int _maxPixels = 1 << 23;

  static double scaleFor({
    required double sigma,
    required Size size,
    required double devicePixelRatio,
  }) {
    final shortSide = math.min(size.width, size.height);
    if (shortSide <= 0 || !size.isFinite) return devicePixelRatio;
    var scale = devicePixelRatio;
    if (sigma > 0) {
      scale = math.min(scale, _texelsPerSigma / sigma);
    }
    scale = math.min(scale, math.sqrt(_maxPixels / (size.width * size.height)));
    // The floor wins over the sigma rule, never over the memory ceiling.
    return math.min(
      devicePixelRatio,
      math.max(scale, math.min(devicePixelRatio, _minShortSide / shortSide)),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BakedBlurKey &&
      other.provider == provider &&
      other.sigma == sigma &&
      other.dim == dim &&
      other.size == size &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(provider, sigma, dim, size, scale);
}
