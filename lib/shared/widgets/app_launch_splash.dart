import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'glaze_logo.dart';

class AppLaunchSplash extends StatefulWidget {
  final bool isReady;
  final Widget child;

  const AppLaunchSplash({
    super.key,
    required this.isReady,
    required this.child,
  });

  @override
  State<AppLaunchSplash> createState() => _AppLaunchSplashState();
}

class _AppLaunchSplashState extends State<AppLaunchSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
      value: widget.isReady ? 1 : 0,
    );
  }

  @override
  void didUpdateWidget(covariant AppLaunchSplash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isReady && widget.isReady) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = theme.scaffoldBackgroundColor;
    final accent = theme.colorScheme.primary;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        // Timeline (t = 0..1 over 1200ms once ready):
        //   0.00–0.22  logo pops in
        //   0.22–0.46  HOLD — logo static & opaque, the child paints and
        //              decodes its images behind an opaque cover
        //   0.46–0.90  cover + logo fade out, revealing the settled child
        //
        // The child is painted at full opacity from the first frame (never
        // wrapped in Opacity(0), which would make RenderOpacity skip painting
        // and defer the list's expensive first layout + image decodes until it
        // became visible — the jank). By keeping it painted but hidden behind
        // an opaque cover during the hold, that heavy work happens while the
        // logo is static, so the reveal is a pure crossfade over already
        // rasterized content and stays smooth.
        final t = widget.isReady ? _controller.value : 0.0;

        final logoIntroScale = Tween<double>(
          begin: 0.78,
          end: 1,
        ).transform(Curves.easeOutBack.transform(_interval(t, 0, 0.22)));
        final logoExitScale = Tween<double>(
          begin: 1,
          end: 1.12,
        ).transform(Curves.easeInCubic.transform(_interval(t, 0.46, 0.90)));
        final logoScale = logoIntroScale * logoExitScale;

        final reveal = Curves.easeInOutCubic.transform(
          _interval(t, 0.46, 0.90),
        );
        final coverOpacity = (1 - reveal).clamp(0.0, 1.0);
        final logoOpacity =
            (1 - Curves.easeIn.transform(_interval(t, 0.50, 0.86))).clamp(
              0.0,
              1.0,
            );

        return ColoredBox(
          color: background,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Painted at full opacity immediately so first layout + image
              // decodes happen during the hold, hidden behind the cover below.
              IgnorePointer(
                ignoring: coverOpacity > 0.02,
                child: widget.child,
              ),
              // Opaque cover: hides the settling child, then fades to reveal it.
              if (coverOpacity > 0)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: coverOpacity,
                      child: ColoredBox(color: background),
                    ),
                  ),
                ),
              // Logo sits above the cover, static through the hold.
              if (logoOpacity > 0)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: logoOpacity,
                      child: Center(
                        child: Transform.scale(
                          scale: logoScale,
                          child: SvgPicture.string(
                            glazeFilledLogoSvg,
                            width: 176,
                            height: 176,
                            colorFilter: ColorFilter.mode(
                              accent,
                              BlendMode.srcIn,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  double _interval(double t, double start, double end) {
    if (t <= start) return 0;
    if (t >= end) return 1;
    return (t - start) / (end - start);
  }
}
