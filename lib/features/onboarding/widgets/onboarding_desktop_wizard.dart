import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import 'onboarding_widgets.dart';

/// Desktop onboarding — a 1:1 port of the Vue wizard (`OnboardingView.vue`,
/// `.desktop-layout`).
///
/// The phone flow stacks everything into one scrolling column under a stories
/// bar. On a wide window that leaves a narrow ribbon of content in the middle
/// of an empty screen, so the desktop build instead centres a fixed card and
/// splits it in two: a visual pane carrying the slide's icon, and a content
/// pane with the title, description, whatever the slide offers, and the
/// primary button pinned to its bottom.
class OnboardingDesktopWizard extends StatelessWidget {
  /// Zero-based index of the visible slide, and how many there are — together
  /// they drive the stories bar in the top bar.
  final int slideIndex;
  final int slideCount;

  final IconData icon;
  final String title;
  final String? description;

  /// Slide-specific content under the description: the info-block list, the
  /// single action card, or the chat-layout picker. Null on a slide that is
  /// only a title and a description.
  final Widget? body;

  final String buttonLabel;
  final VoidCallback onNext;

  /// Null on the first slide, where there is nothing to go back to. The button
  /// keeps its slot either way so the stories bar does not shift.
  final VoidCallback? onBack;

  /// Null on the last slide, which has nothing left to skip.
  final VoidCallback? onSkip;

  const OnboardingDesktopWizard({
    super.key,
    required this.slideIndex,
    required this.slideCount,
    required this.icon,
    required this.title,
    required this.description,
    required this.body,
    required this.buttonLabel,
    required this.onNext,
    required this.onBack,
    required this.onSkip,
  });

  /// `.onboarding-card { width: min(1180px, 100%); height: min(820px, …) }`.
  static const double _cardMaxWidth = 1180;
  static const double _cardMaxHeight = 820;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: SizedBox(
          width: size.width.clamp(0.0, _cardMaxWidth),
          height: (size.height - 40).clamp(0.0, _cardMaxHeight),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.cs.surface.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 40,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Column(
                children: [
                  _buildTopBar(),
                  Expanded(child: _buildSlide(context)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// `.onboarding-topbar` — back button, then the stories bar filling the
  /// rest, with the skip affordance at the far end.
  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: SizedBox(
        height: 42,
        child: Row(
          children: [
            // The slot is held even on the first slide (`.nav-back-btn` starts
            // at width 0 but keeps its place), so the bar does not jump.
            SizedBox(
              width: 42,
              child: onBack == null
                  ? null
                  : OnboardingGlassBackButton(onTap: onBack!),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: OnboardingStoriesBar(
                total: slideCount,
                current: slideIndex,
              ),
            ),
            if (onSkip != null) ...[
              const SizedBox(width: 16),
              OnboardingSkipButton(onTap: onSkip!),
            ],
          ],
        ),
      ),
    );
  }

  /// `.wizard-layout` — the visual pane at `0.95fr`, the content at `1.15fr`.
  Widget _buildSlide(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 95, child: _buildVisual(context)),
          const SizedBox(width: 28),
          Expanded(flex: 115, child: _buildContent(context)),
        ],
      ),
    );
  }

  /// `.wizard-visual` — a tinted panel holding the slide's icon.
  Widget _buildVisual(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Center(child: OnboardingIconBubble(icon: icon)),
    );
  }

  Widget _buildContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 20, right: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.tr(),
                  style: const TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    height: 1.12,
                  ),
                ),
                if (description != null) ...[
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Text(
                      description!.tr(),
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.6,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
                if (body != null) ...[const SizedBox(height: 22), body!],
              ],
            ),
          ),
        ),
        // `.onboarding-footer` — the primary button spans the content pane.
        Padding(
          padding: const EdgeInsets.only(top: 16, right: 8),
          child: OnboardingPrimaryButton(label: buttonLabel, onTap: onNext),
        ),
      ],
    );
  }
}
