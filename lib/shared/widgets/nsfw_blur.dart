import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Draws [child] through a Gaussian blur when [enabled].
///
/// Used to cover adult catalog imagery — a card's main image and the images
/// inside a preview's bio — without hiding the character itself. A plain
/// [ImageFiltered] rather than the baked [BlurredImage] because these are
/// small, bounded images whose source changes as the grid scrolls; the baked
/// path exists for screen-sized backgrounds whose filter would otherwise be
/// recomputed on every frame.
class NsfwBlur extends StatelessWidget {
  final bool enabled;
  final Widget child;

  /// Blur radius in logical pixels. Large enough that the underlying image is
  /// unrecognizable at a glance, on a card the size of a thumbnail.
  final double sigma;

  const NsfwBlur({
    super.key,
    required this.enabled,
    required this.child,
    this.sigma = 16,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: ui.TileMode.clamp,
      ),
      child: child,
    );
  }
}
