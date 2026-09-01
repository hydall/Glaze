import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// One entry of a [DesktopToolStrip].
class DesktopToolStripItem {
  final String id;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const DesktopToolStripItem({
    required this.id,
    required this.icon,
    required this.label,
    required this.onTap,
  });
}

/// The narrow icon column of the desktop right sidebar — port of Vue's
/// `.tools-strip` (DesktopRightSidebar.vue).
///
/// It stands in for the sidebar's full content in two situations, and both
/// modes of the sidebar (Tools and chat Quick Access) use it the same way:
///
/// * the sidebar is collapsed, so the strip *is* the sidebar; and
/// * a sheet is open in an expanded sidebar, where the strip pins itself to
///   the sheet's left edge so the other entries stay one click away.
///
/// Items stack from the **top**, matching the Vue original — the column used
/// to be vertically centred here, which floated the icons away from the header
/// and left a gap the reference build never had.
class DesktopToolStrip extends StatelessWidget {
  final List<DesktopToolStripItem> items;

  /// Id of the entry whose sheet is currently open, tinted like Vue's
  /// `.magic-item.active`. Null when nothing is open.
  final String? activeId;

  /// Room left above the first icon so the strip clears the sheet header when
  /// it overlays one. Mirrors `.left-icon-strip { padding-top: 56px }`.
  final double topPadding;

  const DesktopToolStrip({
    super.key,
    required this.items,
    this.activeId,
    this.topPadding = 0,
  });

  /// Width of the strip when it overlays an open sheet
  /// (`.left-icon-strip { width: 60px }`).
  static const double overlayWidth = 60;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      // Top-aligned: the column starts under [topPadding] and grows down.
      padding: EdgeInsets.only(top: topPadding),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: items
            .map((item) => _StripIcon(item: item, active: item.id == activeId))
            .toList(),
      ),
    );
  }
}

class _StripIcon extends StatefulWidget {
  final DesktopToolStripItem item;
  final bool active;

  const _StripIcon({required this.item, required this.active});

  @override
  State<_StripIcon> createState() => _StripIconState();
}

class _StripIconState extends State<_StripIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // `.tools-strip .magic-item` — a full-width row, bottom-ruled, whose
    // background tints on hover and while its sheet is open.
    final Color background = widget.active
        ? const Color(0x14528BCC) // rgba(82,139,204,0.08)
        : _hovered
        ? Colors.white.withValues(alpha: 0.04)
        : Colors.transparent;

    return Tooltip(
      message: widget.item.label,
      preferBelow: false,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.item.onTap,
          child: Container(
            width: double.infinity,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              border: Border(
                bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
              ),
            ),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: widget.active
                    ? const Color(0x26528BCC) // rgba(82,139,204,0.15)
                    : Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                widget.item.icon,
                size: 18,
                color: widget.active
                    ? context.cs.primary
                    : Colors.white.withValues(alpha: 0.8),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
