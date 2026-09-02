import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/top_edge_blur.dart';

/// Top inset every drawer tab body must leave clear for the header.
///
/// The header floats over the content (see the [Stack] below), so each tab
/// pads its own scroll view by this much instead of the scaffold reserving the
/// space. One constant so the two tab bodies cannot drift apart from each other
/// or from the header: 20px top padding + a ~34px tab strip, plus a gap wide
/// enough that the active tab's underline does not sit on a card's edge.
const double kDrawerContentTopInset = 66;

/// Shared shell for the chat drawer. Provides background, drag handle, top
/// soft-edge blur and the header slot; the tab bodies hosted inside supply
/// their own content and, while they are still loading, their own
/// [PanelLoadingOverlay].
///
/// Background is intentionally hardcoded to [Color(0xFF1E1E1E)] so the panel
/// is always dark regardless of the active theme. [GlazeColors.charBubble]
/// is the chat-bubble colour and must not drive panel backgrounds — themes
/// with a light charBubbleColor (e.g. Fox) would otherwise produce a
/// white/bright panel.
class DrawerPanelScaffold extends StatelessWidget {
  final Widget content;
  final Widget? header;
  final bool disableEffects;

  /// Called when the user swipes down on the drag handle. When null the
  /// handle is purely decorative (e.g. desktop sidebar hosting).
  final VoidCallback? onDismiss;

  const DrawerPanelScaffold({
    super.key,
    required this.content,
    this.header,
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
          if (header != null)
            Positioned(top: 0, left: 0, right: 0, child: header!),
          // Above the header in the stack, so it is hit-tested first. The
          // header's tab strip is opaque and spans the full width, and a
          // Stack stops at the first child that reports a hit — leaving the
          // handle below it would have made the swipe-down dead everywhere
          // the strip covers, which is exactly where the visible handle sits.
          // The handle is translucent, so the strip still receives the taps
          // and horizontal swipes it wants; only the vertical drag is the
          // handle's. The two do not overlap visually (bar 10-14px, strip
          // from 14px), so paint order is unaffected.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _DismissHandle(onDismiss: onDismiss),
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

/// Dimming spinner laid over a drawer tab that is still loading.
///
/// Lived in [DrawerPanelScaffold] while each panel built its own scaffold.
/// Now that the tabs share one scaffold, each tab shows it for itself —
/// switching to a loaded tab must not be dimmed by a sibling still working.
class PanelLoadingOverlay extends StatelessWidget {
  final bool loading;
  final Widget child;

  const PanelLoadingOverlay({
    super.key,
    required this.loading,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!loading) return child;
    return Stack(
      children: [
        Positioned.fill(child: child),
        const Positioned.fill(
          child: ColoredBox(
            color: Color(0x22000000),
            child: Center(child: GlazeSpinner()),
          ),
        ),
      ],
    );
  }
}
