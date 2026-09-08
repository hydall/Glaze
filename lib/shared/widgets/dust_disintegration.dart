import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// iOS-style "disintegrate into dust" delete effect.
///
/// [DustParticles.capture] snapshots a [RepaintBoundary] (found via a
/// [GlobalKey]) and decomposes it into a cloud of coloured particles sampled
/// from the rendered pixels. [DustPainter] then animates that cloud: a wave
/// sweeps left→right, each particle drifts up-and-out, shrinks and fades — the
/// same feel as deleting a Home-Screen app on iOS.
///
/// Usage: wrap the widget in `RepaintBoundary(key: k)`, call
/// `DustParticles.capture(k)`, then paint with a `CustomPaint(painter:
/// DustPainter(data, controller.value))` sized to the original box while an
/// [AnimationController] runs 0→1.
class DustParticles {
  final List<DustParticle> particles;
  final int columns;
  final int rows;

  const DustParticles(this.particles, this.columns, this.rows);

  /// Snapshots the boundary behind [key] and builds the particle cloud.
  ///
  /// Returns `null` when the boundary can't be captured (e.g. the widget was
  /// already unmounted) so callers can fall back to an instant removal.
  static Future<DustParticles?> capture(
    GlobalKey key, {
    // Higher column count → smaller cells → a finer, more granular dust cloud
    // (closer to the fine iOS "app crumble" powder than coarse chunks). Kept
    // moderate so bulk delete — several cards crumbling at once — stays smooth.
    int columns = 36,
    double pixelRatio = 1.6,
  }) async {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final ro = ctx.findRenderObject();
    if (ro is! RenderRepaintBoundary) return null;

    final ui.Image image = await ro.toImage(pixelRatio: pixelRatio);
    final ByteData? byteData =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final int w = image.width;
    final int h = image.height;
    image.dispose();
    if (byteData == null || w == 0 || h == 0) return null;
    final Uint8List bytes = byteData.buffer.asUint8List();

    final int cols = columns;
    final double cellPx = w / cols;
    final int rows = (h / cellPx).round().clamp(1, 512);
    // Fixed seed → the scatter pattern is stable across repaints of one run.
    final rnd = math.Random(0x9E3779B9);
    final list = <DustParticle>[];

    for (var r = 0; r < rows; r++) {
      final int cy = (((r + 0.5) * h / rows).floor()).clamp(0, h - 1);
      for (var c = 0; c < cols; c++) {
        final int cx = (((c + 0.5) * w / cols).floor()).clamp(0, w - 1);
        final int idx = (cy * w + cx) * 4;
        final int a = bytes[idx + 3];
        if (a < 8) continue; // skip the transparent rounded-corner pixels
        final color = Color.fromARGB(a, bytes[idx], bytes[idx + 1],
            bytes[idx + 2]);
        // Disperse mostly upward, fanned out ±~45°.
        final double angle =
            -math.pi / 2 + (rnd.nextDouble() - 0.5) * 1.5;
        list.add(DustParticle(
          nx: (c + 0.5) / cols,
          ny: (r + 0.5) / rows,
          color: color,
          dirX: math.cos(angle),
          dirY: math.sin(angle),
          speed: 0.55 + rnd.nextDouble() * 0.9,
          jitter: rnd.nextDouble(),
        ));
      }
    }
    return DustParticles(list, cols, rows);
  }
}

/// A single sampled speck of the disintegrating widget.
class DustParticle {
  final double nx; // normalised centre x (0..1)
  final double ny; // normalised centre y (0..1)
  final Color color;
  final double dirX; // dispersal direction
  final double dirY;
  final double speed; // per-particle velocity multiplier
  final double jitter; // 0..1 randomiser for wave timing

  const DustParticle({
    required this.nx,
    required this.ny,
    required this.color,
    required this.dirX,
    required this.dirY,
    required this.speed,
    required this.jitter,
  });
}

class DustPainter extends CustomPainter {
  final DustParticles data;

  /// Overall animation progress, 0 (intact) → 1 (gone).
  final double t;

  DustPainter(this.data, this.t);

  // How far into the run the left→right sweep is still starting new particles.
  static const double _sweep = 0.35;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.particles.isEmpty) return;
    final paint = Paint()..style = PaintingStyle.fill;
    // Overlap cells so the round fragments still read as a solid card before
    // it breaks up (circles cover less of a cell than the equivalent rect,
    // so they need a bit more overlap to hide the gaps between them).
    final double baseW = size.width / data.columns * 1.55;
    final double baseH = size.height / data.rows * 1.55;
    final double travel = size.height * 0.55;
    final double window = 1 - _sweep;

    for (final p in data.particles) {
      final double delay = p.nx * _sweep + p.jitter * 0.06 * _sweep;
      final double lt = ((t - delay) / window).clamp(0.0, 1.0);

      final double disp = lt * lt; // accelerate outward
      final double dx =
          p.dirX * p.speed * travel * disp + disp * size.width * 0.12;
      final double dy = p.dirY * p.speed * travel * disp;

      final double cx = p.nx * size.width + dx;
      final double cy = p.ny * size.height + dy;

      final double fade = 1 - lt;
      final double scale = 1 - lt * 0.55;
      paint.color = p.color.withValues(alpha: p.color.a * fade);
      canvas.drawCircle(
        Offset(cx, cy),
        math.max(baseW, baseH) / 2 * scale,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(DustPainter old) => old.t != t || old.data != data;
}
