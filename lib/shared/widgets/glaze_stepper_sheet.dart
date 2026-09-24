import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'glaze_action_button.dart';

/// One page of a [GlazeStepperSheet].
///
/// A step carries only what is specific to it — [leading], [title], [body] and
/// [content]. The shared chrome (the step dots, the accent rules, the spacing)
/// belongs to the sheet, so every stepper reads the same.
class GlazeStepperStep {
  /// Drawn above the title, with a fixed gap. Used for an icon bubble or a
  /// branded mark that heads the very first step.
  final Widget? leading;

  final String? title;
  final String? body;

  /// Arbitrary step body under [body]: toggles, option rows, an action button.
  final Widget? content;

  /// Styles the step as a conditional addition — a step that only appears
  /// because of an earlier choice. Its title and dot take a lighter accent so
  /// the extra pages read as new, and dots count [accent] steps separately.
  final bool accent;

  const GlazeStepperStep({
    this.leading,
    this.title,
    this.body,
    this.content,
    this.accent = false,
  });
}

/// A multi-step explainer for a bottom sheet: a small dot progress ruler, a
/// step header and content, and a Back / Skip / Next footer.
///
/// The sheet owns the navigation and the chrome; the caller owns the steps.
/// Pass a list that is rebuilt from live state and the sheet follows it — a
/// step that no longer applies is dropped, and the index is clamped if it fell
/// past the new end.
class GlazeStepperSheet extends StatefulWidget {
  /// The steps, in order, rebuilt on every parent build.
  final List<GlazeStepperStep> steps;

  /// Called from the last step's primary action, and from Skip.
  final VoidCallback onFinish;

  final String backLabel;
  final String skipLabel;
  final String nextLabel;
  final String doneLabel;

  /// Whether the footer offers Skip alongside Next on the non-final steps.
  final bool showSkip;

  final EdgeInsets padding;

  const GlazeStepperSheet({
    super.key,
    required this.steps,
    required this.onFinish,
    required this.backLabel,
    required this.skipLabel,
    required this.nextLabel,
    required this.doneLabel,
    this.showSkip = true,
    this.padding = const EdgeInsets.fromLTRB(20, 14, 20, 24),
  });

  @override
  State<GlazeStepperSheet> createState() => _GlazeStepperSheetState();
}

class _GlazeStepperSheetState extends State<GlazeStepperSheet> {
  int _index = 0;
  int _direction = 1;

  @override
  void didUpdateWidget(covariant GlazeStepperSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_index >= widget.steps.length) {
      _index = widget.steps.length - 1;
    }
  }

  void _go(int target) {
    if (target < 0 || target >= widget.steps.length) return;
    setState(() {
      _direction = target >= _index ? 1 : -1;
      _index = target;
    });
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps;
    if (steps.isEmpty) return const SizedBox.shrink();

    final index = _index.clamp(0, steps.length - 1);
    final step = steps[index];
    final last = index == steps.length - 1;

    return Padding(
      padding: widget.padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            transitionBuilder: (child, animation) {
              final dir = child.key == ValueKey(index) ? _direction : -_direction;
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset(0.08 * dir, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: KeyedSubtree(
              key: ValueKey(index),
              child: _StepView(
                step: step,
                progress: _StepDots(steps: steps, current: index),
              ),
            ),
          ),
          const SizedBox(height: 20),
          _NavRow(
            showBack: index > 0,
            showSkip: widget.showSkip && !last,
            last: last,
            backLabel: widget.backLabel,
            skipLabel: widget.skipLabel,
            nextLabel: widget.nextLabel,
            doneLabel: widget.doneLabel,
            onBack: () => _go(index - 1),
            onNext: last ? widget.onFinish : () => _go(index + 1),
            onSkip: widget.onFinish,
          ),
        ],
      ),
    );
  }
}

/// The shared body of a step: lead, title, the dot ruler directly under the
/// title, body copy, then the step's own content.
class _StepView extends StatelessWidget {
  final GlazeStepperStep step;
  final Widget progress;

  const _StepView({required this.step, required this.progress});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (step.leading != null) ...[step.leading!, const SizedBox(height: 16)],
        if (step.title != null) ...[
          Text(step.title!, style: _titleStyle(context, accent: step.accent)),
          const SizedBox(height: 8),
        ],
        progress,
        if (step.body != null) ...[
          const SizedBox(height: 12),
          Text(step.body!, style: _bodyStyle(context)),
        ],
        if (step.content != null) ...[
          const SizedBox(height: 16),
          step.content!,
        ],
      ],
    );
  }
}

class _NavRow extends StatelessWidget {
  final bool showBack;
  final bool showSkip;
  final bool last;
  final String backLabel;
  final String skipLabel;
  final String nextLabel;
  final String doneLabel;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  const _NavRow({
    required this.showBack,
    required this.showSkip,
    required this.last,
    required this.backLabel,
    required this.skipLabel,
    required this.nextLabel,
    required this.doneLabel,
    required this.onBack,
    required this.onNext,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (showBack)
          GlazeActionButton(
            icon: Icons.arrow_back_rounded,
            label: backLabel,
            onTap: onBack,
          ),
        const Spacer(),
        if (showSkip) ...[
          GlazeActionButton(
            icon: Icons.close_rounded,
            label: skipLabel,
            onTap: onSkip,
          ),
          const SizedBox(width: 8),
        ],
        GlazeActionButton(
          icon: last ? Icons.check_rounded : Icons.arrow_forward_rounded,
          label: last ? doneLabel : nextLabel,
          tone: GlazeActionTone.primary,
          onTap: onNext,
        ),
      ],
    );
  }
}

/// Step titles use the plain text colour, except a step marked
/// [GlazeStepperStep.accent], which gets a lighter tint of the accent so a
/// conditional page reads as an addition.
TextStyle _titleStyle(BuildContext context, {bool accent = false}) => TextStyle(
  fontSize: 22,
  fontWeight: FontWeight.w700,
  color: accent ? _lighterAccent(context) : context.cs.onSurface,
  height: 1.2,
);

Color _lighterAccent(BuildContext context) =>
    Color.lerp(context.cs.primary, Colors.white, 0.45)!;

TextStyle _bodyStyle(BuildContext context) => TextStyle(
  fontSize: 15,
  color: context.cs.onSurfaceVariant,
  height: 1.5,
);

/// Compact step indicator: the active step is a short pill, the rest dots.
/// Deliberately small, and drawn under the current step's own title rather
/// than as a bar competing with it.
///
/// Unconditional steps (the ones with [GlazeStepperStep.accent] unset) use the
/// full accent; the conditional steps that follow use a lighter tint and
/// animate in — width and colour transition per dot, and the row resizes as
/// steps are added or dropped.
class _StepDots extends StatelessWidget {
  final List<GlazeStepperStep> steps;
  final int current;

  const _StepDots({required this.steps, required this.current});

  @override
  Widget build(BuildContext context) {
    final accent = context.cs.primary;
    final lighter = _lighterAccent(context);
    return AnimatedSize(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < steps.length; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              margin: EdgeInsets.only(right: i == steps.length - 1 ? 0 : 6),
              width: i == current ? 18 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == current
                    ? (steps[i].accent ? lighter : accent)
                    : (steps[i].accent ? lighter : accent).withValues(
                        alpha: steps[i].accent ? 0.35 : 0.22,
                      ),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      ),
    );
  }
}
