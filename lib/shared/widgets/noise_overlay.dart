import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Film-grain overlay: a grid of square cells (cell size grows with the
/// painted area, 1..10 logical px) each filled with [tint] at a random alpha
/// scaled by `intensity * opacity`.
///
/// The grain is baked once per (cell size, tint, alpha scale) into a small
/// repeating tile shared by every [NoiseOverlay] in the app; painting is a
/// single shader-filled drawRect. The previous implementation cached a
/// full-size image per instance keyed by its exact size, so any surface whose
/// size animates (bottom sheets mid-drag/open) missed the cache and fell back
/// to drawing up to 50k rects plus scheduling a screen-sized `toImage` every
/// frame — by far the largest raster-thread cost in the app.
class NoiseOverlay extends StatefulWidget {
  final double opacity;
  final double intensity;
  final Color tint;

  const NoiseOverlay({
    super.key,
    required this.opacity,
    required this.intensity,
    this.tint = const Color(0xFF000000),
  });

  @override
  State<NoiseOverlay> createState() => _NoiseOverlayState();
}

class _NoiseOverlayState extends State<NoiseOverlay> {
  void _onTileReady() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final alphaScale = (widget.intensity * widget.opacity).clamp(0.0, 1.0);
    if (alphaScale <= 0) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size.isEmpty || !size.isFinite) return const SizedBox.shrink();
        final step = _NoiseTileCache.stepFor(size);
        final tile = _NoiseTileCache.get(
          step: step,
          tint: widget.tint,
          alphaScale: alphaScale,
          onReady: _onTileReady,
        );
        // Tile still baking (first frames of a cold start / new theme values):
        // draw nothing rather than anything expensive — at grain alphas the
        // one-or-two-frame gap is imperceptible.
        if (tile == null) return const SizedBox.shrink();
        return CustomPaint(
          painter: _NoiseTilePainter(tile: tile, step: step),
          size: Size.infinite,
        );
      },
    );
  }
}

class _NoiseTilePainter extends CustomPainter {
  final ui.Image tile;
  final int step;
  late final Paint _paint = Paint()
    ..shader = ui.ImageShader(
      tile,
      TileMode.repeated,
      TileMode.repeated,
      Matrix4.diagonal3Values(
        step.toDouble(),
        step.toDouble(),
        1,
      ).storage,
      filterQuality: FilterQuality.none,
    );

  _NoiseTilePainter({required this.tile, required this.step});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, _paint);
  }

  @override
  bool shouldRepaint(covariant _NoiseTilePainter old) =>
      tile != old.tile || step != old.step;
}

/// App-wide cache of baked noise tiles.
///
/// A tile is [cells]×[cells] grain cells rendered at 1px each; the shader
/// matrix in [_NoiseTilePainter] scales it so one texel spans one `step`-sized
/// cell, and [TileMode.repeated] extends it over any surface. Tiles are tiny
/// (64 KiB) and keyed by everything that affects their pixels, so they are
/// kept for the lifetime of the app.
abstract final class _NoiseTileCache {
  static const int cells = 128;

  static final Map<String, ui.Image> _ready = {};
  static final Map<String, Set<VoidCallback>> _waiters = {};

  /// Same cell-size curve as the original per-size painter: one logical px
  /// for small chips, up to 10 for full-screen surfaces.
  static int stepFor(Size size) {
    final pixels = size.width * size.height;
    return (pixels / 50000).ceil().clamp(1, 10);
  }

  static ui.Image? get({
    required int step,
    required Color tint,
    required double alphaScale,
    required VoidCallback onReady,
  }) {
    final base = '${tint.toARGB32()}|${(alphaScale * 1000).round()}';
    final key = '$step|$base';
    final image = _ready[key];
    if (image != null) return image;

    final waiters = _waiters[key];
    if (waiters != null) {
      waiters.add(onReady);
    } else {
      _waiters[key] = {onReady};
      _bake(key, tint, alphaScale);
    }

    // While the exact cell size bakes, fall back to an existing tile of the
    // same tint/alpha with the nearest cell size so grain doesn't blink out
    // mid-animation when a resizing surface crosses a step threshold.
    ui.Image? nearest;
    var nearestDelta = 1 << 30;
    for (final entry in _ready.entries) {
      final parts = entry.key.split('|');
      if ('${parts[1]}|${parts[2]}' != base) continue;
      final delta = (int.parse(parts[0]) - step).abs();
      if (delta < nearestDelta) {
        nearestDelta = delta;
        nearest = entry.value;
      }
    }
    return nearest;
  }

  static Future<void> _bake(String key, Color tint, double alphaScale) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final random = Random(42);
    final paint = Paint();
    for (var x = 0; x < cells; x++) {
      for (var y = 0; y < cells; y++) {
        final v = random.nextDouble();
        paint.color = tint.withValues(alpha: (v * alphaScale).clamp(0.0, 1.0));
        canvas.drawRect(
          Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1),
          paint,
        );
      }
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(cells, cells);
    picture.dispose();
    _ready[key] = image;
    final waiters = _waiters.remove(key);
    if (waiters != null) {
      for (final notify in waiters) {
        notify();
      }
    }
  }
}
