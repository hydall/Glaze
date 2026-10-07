import 'dart:ui';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_logo.dart';
import '../onboarding_models.dart';

// ---------------------------------------------------------------------------
// Reusable onboarding sub-widgets — shared by the phone flow and the desktop
// wizard (see onboarding_desktop_wizard.dart).
// ---------------------------------------------------------------------------

/// Stories-style progress bar (Instagram / Telegram-like)
class OnboardingStoriesBar extends StatelessWidget {
  final int total;
  final int current;
  const OnboardingStoriesBar({
    super.key,
    required this.total,
    required this.current,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(total, (i) {
        final filled = i <= current;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(
              left: i == 0 ? 0 : 3,
              right: i == total - 1 ? 0 : 3,
            ),
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: const Color(0x33808080),
              ),
              child: AnimatedFractionallySizedBox(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                alignment: Alignment.centerLeft,
                widthFactor: filled ? 1.0 : 0.0,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    color: context.cs.primary,
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

/// Glass-morphism pill button to skip the entire onboarding (top-right)
class OnboardingSkipButton extends StatelessWidget {
  final VoidCallback onTap;
  const OnboardingSkipButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.cs.surface.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x4D000000),
                  blurRadius: 15,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Text(
              'onboarding_btn_skip_onboarding'.tr(),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Confirmation body shown inside the "Skip Onboarding?" bottom sheet.
class OnboardingSkipConfirmSheet extends StatelessWidget {
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  const OnboardingSkipConfirmSheet({
    super.key,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'onboarding_skip_confirm_desc'.tr(),
            style: TextStyle(
              fontSize: 15,
              height: 1.5,
              color: context.cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: onConfirm,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 15),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFFF4444).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: const Color(0xFFFF4444).withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                'onboarding_skip_confirm_confirm'.tr(),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFFF6B6B),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: onCancel,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 15),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Text(
                'onboarding_skip_confirm_cancel'.tr(),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: context.cs.onSurface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Glass-morphism circular back button
class OnboardingGlassBackButton extends StatelessWidget {
  final VoidCallback onTap;
  const OnboardingGlassBackButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: context.cs.surface.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x4D000000),
                  blurRadius: 15,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Icon(Icons.arrow_back, size: 20, color: context.cs.primary),
          ),
        ),
      ),
    );
  }
}

/// Accent-tinted circular icon bubble (100×100)
class OnboardingIconBubble extends StatelessWidget {
  final IconData icon;
  const OnboardingIconBubble({super.key, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 100,
      height: 100,
      decoration: BoxDecoration(
        color: context.cs.primary.withValues(alpha: 0.1),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 48, color: context.cs.primary),
    );
  }
}

/// Info block card (column layout) — for the features slide. [compact] is the
/// two-column grid cell: smaller icon and type so half a phone width fits.
class OnboardingIntroBlockCard extends StatelessWidget {
  final OnboardingInfoBlock block;
  final bool compact;
  const OnboardingIntroBlockCard({
    super.key,
    required this.block,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 14 : 16),
      decoration: BoxDecoration(
        color: const Color(0x14808080),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(block.icon, size: compact ? 30 : 48, color: context.cs.primary),
          SizedBox(height: compact ? 10 : 8),
          Text(
            block.title.tr(),
            style: TextStyle(
              fontSize: compact ? 16 : 20,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            block.desc.tr(),
            style: TextStyle(
              fontSize: compact ? 13 : 15,
              color: context.cs.onSurfaceVariant,
              height: compact ? 1.4 : 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Two-column grid of [OnboardingIntroBlockCard]s. Cards in a row share the
/// taller one's height; an odd last card spans the full row.
class OnboardingFeatureGrid extends StatelessWidget {
  final List<OnboardingInfoBlock> blocks;
  const OnboardingFeatureGrid({super.key, required this.blocks});

  static const double _gap = 12;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < blocks.length; i += 2) {
      final hasPair = i + 1 < blocks.length;
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : _gap),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: OnboardingIntroBlockCard(
                    block: blocks[i],
                    compact: true,
                  ),
                ),
                if (hasPair) ...[
                  const SizedBox(width: _gap),
                  Expanded(
                    child: OnboardingIntroBlockCard(
                      block: blocks[i + 1],
                      compact: true,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    return Column(children: rows);
  }
}

/// The first slide: the Glaze logo and a greeting, picking up where the
/// launch splash (`AppLaunchSplash`) leaves off.
///
/// Onboarding is pushed while the splash still covers the screen, and the
/// splash's logo sits dead centre at the same size. So the greeter starts with
/// its logo exactly there — the splash logo swells and fades over an identical
/// one — then lifts it up and lets the greeting rise in beneath. Meant to fill
/// the screen (a `Positioned.fill`), since the centre has to be the screen's.
class OnboardingGreeter extends StatefulWidget {
  final String title;
  final String? subtitle;
  const OnboardingGreeter({super.key, required this.title, this.subtitle});

  @override
  State<OnboardingGreeter> createState() => _OnboardingGreeterState();
}

class _OnboardingGreeterState extends State<OnboardingGreeter>
    with SingleTickerProviderStateMixin {
  /// `AppLaunchSplash` draws its logo at this size.
  static const double _logoSize = 176;
  static const double _settledScale = 0.6;

  /// How far above the screen centre the settled logo's centre sits.
  static const double _settledLift = 110;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.cs.primary;

    return LayoutBuilder(
      builder: (context, constraints) {
        final centerY = constraints.maxHeight / 2;
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            // Timeline (t = 0..1 over 1900ms):
            //   0.00–0.45  HOLD at the splash logo's spot while it fades out
            //   0.45–0.75  logo lifts and shrinks, glow blooms behind it
            //   0.62–0.90  title rises in
            //   0.72–1.00  subtitle rises in
            final t = _controller.value;
            final move = Curves.easeInOutCubic.transform(
              _interval(t, .45, .75),
            );
            final scale = 1 - (1 - _settledScale) * move;
            final logoCenter = centerY - _settledLift * move;
            final titleIn = Curves.easeOutCubic.transform(
              _interval(t, .62, .90),
            );
            final subtitleIn = Curves.easeOutCubic.transform(
              _interval(t, .72, 1),
            );
            final textTop =
                centerY - _settledLift + _logoSize * _settledScale / 2 + 28;

            return Stack(
              children: [
                // Soft accent glow, so the settled logo is not a lone glyph.
                Positioned(
                  left: 0,
                  right: 0,
                  top: logoCenter - 160,
                  height: 320,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: move,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            colors: [
                              accent.withValues(alpha: 0.18),
                              accent.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: logoCenter - _logoSize / 2,
                  child: Center(
                    child: Transform.scale(
                      scale: scale,
                      child: SvgPicture.string(
                        glazeFilledLogoSvg,
                        width: _logoSize,
                        height: _logoSize,
                        colorFilter: ColorFilter.mode(accent, BlendMode.srcIn),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 32,
                  right: 32,
                  top: textTop,
                  child: Column(
                    children: [
                      _riseIn(
                        titleIn,
                        Text(
                          widget.title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            height: 1.15,
                          ),
                        ),
                      ),
                      if (widget.subtitle != null) ...[
                        const SizedBox(height: 12),
                        _riseIn(
                          subtitleIn,
                          Text(
                            widget.subtitle!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 16,
                              color: context.cs.onSurfaceVariant,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _riseIn(double progress, Widget child) => Opacity(
    opacity: progress,
    child: Transform.translate(
      offset: Offset(0, 16 * (1 - progress)),
      child: child,
    ),
  );

  double _interval(double t, double start, double end) {
    if (t <= start) return 0;
    if (t >= end) return 1;
    return (t - start) / (end - start);
  }
}

/// Clickable action card, outlined in the accent — for data import / api /
/// persona slides
class OnboardingClickableBlock extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const OnboardingClickableBlock({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  State<OnboardingClickableBlock> createState() =>
      _OnboardingClickableBlockState();
}

class _OnboardingClickableBlockState extends State<OnboardingClickableBlock> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _pressed ? const Color(0x26808080) : const Color(0x14808080),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: context.cs.primary, width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(widget.icon, size: 48, color: context.cs.primary),
              const SizedBox(height: 8),
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.subtitle,
                style: TextStyle(
                  fontSize: 15,
                  color: context.cs.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-width accent primary button
class OnboardingPrimaryButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const OnboardingPrimaryButton({
    super.key,
    required this.label,
    required this.onTap,
  });

  @override
  State<OnboardingPrimaryButton> createState() =>
      _OnboardingPrimaryButtonState();
}

class _OnboardingPrimaryButtonState extends State<OnboardingPrimaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: context.cs.primary,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            widget.label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
