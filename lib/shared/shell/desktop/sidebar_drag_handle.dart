import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/shared_prefs_provider.dart';
import 'sidebar_resizer.dart';

/// The column-resize grip that lives on a sidebar's inner edge.
///
/// Ported from the Vue `.sidebar-drag-handle`: invisible until hovered or
/// dragged, 8px wide, and straddling the divider rather than eating into the
/// sidebar's content. Double-clicking it toggles collapse, which the Vue app
/// could only do by dragging past the threshold.
class SidebarDragHandle extends ConsumerStatefulWidget {
  final LeftSidebarController? leftController;
  final RightSidebarController? rightController;

  static const double width = 8;

  const SidebarDragHandle.left({super.key, required this.leftController})
    : rightController = null;

  const SidebarDragHandle.right({super.key, required this.rightController})
    : leftController = null;

  @override
  ConsumerState<SidebarDragHandle> createState() => _SidebarDragHandleState();
}

class _SidebarDragHandleState extends ConsumerState<SidebarDragHandle> {
  double _startWidth = 0;
  bool _startCollapsed = false;
  double _accumulatedDx = 0;
  bool _dragging = false;
  bool _hovered = false;

  void _onPointerDown(PointerDownEvent event) {
    if (widget.leftController != null) {
      _startWidth = widget.leftController!.width;
    } else if (widget.rightController != null) {
      _startWidth = widget.rightController!.width;
      _startCollapsed = widget.rightController!.collapsed;
    }
    _accumulatedDx = 0;
    widget.leftController?.beginDrag();
    widget.rightController?.beginDrag();
    setState(() => _dragging = true);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_dragging) return;
    _accumulatedDx += event.delta.dx;
    if (widget.leftController != null) {
      widget.leftController!.width = _startWidth + _accumulatedDx;
    } else if (widget.rightController != null) {
      final newWidth = _startWidth - _accumulatedDx;
      widget.rightController!.handleDragUpdate(newWidth, _startCollapsed);
    }
  }

  Future<void> _onPointerUp(PointerUpEvent event) async {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.leftController?.endDrag();
    widget.rightController?.endDrag();
    final prefs = await ref.read(sharedPreferencesProvider.future);
    if (!mounted) return;
    widget.leftController?.finishResize(prefs);
    widget.rightController?.finishResize(prefs);
  }

  Future<void> _onDoubleTap() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    if (!mounted) return;
    widget.leftController?.toggleCollapse(prefs);
    widget.rightController?.toggleCollapse(prefs);
  }

  @override
  Widget build(BuildContext context) {
    final lit = _hovered || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: _onDoubleTap,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: (_) {
            widget.leftController?.endDrag();
            widget.rightController?.endDrag();
            setState(() => _dragging = false);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: SidebarDragHandle.width,
            height: double.infinity,
            color: lit
                ? Colors.white.withValues(alpha: 0.2)
                : Colors.transparent,
          ),
        ),
      ),
    );
  }
}
