import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/shared_prefs_provider.dart';
import 'sidebar_resizer.dart';

class SidebarDragHandle extends ConsumerStatefulWidget {
  final LeftSidebarController? leftController;
  final RightSidebarController? rightController;

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

  void _onPointerDown(PointerDownEvent event) {
    if (widget.leftController != null) {
      _startWidth = widget.leftController!.width;
    } else if (widget.rightController != null) {
      _startWidth = widget.rightController!.width;
      _startCollapsed = widget.rightController!.collapsed;
    }
    _accumulatedDx = 0;
    _dragging = true;
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
    _dragging = false;
    final prefs = await ref.read(sharedPreferencesProvider.future);
    if (widget.leftController != null) {
      widget.leftController!.finishResize(prefs);
    } else if (widget.rightController != null) {
      widget.rightController!.finishResize(prefs);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        child: Container(
          width: 6,
          height: double.infinity,
          color: Colors.white.withValues(alpha: 0.03),
        ),
      ),
    );
  }
}
