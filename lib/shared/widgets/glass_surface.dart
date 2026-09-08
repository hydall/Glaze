import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/debug/perf_debug.dart';
import '../../features/settings/app_settings_provider.dart';
import '../theme/app_colors.dart';
import '../theme/theme_preset.dart';
import '../theme/theme_provider.dart';
import 'glow_ripple.dart';
import 'noise_overlay.dart';

/// Reusable glassmorphic surface that reads `elementOpacity` / `elementBlur` /
/// `noiseOpacity` / `noiseIntensity` from the active theme preset.
///
/// Replaces ad-hoc `ClipRRect + BackdropFilter + Container(alpha 0.8)` blocks
/// that were scattered across app-bar/nav-bar/sheet/toast/menu surfaces with
/// hardcoded values.
class GlassSurface extends ConsumerWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final Color? tint;
  final BoxBorder? border;
  final List<BoxShadow>? boxShadow;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enableRipple;
  final Color? glowColor;
  final double rippleRadiusFactor;
  final double rippleIntensity;

  /// When this surface floats over the chat `InAppWebView`, its own Flutter
  /// [BackdropFilter] cannot sample the natively-composited WebView pixels, so
  /// the blur is instead reproduced by a CSS `backdrop-filter` strip *inside*
  /// the WebView (mirrored via [BlurRegionTracker] → `setOverlayBlurRegions`).
  /// Setting this drops the redundant Flutter blur pass entirely — the surface
  /// paints only tint / border / noise — which also removes the per-frame blur
  /// recompute that made the keyboard animation janky.
  final bool blurViaWebView;

  const GlassSurface({
    super.key,
    required this.child,
    required this.borderRadius,
    this.tint,
    this.border,
    this.boxShadow,
    this.onTap,
    this.onLongPress,
    this.enableRipple = false,
    this.glowColor,
    this.rippleRadiusFactor = 1.0,
    this.rippleIntensity = 0.15,
    this.blurViaWebView = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // select() so the (many) glass surfaces on screen only rebuild when the
    // values they actually paint with change, not on every settings write.
    final preset = ref.watch(themeProvider.select((t) => t.activePreset));
    final batterySaver = ref.watch(
      appSettingsProvider.select((s) => s.value?.batterySaver ?? false),
    );
    return _build(context, preset, batterySaver);
  }

  Widget _build(BuildContext context, ThemePreset preset, bool batterySaver) {
    final alpha = batterySaver ? 1.0 : preset.elementOpacity.clamp(0.0, 1.0);
    // Over the chat WebView the blur is done by an in-WebView CSS strip, so the
    // Flutter BackdropFilter is dropped here (it would sample the platform-view
    // hole, not the WebView content, and cost a blur pass every frame).
    final blur = (batterySaver || PerfDebug.noGlassBlur || blurViaWebView)
        ? 0.0
        : preset.elementBlur;
    final defaultBase = Theme.of(context).colorScheme.surfaceContainerHighest;
    final effectiveTint = tint;
    final fillColor = effectiveTint == null
        ? defaultBase.withValues(alpha: alpha)
        : effectiveTint.withValues(
            alpha: (effectiveTint.a * alpha).clamp(0.0, 1.0),
          );

    final filled = DecoratedBox(
      decoration: BoxDecoration(
        color: fillColor,
        borderRadius: borderRadius,
        border: border,
        boxShadow: boxShadow,
      ),
      // The foreground content is isolated in its own compositing layer so that
      // scrolling / press animations / streaming repaints inside it do NOT mark
      // the enclosing BackdropFilter dirty. When the backdrop behind the surface
      // is static (e.g. a bottom sheet over a still screen) the expensive blur
      // pass is then reused frame-to-frame instead of recomputed on every tick.
      child: Material(
        type: MaterialType.transparency,
        child: RepaintBoundary(child: child),
      ),
    );

    final withNoise =
        !batterySaver && !PerfDebug.noNoise && preset.noiseOpacity > 0
        ? Stack(
            fit: StackFit.passthrough,
            children: [
              filled,
              Positioned.fill(
                child: IgnorePointer(
                  // Cached on its own layer: the noise raster never changes once
                  // generated, so it must not be re-rasterised when sibling
                  // content repaints.
                  child: RepaintBoundary(
                    child: ClipRRect(
                      borderRadius: borderRadius,
                      child: NoiseOverlay(
                        opacity: preset.noiseOpacity,
                        intensity: preset.noiseIntensity,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          )
        : filled;

    final surface = ClipRRect(
      borderRadius: borderRadius,
      // Deliberately NOT `BackdropFilter.grouped`: grouped filters blur the
      // backdrop as of the enclosing BackdropGroup — i.e. only the app
      // background — so content scrolling under a glass header was ignored by
      // the blur, and the effect vanished entirely inside the Android
      // overscroll stretch transform.
      child: blur > 0
          ? RepaintBoundary(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: withNoise,
              ),
            )
          : withNoise,
    );

    final hasTapHandler = onTap != null || onLongPress != null;
    if (hasTapHandler) {
      return GlowInkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: borderRadius,
        glowColor: glowColor ?? context.cs.primary,
        radiusFactor: rippleRadiusFactor,
        intensity: rippleIntensity,
        child: surface,
      );
    }
    if (enableRipple && !batterySaver) {
      return GlowRippleOverlay(
        glowColor: glowColor ?? context.cs.primary,
        borderRadius: borderRadius,
        radiusFactor: rippleRadiusFactor,
        intensity: rippleIntensity,
        child: surface,
      );
    }
    return surface;
  }
}
