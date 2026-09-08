import 'package:flutter/material.dart';

/// Computes the tab index a horizontal swipe should land on, or `null` when the
/// gesture is too weak or would run off the end of the tab range.
///
/// A swipe to the **left** (finger travels right→left, negative delta) advances
/// to the next tab; a swipe to the **right** goes back to the previous one —
/// matching the direction the underlying content visually moves.
int? resolveSwipeTarget({
  required int index,
  required int length,
  required double distance,
  required double velocity,
  double minDistance = 48.0,
  double minVelocity = 260.0,
}) {
  if (length <= 1) return null;

  final passedDistance = distance.abs() >= minDistance;
  final passedVelocity = velocity.abs() >= minVelocity;
  if (!passedDistance && !passedVelocity) return null;

  // A fast flick's direction is most reliable; fall back to the accumulated
  // travel for slow, deliberate drags that never build up much velocity.
  final int direction;
  if (passedVelocity) {
    direction = velocity < 0 ? 1 : -1;
  } else {
    direction = distance < 0 ? 1 : -1;
  }

  final next = index + direction;
  if (next < 0 || next >= length) return null;
  return next;
}

/// Wraps [child] so a horizontal swipe anywhere over it switches the active tab.
///
/// The detector sits *above* the content in the tree, so any nested widget that
/// also wants horizontal drags — a horizontal list, a `Slider`, a `Dismissible`
/// — wins the gesture arena and this switcher stays out of its way. That gives
/// the desired "ignore the swipe if the user grabbed something else swipeable"
/// behaviour for free, while vertical scrolling (a different drag axis) is never
/// affected.
class SwipeTabSwitcher extends StatefulWidget {
  final int index;
  final int length;
  final ValueChanged<int> onChanged;
  final Widget child;

  /// When false the switcher is a transparent pass-through (e.g. while the tab
  /// strip itself is hidden).
  final bool enabled;

  final HitTestBehavior behavior;

  const SwipeTabSwitcher({
    super.key,
    required this.index,
    required this.length,
    required this.onChanged,
    required this.child,
    this.enabled = true,
    this.behavior = HitTestBehavior.translucent,
  });

  @override
  State<SwipeTabSwitcher> createState() => _SwipeTabSwitcherState();
}

class _SwipeTabSwitcherState extends State<SwipeTabSwitcher> {
  double _distance = 0;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.length <= 1) return widget.child;

    return GestureDetector(
      behavior: widget.behavior,
      onHorizontalDragStart: (_) => _distance = 0,
      onHorizontalDragUpdate: (d) => _distance += d.delta.dx,
      onHorizontalDragEnd: (details) {
        final target = resolveSwipeTarget(
          index: widget.index,
          length: widget.length,
          distance: _distance,
          velocity: details.primaryVelocity ?? 0,
        );
        if (target != null) widget.onChanged(target);
      },
      child: widget.child,
    );
  }
}
