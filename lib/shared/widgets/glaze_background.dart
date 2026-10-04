import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/app_settings_provider.dart';
import '../theme/app_colors.dart';
import '../theme/theme_font_provider.dart';
import '../theme/theme_provider.dart';
import 'blurred_image.dart';
import 'card_backdrop.dart';
import 'noise_overlay.dart';

class GlazeBackground extends ConsumerWidget {
  final Widget child;
  final Color? backgroundColor;

  const GlazeBackground({super.key, required this.child, this.backgroundColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(effectiveBgImageBytesProvider);
    final preset = ref.watch(themeProvider).activePreset;
    final batterySaver =
        ref.watch(appSettingsProvider).value?.batterySaver ?? false;
    final base = backgroundColor ?? context.cs.surface;

    return Container(
      color: base,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (bytes != null) ...[
            Positioned.fill(
              // The blur is baked once per (image, sigma, size) rather than
              // re-applied on every composite — see [BlurredImage]. Battery
              // saver keeps dropping it entirely.
              child: BlurredImage(
                image: MemoryImage(bytes),
                sigma: batterySaver ? 0 : preset.bgBlur,
              ),
            ),
            // Darken the image with a black overlay instead of fading it out:
            // a translucent image would let [base] (and, in the chat, the
            // Flutter surface behind the transparent WebView) bleed through.
            if (preset.bgDim > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(
                      alpha: preset.bgDim.clamp(0.0, 1.0),
                    ),
                  ),
                ),
              ),
          ],
          if (!batterySaver && preset.bgNoiseOpacity > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: NoiseOverlay(
                  opacity: preset.bgNoiseOpacity,
                  intensity: preset.bgNoiseIntensity,
                ),
              ),
            ),
          // Deliberately no `BackdropGroup` here. Grouping would make every
          // glass surface below share one backdrop capture, taken where the
          // first grouped filter paints — so a nav bar or header drawn after
          // the scrolling body would blur the app background instead of the
          // content actually under it. See the note in [GlassSurface].
          //
          // [CardBackdrop] instead bakes the background blurred once so that
          // surfaces opting in with `GlassSurface.backdropSample` can read it
          // as a texture instead of each blurring the backdrop per frame.
          bytes != null && preset.elementBlur > 0 && !batterySaver
              ? CardBackdrop(
                  image: MemoryImage(bytes),
                  // What a card actually has under it is the image blurred by
                  // `bgBlur` and then by its own `elementBlur`. Two Gaussians
                  // in a row are one, so the bake uses the combined sigma —
                  // baking at `elementBlur` alone would leave a sampling card
                  // visibly sharper than its blurring neighbours.
                  sigma: CardBackdrop.combineSigma(
                    preset.bgBlur,
                    preset.elementBlur,
                  ),
                  // Baked in, because the sample paints over the dim the stack
                  // above already drew and would otherwise lose it.
                  dim: preset.bgDim.clamp(0.0, 1.0),
                  child: child,
                )
              : child,
        ],
      ),
    );
  }
}
