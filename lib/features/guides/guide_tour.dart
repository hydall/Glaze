import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glass_surface.dart';
import 'guide_anchor.dart';

/// One stop of a guide tour: the control to point at and what to say about it.
class GuideTourStep {
  /// The [GuideAnchor] id to spotlight. Null for a step that explains
  /// something with no single control behind it (gestures inside the chat
  /// WebView, a setting picked in place): the screen is dimmed evenly.
  final String? target;
  final String title;
  final String body;

  /// Shown under [body] in the hint card — a switch or a choice the reader
  /// can make right there.
  final Widget? content;

  /// Dropped from the tour when [target] is not on screen as it opens: a
  /// tile the reader hid, a button that only exists with characters in the
  /// library. A step that is not optional stays, unlit, instead.
  final bool optional;

  const GuideTourStep({
    this.target,
    required this.title,
    required this.body,
    this.content,
    this.optional = false,
  });

  /// A step whose copy lives under `<key>_title` and `<key>_body`.
  GuideTourStep.tr(
    String key, {
    this.target,
    this.content,
    this.optional = false,
  }) : title = '${key}_title'.tr(),
       body = '${key}_body'.tr();
}

/// How long [showGuideTour] waits for the screen to mount what the tour
/// points at — a list still loading, a branch still fading in.
const _kAnchorWait = Duration(milliseconds: 1500);

/// Space between a spotlit control and the edge of its spotlight.
const double _kHolePad = 6;

/// Runs [steps] as a spotlight tour over the whole app: the screen dims, the
/// current step's control is cut out and ringed, a hint card sits at the top
/// and the step buttons at the bottom — each moved out of the way when the
/// control sits where it would go.
Future<void> showGuideTour(
  BuildContext context,
  List<GuideTourStep> steps,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);

  bool ready() => steps.every(
    (s) => s.optional || s.target == null || GuideAnchors.isVisible(s.target!),
  );
  final deadline = DateTime.now().add(_kAnchorWait);
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (!navigator.mounted) return;

  final visible = [
    for (final step in steps)
      if (!step.optional || GuideAnchors.isVisible(step.target!)) step,
  ];
  if (visible.isEmpty) return;

  await navigator.push(
    PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) => GuideTourView(steps: visible),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// The tour overlay. Public for tests; open it through [showGuideTour].
class GuideTourView extends StatefulWidget {
  final List<GuideTourStep> steps;
  const GuideTourView({super.key, required this.steps});

  @override
  State<GuideTourView> createState() => _GuideTourViewState();
}

enum _Slot { card, controls }

class _GuideTourViewState extends State<GuideTourView>
    with TickerProviderStateMixin {
  int _index = 0;

  /// Where the current step's control is now, in this overlay's coordinates.
  /// Re-measured every frame, so the spotlight follows a control that scrolls,
  /// animates in or moves with a hiding header.
  Rect? _target;

  /// The spotlight as it was when the step changed; [_move] carries it from
  /// here to [_target].
  Rect? _from;

  late final AnimationController _move = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
    value: 1,
  );
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();
  late final Ticker _tracker;

  GuideTourStep get _step => widget.steps[_index];
  bool get _last => _index == widget.steps.length - 1;

  @override
  void initState() {
    super.initState();
    _tracker = createTicker((_) => _track())..start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bringIntoView());
  }

  @override
  void dispose() {
    _tracker.dispose();
    _move.dispose();
    _pulse.dispose();
    super.dispose();
  }

  Rect? _measure() {
    final id = _step.target;
    if (id == null) return null;
    final rect = GuideAnchors.rectOf(id);
    if (rect == null) return null;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return rect;
    return box.globalToLocal(rect.topLeft) & rect.size;
  }

  void _track() {
    if (!mounted) return;
    final rect = _measure();
    if (rect != _target) setState(() => _target = rect);
  }

  /// The spotlight to draw this frame: the live target once the move is done,
  /// in between a blend from where it was. A step without a control grows its
  /// spotlight from, or shrinks it into, the centre of the neighbouring one.
  Rect? _displayRect() {
    if (_move.isCompleted) return _target;
    final from = _from ?? _collapsed(_target);
    final to = _target ?? _collapsed(_from);
    if (from == null || to == null) return null;
    return Rect.lerp(from, to, Curves.easeOutCubic.transform(_move.value));
  }

  static Rect? _collapsed(Rect? rect) => rect == null
      ? null
      : Rect.fromCenter(center: rect.center, width: 0, height: 0);

  void _go(int index) {
    if (index < 0 || index >= widget.steps.length || index == _index) return;
    final current = _displayRect();
    setState(() {
      _index = index;
      _from = current;
      _target = _measure();
    });
    _move.forward(from: 0);
    _bringIntoView();
  }

  /// Scrolls the step's control on screen when it sits in a list and is
  /// (partly) out of view. Left alone when already visible, so a tour over a
  /// short screen does not jiggle it at every step.
  void _bringIntoView() {
    final id = _step.target;
    if (id == null) return;
    final anchor = GuideAnchors.contextOf(id);
    if (anchor == null || Scrollable.maybeOf(anchor) == null) return;
    final rect = GuideAnchors.rectOf(id);
    final screen = MediaQuery.sizeOf(context);
    const margin = 120.0;
    if (rect != null &&
        rect.top >= margin &&
        rect.bottom <= screen.height - margin) {
      return;
    }
    Scrollable.ensureVisible(
      anchor,
      alignment: 0.4,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void _finish() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // The dim swallows every tap: the tour is driven by its own buttons,
          // not by stray touches on the app underneath.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: AnimatedBuilder(
                animation: _move,
                builder: (context, _) => CustomPaint(
                  painter: _SpotlightPainter(
                    hole: _displayRect(),
                    pulse: _pulse,
                    accent: context.cs.primary,
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: CustomMultiChildLayout(
              delegate: _TourLayout(target: _target, padding: padding),
              children: [
                LayoutId(id: _Slot.card, child: _buildCard(context)),
                LayoutId(id: _Slot.controls, child: _buildControls(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(BuildContext context) {
    final step = _step;
    return _Panel(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topLeft,
            children: [...previous, ?current],
          ),
          child: Column(
            key: ValueKey(_index),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'guide_step_counter'.tr(
                  namedArgs: {
                    'current': '${_index + 1}',
                    'total': '${widget.steps.length}',
                  },
                ),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.cs.primary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                step.title,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  color: context.cs.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                step.body,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
              if (step.content != null) ...[
                const SizedBox(height: 14),
                step.content!,
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    return _Panel(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StepDots(count: widget.steps.length, current: _index, onTap: _go),
            const SizedBox(height: 12),
            Row(
              children: [
                if (_index > 0)
                  _RoundStepButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: 'guide_back'.tr(),
                    onTap: () => _go(_index - 1),
                  ),
                const Spacer(),
                if (!_last) ...[
                  _SkipPill(label: 'guide_skip'.tr(), onTap: _finish),
                  const SizedBox(width: 10),
                ],
                _RoundStepButton(
                  icon: _last
                      ? Icons.check_rounded
                      : Icons.arrow_forward_rounded,
                  tooltip: _last ? 'guide_done'.tr() : 'guide_next'.tr(),
                  primary: true,
                  onTap: _last ? _finish : () => _go(_index + 1),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Places the hint card at the top and the step buttons at the bottom, and
/// moves either out of the spotlight's way: the card below a control in the
/// top band, the buttons above a control in the bottom band.
class _TourLayout extends MultiChildLayoutDelegate {
  final Rect? target;
  final EdgeInsets padding;

  _TourLayout({required this.target, required this.padding});

  @override
  void performLayout(Size size) {
    const gap = 12.0;
    final width = math.min(size.width - 24, 480.0);
    final left = (size.width - width) / 2;
    final hole = target?.inflate(_kHolePad + 4);

    final controls = layoutChild(
      _Slot.controls,
      BoxConstraints.tightFor(width: width),
    );
    final card = layoutChild(
      _Slot.card,
      BoxConstraints(
        minWidth: width,
        maxWidth: width,
        maxHeight: size.height * 0.46,
      ),
    );

    var controlsTop = size.height - padding.bottom - gap - controls.height;
    if (hole != null && hole.bottom > controlsTop) {
      controlsTop = hole.top - gap - controls.height;
    }

    final top = padding.top + gap;
    var cardTop = top;
    if (hole != null && hole.top < cardTop + card.height) {
      final below = hole.bottom + gap;
      // Below the control when that still clears the buttons; otherwise back
      // at the top, where the control at least stays partly visible.
      cardTop = below + card.height <= controlsTop - gap ? below : top;
    }

    positionChild(_Slot.card, Offset(left, cardTop));
    positionChild(_Slot.controls, Offset(left, math.max(top, controlsTop)));
  }

  @override
  bool shouldRelayout(_TourLayout old) =>
      old.target != target || old.padding != padding;
}

/// The dim with the spotlight cut out of it, ringed in the accent, with a
/// second ring that keeps pulsing outwards to draw the eye.
class _SpotlightPainter extends CustomPainter {
  final Rect? hole;
  final Animation<double> pulse;
  final Color accent;

  _SpotlightPainter({
    required this.hole,
    required this.pulse,
    required this.accent,
  }) : super(repaint: pulse);

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.62);
    final screen = Path()..addRect(Offset.zero & size);
    final rect = hole;
    if (rect == null || rect.isEmpty) {
      canvas.drawPath(screen, dim);
      return;
    }

    final spot = rect.inflate(_kHolePad);
    final rrect = RRect.fromRectAndRadius(
      spot,
      Radius.circular(math.min(spot.shortestSide / 2, 18)),
    );
    canvas.drawPath(
      Path.combine(PathOperation.difference, screen, Path()..addRRect(rrect)),
      dim,
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = accent,
    );
    final t = pulse.value;
    canvas.drawRRect(
      rrect.inflate(2 + 8 * t),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = accent.withValues(alpha: 0.5 * (1 - t)),
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.hole != hole || old.accent != accent || old.pulse != pulse;
}

/// The solid rounded surface both the hint card and the step buttons sit on.
class _Panel extends StatelessWidget {
  final Widget child;
  const _Panel({required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.cs.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.cs.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(20), child: child),
    );
  }
}

/// One dot per step, the current one a pill. Tapping a dot jumps to it.
class _StepDots extends StatelessWidget {
  final int count;
  final int current;
  final ValueChanged<int> onTap;

  const _StepDots({
    required this.count,
    required this.current,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = context.cs.primary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onTap(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                width: i == current ? 20 : 7,
                height: 7,
                decoration: BoxDecoration(
                  color: i == current
                      ? accent
                      : accent.withValues(alpha: i < current ? 0.5 : 0.22),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A round, icon-only step button: back, next, or done on the last step.
class _RoundStepButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool primary;
  final VoidCallback onTap;

  const _RoundStepButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = primary ? context.cs.primary : context.cs.onSurface;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: GlassSurface(
          borderRadius: BorderRadius.circular(24),
          tint: primary
              ? context.cs.primary.withValues(alpha: 0.18)
              : context.cs.surface,
          border: Border.all(color: accent.withValues(alpha: 0.22)),
          onTap: onTap,
          child: SizedBox.square(
            dimension: 48,
            child: Icon(icon, size: 22, color: accent),
          ),
        ),
      ),
    );
  }
}

/// The text-labelled Skip, as a fully rounded pill.
class _SkipPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _SkipPill({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = context.cs.onSurface;
    return GlassSurface(
      borderRadius: BorderRadius.circular(24),
      tint: context.cs.surface,
      border: Border.all(color: color.withValues(alpha: 0.22)),
      onTap: onTap,
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
