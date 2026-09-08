import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/app_settings_provider.dart';
import '../theme/app_colors.dart';
import '../theme/theme_font_provider.dart';
import '../theme/theme_provider.dart';
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
          if (bytes != null)
            Positioned.fill(
              child: Opacity(
                opacity: preset.bgOpacity.clamp(0.0, 1.0),
                child: !batterySaver && preset.bgBlur > 0
                    ? ImageFiltered(
                        imageFilter: ImageFilter.blur(
                          sigmaX: preset.bgBlur,
                          sigmaY: preset.bgBlur,
                          tileMode: TileMode.clamp,
                        ),
                        child: Image.memory(
                          bytes,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                      )
                    : Image.memory(
                        bytes,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
              ),
            ),
          if (!batterySaver && preset.bgNoiseOpacity > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: NoiseOverlay(
                  opacity: preset.bgNoiseOpacity,
                  intensity: preset.bgNoiseIntensity,
                ),
              ),
            ),
          // Shares a single backdrop blur pass across every grouped
          // BackdropFilter below (nav bar, header, glass surfaces) instead of
          // each re-blurring the backdrop independently every frame.
          BackdropGroup(child: child),
        ],
      ),
    );
  }
}
