import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/hover_glow.dart';
import 'magic_drawer_models.dart';

class MagicCard extends StatefulWidget {
  final MagicDrawerCardItem item;
  final bool editing;
  final bool hovered;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback? onLongPress;

  /// Lifts the card out of the grid and into the composer's pinned row, from
  /// the up-arrow badge edit mode draws opposite the delete badge. Null for a
  /// card with nothing to pin (the "+" tile) or one already up there.
  final VoidCallback? onPin;

  /// False for cards that back a built-in feature rather than user content:
  /// edit mode still reorders and renames them, but the delete badge is not
  /// drawn, because removing one would take the feature away for good.
  final bool deletable;

  const MagicCard({
    super.key,
    required this.item,
    required this.editing,
    required this.hovered,
    required this.onTap,
    required this.onDelete,
    this.onLongPress,
    this.onPin,
    this.deletable = true,
  });

  @override
  State<MagicCard> createState() => _MagicCardState();
}

class _MagicCardState extends State<MagicCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final editing = widget.editing;
    final hovered = widget.hovered;

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : (hovered ? 1.02 : 1.0),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          decoration: hovered
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: context.cs.primary.withValues(alpha: 0.35),
                      blurRadius: 14,
                    ),
                  ],
                )
              : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(
                  alpha: _pressed || hovered ? 0.08 : 0.04,
                ),
                border: Border.all(
                  color: editing
                      ? context.cs.primary.withValues(alpha: 0.55)
                      : Colors.white.withValues(alpha: 0.06),
                ),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        item.def.icon,
                        size: 20,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.def.label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: context.cs.onSurface,
                                height: 1,
                              ),
                            ),
                            if (item.status != null) ...[
                              const SizedBox(height: 1),
                              Text(
                                item.status!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 9,
                                  color: context.cs.onSurfaceVariant.withValues(
                                    alpha: 0.95,
                                  ),
                                  height: 1,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (editing && widget.deletable)
                    Positioned(
                      top: -8,
                      right: -8,
                      child: MagicCardBadge(
                        icon: Icons.close,
                        color: const Color(0xFFFF3B30),
                        tooltip: 'btn_delete'.tr(),
                        onTap: widget.onDelete,
                      ),
                    ),
                  // Opposite corner from delete, and accent- rather than
                  // danger-coloured: promoting a card is the reversible half of
                  // edit mode, and the two must not be confusable at a glance.
                  if (editing && widget.onPin != null)
                    Positioned(
                      top: -8,
                      left: -8,
                      child: MagicCardBadge(
                        icon: Icons.arrow_upward,
                        color: context.cs.primary,
                        tooltip: 'composer_pin_add'.tr(),
                        onTap: widget.onPin!,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The small circular badge edit mode hangs off a card's corner.
///
/// Shared by the delete badge and the pin badge, and by the composer's pinned
/// row for the matching down-arrow, so the three cannot drift apart in size or
/// weight while meaning the same kind of thing.
class MagicCardBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  /// Diameter. The composer's row uses a smaller badge than the grid, since it
  /// hangs off a 40px circle rather than a full-width card.
  final double size;

  const MagicCardBadge({
    super.key,
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: Semantics(
        button: true,
        label: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(icon, size: size * 0.58, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Sectioned list of available (hidden) drawer items for the
/// "Add Action" sheet. Grouping lives only here - the grid itself
/// stays freely orderable by the user.
class MagicDrawerAddList extends StatelessWidget {
  final List<MagicDrawerItemDef> items;
  final ValueChanged<MagicDrawerItemDef> onSelect;

  const MagicDrawerAddList({
    super.key,
    required this.items,
    required this.onSelect,
  });

  // TODO(l10n): localize section labels alongside 'Coverage'/'Ext Blocks'.
  static String _categoryLabel(MagicDrawerCategory category) =>
      switch (category) {
        MagicDrawerCategory.session => 'Session',
        MagicDrawerCategory.library => 'Library',
        MagicDrawerCategory.config => 'Configuration',
        MagicDrawerCategory.tools => 'Diagnostics & Tools',
      };

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final category in MagicDrawerCategory.values) {
      final sectionItems = items
          .where((item) => item.category == category)
          .toList();
      if (sectionItems.isEmpty) continue;
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
          child: Text(
            _categoryLabel(category).toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: context.cs.onSurfaceVariant.withValues(alpha: 0.8),
            ),
          ),
        ),
      );
      children.addAll(
        sectionItems.map(
          (item) => InkWell(
            onTap: () => onSelect(item),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    item.icon,
                    size: 20,
                    color: context.cs.onSurface.withValues(alpha: 0.85),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 15,
                        color: context.cs.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// Lays out fixed-width cells left-to-right in rows of [columns], like
/// [Wrap], but stretches every cell in a row to match the tallest cell in
/// that row so cards with a status line and cards without one stay level.
class MagicCardGrid extends StatelessWidget {
  final List<Widget> cells;
  final int columns;
  final double spacing;
  final double runSpacing;

  const MagicCardGrid({
    super.key,
    required this.cells,
    required this.columns,
    this.spacing = 6,
    this.runSpacing = 8,
  });

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += columns) {
      final rowCells = cells.skip(i).take(columns).toList();
      if (rows.isNotEmpty) rows.add(SizedBox(height: runSpacing));
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var j = 0; j < rowCells.length; j++) ...[
                if (j > 0) SizedBox(width: spacing),
                rowCells[j],
              ],
            ],
          ),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }
}

class AddMagicCard extends StatelessWidget {
  final VoidCallback onTap;

  const AddMagicCard({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.add,
                size: 20,
                color: context.cs.onSurface.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'action_add'.tr(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: context.cs.onSurface,
                    height: 1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One row of the desktop right sidebar's icon strip.
///
/// Mirrors Vue's `.tools-strip .magic-item`: a 64x48 cell with a hairline
/// bottom rule, a 28px tinted rounded square, and the item's label as a
/// tooltip. Shared by the Magic Drawer strip and the Tools strip so the two
/// cannot drift apart.
class MagicDrawerStripIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const MagicDrawerStripIcon({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      preferBelow: false,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: HoverGlow(
          child: Container(
            width: 64,
            height: 48,
            decoration: BoxDecoration(
              color: active
                  ? scheme.primary.withValues(alpha: 0.08)
                  : Colors.transparent,
              border: Border(
                bottom: BorderSide(
                  color: scheme.onSurface.withValues(alpha: 0.05),
                ),
              ),
            ),
            child: Center(
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: active
                      ? scheme.primary.withValues(alpha: 0.15)
                      : scheme.onSurface.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: active
                      ? scheme.primary
                      : scheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
