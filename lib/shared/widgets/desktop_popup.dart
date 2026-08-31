import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'glass_surface.dart';
import 'hover_glow.dart';

/// Where the pointer last went down, in global coordinates.
///
/// The Vue app tracked this on `window` so any `showBottomSheet()` caller could
/// be turned into an anchored desktop dropdown without threading an anchor
/// through every call site. [PointerPositionTracker] does the same job here.
Offset? lastPointerDownPosition;

/// Records [lastPointerDownPosition]. Mount once, above the app.
class PointerPositionTracker extends StatelessWidget {
  final Widget child;

  const PointerPositionTracker({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => lastPointerDownPosition = e.position,
      child: child,
    );
  }
}

/// A trailing affordance on a dropdown row — a selected check mark, or a
/// secondary action such as "edit" beside the item it belongs to.
class DesktopPopupAction {
  final IconData icon;
  final Color? color;
  final VoidCallback onTap;

  const DesktopPopupAction({
    required this.icon,
    this.color,
    required this.onTap,
  });
}

/// One row of a desktop dropdown.
class DesktopPopupEntry {
  final String label;
  final IconData? icon;
  final Color? iconColor;
  final String? hint;
  final bool isDestructive;
  final VoidCallback onTap;
  final List<DesktopPopupAction> actions;

  const DesktopPopupEntry({
    required this.label,
    required this.onTap,
    this.icon,
    this.iconColor,
    this.hint,
    this.isDestructive = false,
    this.actions = const [],
  });
}

/// Opens a dropdown anchored at the pointer instead of a bottom sheet.
///
/// On a desktop-sized window a modal bottom sheet for "Rename / Delete" slides
/// a band across the entire screen; the Vue app used `DesktopPopup` for exactly
/// these simple menus. Positioning flips the panel across the anchor when it
/// would overflow and then clamps it into the viewport — handled by
/// [_PopupLayout], which sees the real measured size rather than the height
/// estimate the Vue implementation had to maintain by hand.
Future<T?> showDesktopPopup<T>(
  BuildContext context, {
  String? title,
  required List<DesktopPopupEntry> entries,
  double width = 240,
}) {
  final anchor =
      lastPointerDownPosition ??
      Offset(
        MediaQuery.sizeOf(context).width / 2,
        MediaQuery.sizeOf(context).height / 2,
      );
  return Navigator.of(context, rootNavigator: true).push<T>(
    _DesktopPopupRoute<T>(
      anchor: anchor,
      title: title,
      entries: entries,
      width: width,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

class _DesktopPopupRoute<T> extends PopupRoute<T> {
  final Offset anchor;
  final String? title;
  final List<DesktopPopupEntry> entries;
  final double width;

  _DesktopPopupRoute({
    required this.anchor,
    required this.title,
    required this.entries,
    required this.width,
    required this.barrierLabel,
  });

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 140);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return CustomSingleChildLayout(
      delegate: _PopupLayout(
        anchor: anchor,
        padding: MediaQuery.paddingOf(context),
      ),
      child: _PopupPanel(
        title: title,
        entries: entries,
        width: width,
        onPick: (entry) => _dismissAfter(context, entry.onTap),
        onAction: (action) => _dismissAfter(context, action.onTap),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
        alignment: Alignment.topLeft,
        child: child,
      ),
    );
  }
}

/// Runs a menu item's callback, then closes the dropdown if it is still open.
///
/// Sheet items conventionally dismiss themselves —
/// `Navigator.of(context, rootNavigator: true).pop(result)` — and the caller
/// awaits that result. This route stands in for the sheet on the same
/// navigator, so those callbacks pop *it* and its result reaches the caller
/// unchanged. Popping first instead would leave the item's own pop to close
/// whatever route sat underneath.
void _dismissAfter(BuildContext context, VoidCallback action) {
  final route = ModalRoute.of(context);
  final navigator = Navigator.of(context);
  action();
  if (route != null && route.isActive) navigator.removeRoute(route);
}

class _PopupLayout extends SingleChildLayoutDelegate {
  final Offset anchor;
  final EdgeInsets padding;

  static const double _gap = 12;

  const _PopupLayout({required this.anchor, required this.padding});

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    // Leave room for the viewport edges so a long menu scrolls instead of
    // being clipped off-screen.
    return BoxConstraints.loose(
      Size(
        constraints.maxWidth - _gap * 2,
        constraints.maxHeight - padding.vertical - _gap * 2,
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // Flip across the anchor when the panel would overflow, then clamp — the
    // same two-step the Vue popup did, minus its height guesswork.
    double x = anchor.dx;
    if (x + childSize.width > size.width - _gap) {
      x = anchor.dx - childSize.width;
    }
    double y = anchor.dy;
    if (y + childSize.height > size.height - _gap) {
      y = anchor.dy - childSize.height;
    }
    final maxX = (size.width - childSize.width - _gap).clamp(
      _gap,
      double.infinity,
    );
    final maxY = (size.height - childSize.height - _gap).clamp(
      _gap,
      double.infinity,
    );
    return Offset(x.clamp(_gap, maxX), y.clamp(_gap, maxY));
  }

  @override
  bool shouldRelayout(_PopupLayout oldDelegate) =>
      oldDelegate.anchor != anchor || oldDelegate.padding != padding;
}

class _PopupPanel extends StatelessWidget {
  final String? title;
  final List<DesktopPopupEntry> entries;
  final double width;
  final void Function(DesktopPopupEntry) onPick;
  final void Function(DesktopPopupAction) onAction;

  const _PopupPanel({
    required this.title,
    required this.entries,
    required this.width,
    required this.onPick,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: GlassSurface(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.cs.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            spreadRadius: 1,
          ),
        ],
        child: Material(
          type: MaterialType.transparency,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null && title!.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                    child: Text(
                      title!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Divider(height: 1, color: context.cs.outlineVariant),
                ],
                const SizedBox(height: 4),
                for (final entry in entries)
                  _PopupRow(entry: entry, onPick: onPick, onAction: onAction),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PopupRow extends StatelessWidget {
  final DesktopPopupEntry entry;
  final void Function(DesktopPopupEntry) onPick;
  final void Function(DesktopPopupAction) onAction;

  const _PopupRow({
    required this.entry,
    required this.onPick,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final color = entry.isDestructive ? context.cs.error : context.cs.onSurface;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onPick(entry),
      child: HoverGlow(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            children: [
              if (entry.icon != null) ...[
                Icon(entry.icon, size: 18, color: entry.iconColor ?? color),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.label,
                      style: TextStyle(fontSize: 14, color: color),
                    ),
                    if (entry.hint != null)
                      Text(
                        entry.hint!,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              for (final action in entry.actions) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onAction(action),
                  child: Icon(
                    action.icon,
                    size: 18,
                    color: action.color ?? context.cs.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
