import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../widgets/glass_surface.dart';

enum SidebarEdge { left, right }

/// Shared chrome for the two desktop sidebars.
///
/// The Vue sidebars were `rgba(var(--ui-bg-rgb), .4)` panes behind
/// `backdrop-filter: blur(var(--element-blur))` and animated their width with a
/// 220ms ease. Both were lost in the port: the columns were flat
/// `Colors.black @ 20%` boxes that ignored the theme and snapped between widths.
/// [GlassSurface] restores the glass (and with it the preset's opacity, blur
/// and noise), and [AnimatedContainer] restores the collapse animation.
class DesktopSidebarSurface extends StatelessWidget {
  final double width;
  final SidebarEdge edge;
  final Widget child;

  /// False while the grip is dragged, so the edge tracks the cursor exactly.
  final bool animate;

  static const Duration animationDuration = Duration(milliseconds: 220);
  static const Curve animationCurve = Cubic(0.2, 0.8, 0.2, 1);

  const DesktopSidebarSurface({
    super.key,
    required this.width,
    required this.edge,
    required this.child,
    this.animate = true,
  });

  @override
  Widget build(BuildContext context) {
    final side = BorderSide(color: context.cs.outlineVariant);
    return AnimatedContainer(
      duration: animate ? animationDuration : Duration.zero,
      curve: animationCurve,
      width: width,
      child: GlassSurface(
        borderRadius: BorderRadius.zero,
        border: edge == SidebarEdge.left
            ? Border(right: side)
            : Border(left: side),
        // Sidebars never scroll as a whole and are the full height of the
        // window; clip so a child's overflow cannot paint over the divider.
        child: ClipRect(child: child),
      ),
    );
  }
}
