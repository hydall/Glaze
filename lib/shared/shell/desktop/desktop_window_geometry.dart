import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Smallest size a desktop window can be resized down to.
const Size kDesktopWindowMinSize = Size(360, 260);

/// Height of a desktop window's title bar — the strip that must stay on screen
/// so the window can always be dragged back.
const double kDesktopWindowTitleBarHeight = 52;

/// How much of a window's width must stay on screen horizontally.
const double kDesktopWindowGrabMargin = 96;

/// Width of the invisible resize grips along a window's edges.
const double kDesktopWindowResizeGrip = 6;

/// Which edge (or corner) of a window a resize drag grabbed.
enum WindowResizeEdge {
  left,
  top,
  right,
  bottom,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight;

  bool get movesLeft => this == left || this == topLeft || this == bottomLeft;
  bool get movesTop => this == top || this == topLeft || this == topRight;
  bool get movesRight =>
      this == right || this == topRight || this == bottomRight;
  bool get movesBottom =>
      this == bottom || this == bottomLeft || this == bottomRight;

  MouseCursor get cursor => switch (this) {
    left || right => SystemMouseCursors.resizeLeftRight,
    top || bottom => SystemMouseCursors.resizeUpDown,
    topLeft || bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
    topRight || bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
  };
}

/// Where a window opens before the user has moved it: [preferred] centered in
/// [bounds] (capped at 92% of them), stepped down-right by [cascade] so windows
/// opened one after another do not stack exactly on top of each other.
Rect defaultWindowRect(Size bounds, Size preferred, {int cascade = 0}) {
  final width = math.min(preferred.width, bounds.width * 0.92);
  final height = math.min(preferred.height, bounds.height * 0.92);
  final step = 28.0 * (cascade % 6);
  final rect = Rect.fromLTWH(
    (bounds.width - width) / 2 + step,
    (bounds.height - height) / 2 + step,
    width,
    height,
  );
  return clampWindowRect(rect, bounds);
}

/// Fits [rect] into [bounds]: no bigger than the bounds, never smaller than
/// [minSize] (unless the bounds themselves are), and positioned so the title
/// bar stays reachable. A window may hang off the left, right or bottom edge,
/// but never past its grab margin, and never above the top edge.
Rect clampWindowRect(
  Rect rect,
  Size bounds, {
  Size minSize = kDesktopWindowMinSize,
}) {
  final width = rect.width
      .clamp(math.min(minSize.width, bounds.width), bounds.width)
      .toDouble();
  final height = rect.height
      .clamp(math.min(minSize.height, bounds.height), bounds.height)
      .toDouble();
  final minLeft = math.min(0.0, kDesktopWindowGrabMargin - width);
  final maxLeft = math.max(0.0, bounds.width - kDesktopWindowGrabMargin);
  final maxTop = math.max(0.0, bounds.height - kDesktopWindowTitleBarHeight);
  return Rect.fromLTWH(
    rect.left.clamp(minLeft, maxLeft),
    rect.top.clamp(0.0, maxTop),
    width,
    height,
  );
}

/// [start] with the grabbed [edge] dragged by [delta], kept at least [minSize]
/// and inside [bounds] (an edge that already hung outside may stay there).
Rect resizeWindowRect(
  Rect start,
  WindowResizeEdge edge,
  Offset delta,
  Size bounds, {
  Size minSize = kDesktopWindowMinSize,
}) {
  final minW = math.min(minSize.width, bounds.width);
  final minH = math.min(minSize.height, bounds.height);
  var left = start.left;
  var top = start.top;
  var right = start.right;
  var bottom = start.bottom;
  if (edge.movesLeft) {
    left = (left + delta.dx).clamp(math.min(0.0, start.left), right - minW);
  }
  if (edge.movesRight) {
    right = (right + delta.dx).clamp(
      left + minW,
      math.max(bounds.width, start.right),
    );
  }
  if (edge.movesTop) {
    top = (top + delta.dy).clamp(0.0, bottom - minH);
  }
  if (edge.movesBottom) {
    bottom = (bottom + delta.dy).clamp(
      top + minH,
      math.max(bounds.height, start.bottom),
    );
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Hands a window's move gesture to whatever positions it.
///
/// Provided by [DesktopWindowGeometry] (and by the desktop sheet window for its
/// content-sized variant); [DesktopWindowMoveArea] — the title bar — reads it,
/// so the title bar does not need to know how its window is laid out.
class DesktopWindowMoveScope extends InheritedWidget {
  final VoidCallback onMoveStart;

  /// Called with the pointer's total travel since the drag began.
  final ValueChanged<Offset> onMoveUpdate;
  final VoidCallback onMoveEnd;
  final VoidCallback? onToggleMaximize;

  const DesktopWindowMoveScope({
    super.key,
    required this.onMoveStart,
    required this.onMoveUpdate,
    required this.onMoveEnd,
    this.onToggleMaximize,
    required super.child,
  });

  static DesktopWindowMoveScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopWindowMoveScope>();

  @override
  bool updateShouldNotify(DesktopWindowMoveScope oldWidget) =>
      (oldWidget.onToggleMaximize == null) != (onToggleMaximize == null);
}

/// Makes [child] (a window's title bar) drag the window around, and
/// double-clicking it toggle maximize. A no-op outside a [DesktopWindowMoveScope]
/// or when the window is not movable.
class DesktopWindowMoveArea extends StatefulWidget {
  final Widget child;

  const DesktopWindowMoveArea({super.key, required this.child});

  @override
  State<DesktopWindowMoveArea> createState() => _DesktopWindowMoveAreaState();
}

class _DesktopWindowMoveAreaState extends State<DesktopWindowMoveArea> {
  Offset _origin = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final scope = DesktopWindowMoveScope.maybeOf(context);
    if (scope == null) return widget.child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onDoubleTap: scope.onToggleMaximize,
      onPanStart: (details) {
        _origin = details.globalPosition;
        scope.onMoveStart();
      },
      onPanUpdate: (details) =>
          scope.onMoveUpdate(details.globalPosition - _origin),
      onPanEnd: (_) => scope.onMoveEnd(),
      onPanCancel: scope.onMoveEnd,
      child: widget.child,
    );
  }
}

/// Places a window at [rect] inside a [Stack] that spans [bounds], and lets the
/// user move it (through a [DesktopWindowMoveArea] in its title bar) and resize
/// it (from any edge or corner).
///
/// The rect is tracked locally while a gesture runs and reported through
/// [onChanged] once it ends, so a drag does not rebuild whoever owns the rect
/// on every pointer move.
class DesktopWindowGeometry extends StatefulWidget {
  final Rect rect;
  final Size bounds;
  final bool movable;
  final bool resizable;
  final Size minSize;
  final ValueChanged<Rect> onChanged;
  final VoidCallback? onToggleMaximize;
  final Widget child;

  const DesktopWindowGeometry({
    super.key,
    required this.rect,
    required this.bounds,
    this.movable = true,
    this.resizable = true,
    this.minSize = kDesktopWindowMinSize,
    required this.onChanged,
    this.onToggleMaximize,
    required this.child,
  });

  @override
  State<DesktopWindowGeometry> createState() => _DesktopWindowGeometryState();
}

class _DesktopWindowGeometryState extends State<DesktopWindowGeometry> {
  Rect? _start;
  Rect? _live;

  void _begin() {
    _start = widget.rect;
  }

  void _move(Offset delta) {
    final start = _start;
    if (start == null) return;
    setState(() => _live = clampWindowRect(start.shift(delta), widget.bounds));
  }

  void _resize(WindowResizeEdge edge, Offset delta) {
    final start = _start;
    if (start == null) return;
    setState(
      () => _live = resizeWindowRect(
        start,
        edge,
        delta,
        widget.bounds,
        minSize: widget.minSize,
      ),
    );
  }

  void _end() {
    final live = _live;
    _start = null;
    if (live == null) return;
    setState(() => _live = null);
    widget.onChanged(live);
  }

  @override
  Widget build(BuildContext context) {
    final rect = _live ?? widget.rect;
    const grip = kDesktopWindowResizeGrip;

    Widget handle(WindowResizeEdge edge) => _ResizeGrip(
      edge: edge,
      onStart: _begin,
      onUpdate: (delta) => _resize(edge, delta),
      onEnd: _end,
    );

    final content = widget.movable
        ? DesktopWindowMoveScope(
            onMoveStart: _begin,
            onMoveUpdate: _move,
            onMoveEnd: _end,
            onToggleMaximize: widget.onToggleMaximize,
            child: widget.child,
          )
        // A pinned (maximized) window keeps the double-click that restores
        // it, but its title bar no longer drags it.
        : DesktopWindowMoveScope(
            onMoveStart: () {},
            onMoveUpdate: (_) {},
            onMoveEnd: () {},
            onToggleMaximize: widget.onToggleMaximize,
            child: widget.child,
          );

    // The grips straddle the window's border. Hit testing stops at a render
    // box's own bounds, so the positioned box is inflated by the grip width
    // and the window is inset back by the same amount.
    return Positioned.fromRect(
      rect: widget.resizable ? rect.inflate(grip / 2) : rect,
      child: widget.resizable
          ? Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.all(grip / 2),
                    child: content,
                  ),
                ),
                Positioned(
                  left: 0,
                  top: grip * 2,
                  bottom: grip * 2,
                  width: grip,
                  child: handle(WindowResizeEdge.left),
                ),
                Positioned(
                  right: 0,
                  top: grip * 2,
                  bottom: grip * 2,
                  width: grip,
                  child: handle(WindowResizeEdge.right),
                ),
                Positioned(
                  top: 0,
                  left: grip * 2,
                  right: grip * 2,
                  height: grip,
                  child: handle(WindowResizeEdge.top),
                ),
                Positioned(
                  bottom: 0,
                  left: grip * 2,
                  right: grip * 2,
                  height: grip,
                  child: handle(WindowResizeEdge.bottom),
                ),
                for (final corner in const [
                  (WindowResizeEdge.topLeft, Alignment.topLeft),
                  (WindowResizeEdge.topRight, Alignment.topRight),
                  (WindowResizeEdge.bottomLeft, Alignment.bottomLeft),
                  (WindowResizeEdge.bottomRight, Alignment.bottomRight),
                ])
                  Positioned.fill(
                    child: Align(
                      alignment: corner.$2,
                      child: SizedBox.square(
                        dimension: grip * 2,
                        child: handle(corner.$1),
                      ),
                    ),
                  ),
              ],
            )
          : content,
    );
  }
}

class _ResizeGrip extends StatefulWidget {
  final WindowResizeEdge edge;
  final VoidCallback onStart;
  final ValueChanged<Offset> onUpdate;
  final VoidCallback onEnd;

  const _ResizeGrip({
    required this.edge,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  @override
  State<_ResizeGrip> createState() => _ResizeGripState();
}

class _ResizeGripState extends State<_ResizeGrip> {
  Offset _origin = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.edge.cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) {
          _origin = details.globalPosition;
          widget.onStart();
        },
        onPanUpdate: (details) =>
            widget.onUpdate(details.globalPosition - _origin),
        onPanEnd: (_) => widget.onEnd(),
        onPanCancel: widget.onEnd,
      ),
    );
  }
}

/// Whether the platform's "open in a new window" modifier is held — Ctrl, or
/// Cmd on macOS — the way a browser opens a link in a new tab.
bool get isNewWindowModifierPressed {
  final keyboard = HardwareKeyboard.instance;
  return keyboard.isControlPressed || keyboard.isMetaPressed;
}
