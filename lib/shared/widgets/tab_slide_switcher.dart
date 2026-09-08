import 'package:flutter/material.dart';

/// Cross-fades between tab bodies with a horizontal slide whose direction
/// follows the change in [index]: advancing to a higher tab slides the incoming
/// body in from the right while the outgoing one exits to the left, and going
/// back reverses it.
///
/// The animation is driven purely by [index], so it looks identical whether the
/// tab changed from a segmented-control tap or from a swipe — both just update
/// the index and this widget picks up the delta.
class TabSlideSwitcher extends StatefulWidget {
  /// The currently active tab index. A change triggers the slide.
  final int index;

  /// The body of the [index] tab. It is re-keyed on [index] internally, so the
  /// caller does not need to add its own [Key].
  final Widget child;

  final Duration duration;

  const TabSlideSwitcher({
    super.key,
    required this.index,
    required this.child,
    this.duration = const Duration(milliseconds: 260),
  });

  @override
  State<TabSlideSwitcher> createState() => _TabSlideSwitcherState();
}

class _TabSlideSwitcherState extends State<TabSlideSwitcher> {
  // +1 when the last change moved to a higher tab (content travels left→right
  // as the new page enters from the right), -1 when it moved to a lower tab.
  double _direction = 1;

  @override
  void didUpdateWidget(TabSlideSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index) {
      _direction = widget.index > oldWidget.index ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSwitcher(
        duration: widget.duration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final key = child.key;
          final isIncoming = key is ValueKey<int> && key.value == widget.index;
          // The incoming child enters from `_direction`; the outgoing child —
          // whose animation runs in reverse — leaves toward `-_direction`.
          final begin = Offset(isIncoming ? _direction : -_direction, 0);
          return SlideTransition(
            position: Tween<Offset>(
              begin: begin,
              end: Offset.zero,
            ).animate(animation),
            child: child,
          );
        },
        layoutBuilder: (currentChild, previousChildren) => Stack(
          alignment: Alignment.topCenter,
          children: [...previousChildren, ?currentChild],
        ),
        child: KeyedSubtree(
          key: ValueKey<int>(widget.index),
          child: widget.child,
        ),
      ),
    );
  }
}
