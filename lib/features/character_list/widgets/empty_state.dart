import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';

/// Shown in place of the grid while the library has no characters: a fan of
/// drifting cards, a short explanation and the ways to get a first character.
class EmptyCharacterState extends StatelessWidget {
  final VoidCallback onAdd;

  /// Switches to the Discover tab. Null hides the button — the catalog can be
  /// turned off in settings.
  final VoidCallback? onDiscover;

  const EmptyCharacterState({super.key, required this.onAdd, this.onDiscover});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _CardsIllustration(),
            const SizedBox(height: 20),
            Text(
              'characters_empty_title'.tr(),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'characters_empty_hint'.tr(),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: context.cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            // Wrap, not Row: both labels are translated and may not fit side
            // by side in a narrow column.
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                GlazeActionButton(
                  icon: Icons.add_rounded,
                  label: 'btn_add'.tr(),
                  tone: GlazeActionTone.primary,
                  onTap: onAdd,
                ),
                if (onDiscover != null)
                  GlazeActionButton(
                    icon: Icons.public_rounded,
                    label: 'tab_catalog'.tr(),
                    onTap: onDiscover,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Three character cards fanned out and gently bobbing: two muted ones behind
/// and an accent one in front.
class _CardsIllustration extends StatefulWidget {
  const _CardsIllustration();

  @override
  State<_CardsIllustration> createState() => _CardsIllustrationState();
}

class _CardsIllustrationState extends State<_CardsIllustration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _float = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4200),
  )..repeat();

  @override
  void dispose() {
    _float.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 500),
      curve: const Cubic(0.2, 0.8, 0.2, 1),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(scale: 0.9 + 0.1 * t, child: child),
      ),
      child: SizedBox(
        width: 200,
        height: 160,
        child: AnimatedBuilder(
          animation: _float,
          builder: (context, _) {
            final a = _float.value * 2 * pi;
            // Side cards bob opposite to the front one.
            final sideDy = sin(a) * 3;
            final frontDy = sin(a + pi) * 4;
            return Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Transform.translate(
                  offset: Offset(-46, 8 + sideDy),
                  child: Transform.rotate(
                    angle: -0.22,
                    child: _MutedCard(color: cs.onSurfaceVariant),
                  ),
                ),
                Transform.translate(
                  offset: Offset(46, 8 - sideDy),
                  child: Transform.rotate(
                    angle: 0.22,
                    child: _MutedCard(color: cs.onSurfaceVariant),
                  ),
                ),
                Transform.translate(
                  offset: Offset(0, frontDy),
                  child: _AccentCard(color: cs.primary, onColor: cs.onPrimary),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

const _cardWidth = 84.0;
const _cardHeight = 120.0;

class _MutedCard extends StatelessWidget {
  final Color color;

  const _MutedCard({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _cardWidth * 0.9,
      height: _cardHeight * 0.9,
      decoration: BoxDecoration(
        color: Color.lerp(context.cs.surface, Colors.white, 0.06),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.person_rounded,
            size: 34,
            color: color.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 8),
          _Line(width: 40, color: color.withValues(alpha: 0.25)),
        ],
      ),
    );
  }
}

class _AccentCard extends StatelessWidget {
  final Color color;
  final Color onColor;

  const _AccentCard({required this.color, required this.onColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _cardWidth,
      height: _cardHeight,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, Color.lerp(color, Colors.black, 0.25)!],
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: onColor.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.person_rounded, size: 28, color: onColor),
          ),
          const SizedBox(height: 12),
          _Line(width: 48, color: onColor.withValues(alpha: 0.75)),
          const SizedBox(height: 6),
          _Line(width: 30, color: onColor.withValues(alpha: 0.4)),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final double width;
  final Color color;

  const _Line({required this.width, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 6,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}
