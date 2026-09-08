import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/top_edge_blur.dart';

/// Shared shell for bottom slide-up panels (Magic Drawer, Quick Replies).
/// Provides background, drag handle, top soft-edge blur, header slot,
/// and an optional loading overlay.
///
/// Background is intentionally hardcoded to [Color(0xFF1E1E1E)] so the panel
/// is always dark regardless of the active theme. [GlazeColors.charBubble]
/// is the chat-bubble colour and must not drive panel backgrounds — themes
/// with a light charBubbleColor (e.g. Fox) would otherwise produce a
/// white/bright panel.
class DrawerPanelScaffold extends StatelessWidget {
  final Widget content;
  final Widget? header;
  final bool loading;
  final bool disableEffects;

  /// Called when the user swipes down on the drag handle. When null the
  /// handle is purely decorative (e.g. desktop sidebar hosting).
  final VoidCallback? onDismiss;

  const DrawerPanelScaffold({
    super.key,
    required this.content,
    this.header,
    this.loading = false,
    this.disableEffects = false,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border(top: BorderSide(color: context.cs.outlineVariant)),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: TopEdgeBlur(
              enabled: !disableEffects,
              height: 68,
              sigma: 24,
              tintColor: const Color(0xFF1E1E1E).withValues(alpha: 0.88),
              child: content,
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _DismissHandle(onDismiss: onDismiss),
          ),
          if (header != null)
            Positioned(top: 0, left: 0, right: 0, child: header!),
          if (loading)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x22000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

/// Drag handle at the top of the panel. When [onDismiss] is provided the
/// zone around the handle accepts a downward swipe to close the panel;
/// otherwise it stays decorative and hit-transparent.
class _DismissHandle extends StatefulWidget {
  final VoidCallback? onDismiss;

  const _DismissHandle({this.onDismiss});

  @override
  State<_DismissHandle> createState() => _DismissHandleState();
}

class _DismissHandleState extends State<_DismissHandle> {
  static const double _kDistanceThreshold = 48;
  static const double _kVelocityThreshold = 300;

  double _dragDistance = 0;

  @override
  Widget build(BuildContext context) {
    final bar = Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Center(
        child: Container(
          width: 32,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.grey[600],
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );

    if (widget.onDismiss == null) {
      return IgnorePointer(child: bar);
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) => _dragDistance = 0,
      onVerticalDragUpdate: (details) => _dragDistance += details.delta.dy,
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (_dragDistance > _kDistanceThreshold ||
            velocity > _kVelocityThreshold) {
          widget.onDismiss?.call();
        }
      },
      child: SizedBox(height: 34, width: double.infinity, child: bar),
    );
  }
}
