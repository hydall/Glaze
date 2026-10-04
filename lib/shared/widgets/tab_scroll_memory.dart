import 'package:flutter/material.dart';

/// Per-tab scroll positions for a tab switcher whose bodies are torn down when
/// the active tab changes.
///
/// Tab bodies that live in an [AnimatedSwitcher] — as `TabSlideSwitcher`'s do
/// — are disposed once they finish sliding away, so a single shared
/// [ScrollController] hands every returning tab a fresh position at the very
/// top. This owns one controller per tab instead: [controllerFor] is provided
/// *inside* each tab body via [PrimaryScrollController] — not above the
/// switcher — so the outgoing body keeps scrolling with the controller it was
/// built with while it animates out, and [switchTab] stashes the offset of the
/// tab being left so the one being entered re-attaches where the user last saw
/// it.
///
/// The offset is applied when the scroll position is created, i.e. before the
/// incoming body's first frame, so the tab appears already scrolled instead of
/// jumping. The restore is one-shot and only arms a tab that has no live
/// scroll view, so navigation *inside* a tab (opening a folder) still starts at
/// the top and an interrupted switch animation keeps the position it has.
class TabScrollMemory {
  TabScrollMemory({required int tabCount})
    : assert(tabCount > 0),
      _controllers = List.generate(
        tabCount,
        (_) => _RestoringScrollController(),
        growable: false,
      );

  final List<_RestoringScrollController> _controllers;

  /// The controller [tab]'s body scrolls with.
  ScrollController controllerFor(int tab) => _controllers[tab];

  /// Carries the scroll positions across a tab change: [from] remembers where
  /// it was left, [to] is armed to open at the offset it was left at.
  void switchTab({required int from, required int to}) {
    if (from == to) return;
    _controllers[from].stash();
    _controllers[to].arm();
  }

  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
  }
}

/// A [ScrollController] whose next scroll position can be started at a
/// remembered offset instead of at the top.
class _RestoringScrollController extends ScrollController {
  double _stashed = 0;
  double? _pending;

  /// Records where the attached scroll view currently sits. Skipped when there
  /// is no single position to read — none attached, or two while a switch
  /// animation still holds the previous body.
  void stash() {
    if (positions.length == 1 && position.hasPixels) _stashed = position.pixels;
  }

  /// Makes the next position created by this controller open at the stashed
  /// offset. A tab that still has a live scroll view keeps its current offset,
  /// so nothing is armed for it.
  void arm() {
    if (positions.isEmpty) _pending = _stashed;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    final restoreTo = _pending;
    _pending = null;
    return ScrollPositionWithSingleContext(
      physics: physics,
      context: context,
      initialPixels: restoreTo ?? initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}
