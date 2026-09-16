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
import 'card_backdrop.dart';

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

  /// Set when this surface floats over the chat `InAppWebView` on a platform
  /// whose WebView pixels a Flutter [BackdropFilter] cannot sample (see
  /// `chatWebViewBlurIsFlutterSide`). The blur is then reproduced by a CSS
  /// `backdrop-filter` strip *inside* the WebView, mirrored via
  /// `BlurRegionTracker` → `setOverlayBlurRegions`, and setting this drops the
  /// redundant Flutter pass entirely — the surface paints only tint / border /
  /// noise. Where the WebView *is* part of the Flutter frame this stays false
  /// and the surface blurs it like any other content.
  final bool blurViaWebView;

  /// Shares one backdrop capture with every other [GlassSurface] painted under
  /// the same key, so the engine runs the blur once instead of once per
  /// surface. Left null (and inherited from an enclosing [GlassBackdropGroup]
  /// when there is one) this is an ordinary, independent [BackdropFilter].
  ///
  /// The capture is taken where the *first* surface of the group paints, and
  /// every later member reads that same snapshot. Sharing is therefore only
  /// correct while nothing is drawn into a member's own rectangle between that
  /// capture and the member's paint — in practice: members must not overlap
  /// each other, and nothing may be painted over one of them in between. Two
  /// surfaces that do overlap must stay on separate keys, or the upper one
  /// blurs pixels that no longer exist under it.
  ///
  /// Content scrolling *under* the whole group is fine, and is the case this
  /// exists for: it is painted before the capture, so every member still blurs
  /// the live content beneath it.
  final BackdropKey? backdropKey;

  /// Samples a once-baked, already-blurred app-background texture for this
  /// surface's backdrop instead of running a `BackdropFilter`. Only valid when
  /// the surface sits over the *static* app background (which does not scroll;
  /// content scrolls over it) — a `MenuGroup` card, not a header over a list.
  /// Falls back to a normal `BackdropFilter` when there is no background image
  /// or the texture is not baked yet.
  final bool backdropSample;

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
    this.backdropKey,
    this.backdropSample = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // select() so the (many) glass surfaces on screen only rebuild when the
    // values they actually paint with change, not on every settings write.
    final preset = ref.watch(themeProvider.select((t) => t.activePreset));
    final batterySaver = ref.watch(
      appSettingsProvider.select((s) => s.value?.batterySaver ?? false),
    );
    return _build(
      context,
      preset,
      batterySaver,
      backdropKey ?? GlassBackdropGroup.of(context),
    );
  }

  Widget _build(
    BuildContext context,
    ThemePreset preset,
    bool batterySaver,
    BackdropKey? groupKey,
  ) {
    final alpha = batterySaver ? 1.0 : preset.elementOpacity.clamp(0.0, 1.0);
    final defaultBase = Theme.of(context).colorScheme.surfaceContainerHighest;
    final effectiveTint = tint;
    final tinted = effectiveTint == null
        ? defaultBase.withValues(alpha: alpha)
        : effectiveTint.withValues(
            alpha: (effectiveTint.a * alpha).clamp(0.0, 1.0),
          );
    // When what is behind this surface is a known opaque colour, compositing
    // the tint against it here gives the same pixels with none of the work:
    // no per-frame blend, nothing behind to read, and — through the check
    // below — no blur pass, since blurring one flat colour returns it. An
    // opaque card also gives the engine something it can draw over instead of
    // through, which is what the sheet header's strip capture reads.
    final behind = FlatBackdrop.of(context);
    final fillColor = behind == null
        ? tinted
        : Color.alphaBlend(tinted, behind);
    // With the blur mirrored into the WebView, the Flutter BackdropFilter is
    // dropped here: it would sample the platform-view hole rather than the web
    // content, and cost a blur pass every frame for nothing. A fully opaque
    // fill hides the backdrop too, so the blur would be invisible and only
    // cost a saveLayer + blur every frame.
    final blur =
        (batterySaver ||
            PerfDebug.noGlassBlur ||
            blurViaWebView ||
            // A fully opaque fill hides the backdrop, so the blur would be
            // invisible and only cost a saveLayer and a pass every frame. A
            // surface composited against a flat backdrop above lands here too.
            fillColor.a >= 1.0)
        ? 0.0
        : preset.elementBlur;

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
        // Anything inside this surface is painted *over* its own blur, so it
        // can never share this surface's backdrop capture, and what is under it
        // is this surface rather than the app background. Closing both scopes
        // here is what keeps a nested glass element — the active pill inside a
        // tab strip, a card inside a card — on its own honest blur without
        // anyone having to remember.
        child: GlassBackdropGroup.none(
          child: CardBackdrop.closed(child: RepaintBoundary(child: child)),
        ),
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

    final sample = (backdropSample && !batterySaver && blur > 0)
        ? CardBackdrop.of(context)
        : null;

    final surface = ClipRRect(
      borderRadius: borderRadius,
      // Grouping is opt-in per surface ([backdropKey] / [GlassBackdropGroup])
      // rather than ambient. An earlier attempt put a `BackdropGroup` around
      // the whole app background and made every surface `.grouped`: that made
      // them all share the capture taken at the first one, so chrome painted
      // after the scrolling body blurred the app background instead of the
      // content actually under it, and the effect disappeared inside the
      // Android overscroll stretch. Sharing is only safe between surfaces that
      // do not overlap and have nothing drawn over them in between, which is a
      // judgement each call site has to make.
      child: blur > 0
          ? RepaintBoundary(
              child: sample != null
                  ? CardBackdropSample(data: sample, child: withNoise)
                  : BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                      backdropGroupKey: groupKey,
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

/// Marks a subtree whose [GlassSurface]s share a single backdrop capture: the
/// engine blurs once for the group instead of once per surface, which on a
/// tiled mobile GPU is the difference between one framebuffer resolve per
/// frame and one per surface.
///
/// Only wrap surfaces that satisfy the rule documented on
/// [GlassSurface.backdropKey]: they must not overlap each other, and nothing
/// may be painted over one of them between the group's first paint and theirs.
/// A row of chips or a header and a nav bar at opposite edges qualify; a badge
/// or a pill sitting on top of another glass surface does not — and does not
/// have to be excluded by hand, because [GlassSurface] closes the group around
/// its own children.
class GlassBackdropGroup extends StatefulWidget {
  final Widget child;

  const GlassBackdropGroup({super.key, required this.child});

  /// Closes any enclosing group for [child]: the surfaces inside get their own
  /// independent blur again.
  static Widget none({Key? key, required Widget child}) =>
      _GlassBackdropScope(key: key, backdropKey: null, child: child);

  /// The key [GlassSurface] should paint with, or null outside a group.
  static BackdropKey? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_GlassBackdropScope>()
      ?.backdropKey;

  @override
  State<GlassBackdropGroup> createState() => _GlassBackdropGroupState();
}

class _GlassBackdropGroupState extends State<GlassBackdropGroup> {
  // Stable for the life of the group: a fresh key every build would be a fresh
  // capture every frame, which is exactly what the group exists to avoid.
  final BackdropKey _key = BackdropKey();

  @override
  Widget build(BuildContext context) =>
      _GlassBackdropScope(backdropKey: _key, child: widget.child);
}

class _GlassBackdropScope extends InheritedWidget {
  final BackdropKey? backdropKey;

  const _GlassBackdropScope({
    super.key,
    required this.backdropKey,
    required super.child,
  });

  @override
  bool updateShouldNotify(covariant _GlassBackdropScope oldWidget) =>
      oldWidget.backdropKey != backdropKey;
}

/// Names the flat, opaque colour that sits behind a subtree, so a
/// [GlassSurface] inside it can composite its tint against that colour once
/// instead of blending over it every frame — and skip its blur, since blurring
/// one uniform colour gives that colour back.
///
/// The surfaces look exactly the same: the same tint over the same backdrop,
/// resolved ahead of time rather than by the compositor. What goes away is a
/// blend, a backdrop read and a render target per surface.
///
/// Set it where the colour behind is genuinely opaque and uniform under
/// everything in the subtree, as an opaque modal sheet is: its cards sit on the
/// sheet's own colour and never overlap each other. It does not hold for chrome
/// painted over scrolling content, which is why a sheet marks its body and not
/// its header.
class FlatBackdrop extends InheritedWidget {
  /// The opaque colour behind this subtree, or null where it is not flat —
  /// which re-opens the blur inside a marked one.
  final Color? color;

  const FlatBackdrop({super.key, required this.color, required super.child});

  static Color? of(BuildContext context) {
    final color = context
        .dependOnInheritedWidgetOfExactType<FlatBackdrop>()
        ?.color;
    // A backdrop that is not itself opaque cannot stand in for what is behind
    // it, so it is no better than not knowing.
    return (color != null && color.a >= 1.0) ? color : null;
  }

  @override
  bool updateShouldNotify(covariant FlatBackdrop oldWidget) =>
      oldWidget.color != color;
}
