import 'package:flutter/material.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/hover_glow.dart';
import 'magic_drawer_models.dart';

class MagicDrawerHeader extends StatelessWidget {
  final bool editing;
  final VoidCallback onToggleEditing;

  /// Opens the "Add Action" sheet. Null when every item is already placed,
  /// in which case the button is hidden.
  final VoidCallback? onAdd;

  const MagicDrawerHeader({
    super.key,
    required this.editing,
    required this.onToggleEditing,
    this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'Quick Access',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurface,
              letterSpacing: -0.2,
            ),
          ),
          const Spacer(),
          if (onAdd != null) ...[
            GestureDetector(
              onTap: onAdd,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.18),
                  ),
                ),
                child: Icon(Icons.add, size: 18, color: context.cs.onSurface),
              ),
            ),
            const SizedBox(width: 8),
          ],
          GestureDetector(
            onTap: onToggleEditing,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: editing
                    ? context.cs.primary.withValues(alpha: 0.22)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(17),
                border: Border.all(
                  color: editing
                      ? context.cs.primary.withValues(alpha: 0.38)
                      : Colors.white.withValues(alpha: 0.18),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    editing ? Icons.check : Icons.edit,
                    size: 16,
                    color: editing ? context.cs.primary : context.cs.onSurface,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    editing ? 'Done' : 'Edit',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: editing
                          ? context.cs.primary
                          : context.cs.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MagicCard extends StatefulWidget {
  final MagicDrawerCardItem item;
  final bool editing;
  final bool hovered;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback? onLongPress;

  const MagicCard({
    super.key,
    required this.item,
    required this.editing,
    required this.hovered,
    required this.onTap,
    required this.onDelete,
    this.onLongPress,
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
                  if (editing)
                    Positioned(
                      top: -8,
                      right: -8,
                      child: GestureDetector(
                        onTap: widget.onDelete,
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: const BoxDecoration(
                            color: Color(0xFFFF3B30),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Color(0x4DFF3B30),
                                blurRadius: 8,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.close,
                            size: 14,
                            color: Colors.white,
                          ),
                        ),
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
                  'Add',
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
