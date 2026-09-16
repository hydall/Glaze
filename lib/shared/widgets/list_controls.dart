import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'glass_surface.dart';
import 'glaze_bottom_sheet.dart';

/// One row of a [showGlazePickerSheet] list.
class GlazePickerItem {
  final String label;
  final bool isActive;
  final dynamic value;

  /// Leading glyph. When null the row falls back to the plain check-mark
  /// treatment (icon shown only while active).
  final IconData? icon;

  /// Secondary line under [label], explaining what the option does.
  final String? hint;

  const GlazePickerItem({
    required this.label,
    required this.isActive,
    required this.value,
    this.icon,
    this.hint,
  });
}

/// Single-choice picker opened by a [GlazeDropdownChip]: each row carries its
/// own glyph, and the active one is tinted plus tagged with a trailing check.
void showGlazePickerSheet(
  BuildContext context, {
  required String title,
  required List<GlazePickerItem> items,
  required ValueChanged<dynamic> onSelect,
  Widget? headerAction,
}) {
  GlazeBottomSheet.show<void>(
    context,
    title: title,
    headerAction: headerAction,
    items: items.map((item) {
      void select() {
        Navigator.of(context, rootNavigator: true).pop();
        onSelect(item.value);
      }

      return BottomSheetItem(
        icon: item.icon ?? (item.isActive ? Icons.check_rounded : null),
        iconColor: item.icon != null
            ? (item.isActive ? context.cs.primary : context.cs.onSurfaceVariant)
            : context.cs.primary,
        label: item.label,
        hint: item.hint,
        actions: item.icon != null && item.isActive
            ? [
                BottomSheetAction(
                  icon: Icons.check_rounded,
                  color: context.cs.primary,
                  onTap: select,
                ),
              ]
            : const [],
        onTap: select,
      );
    }).toList(),
  );
}

/// Glass pill that opens a picker sheet — the dropdown trigger of a list's
/// control row (catalog provider/sort, presets type).
class GlazeDropdownChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const GlazeDropdownChip({
    super.key,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        height: 32,
        child: GlassSurface(
          borderRadius: BorderRadius.circular(16),
          tint: context.cs.surface,
          border: Border.all(color: context.cs.primary.withValues(alpha: 0.18)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: context.cs.primary,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: context.cs.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass pill showing the active sort mode as an icon, opening a picker sheet
/// with the available modes. Shared by the catalog and the Presets list.
class GlazeSortIconChip extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const GlazeSortIconChip({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          height: 32,
          child: GlassSurface(
            borderRadius: BorderRadius.circular(16),
            tint: context.cs.surface,
            border: Border.all(
              color: context.cs.primary.withValues(alpha: 0.18),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: context.cs.primary),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: context.cs.primary,
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

/// Glass button for a single action next to a chip — the permissions shield
/// beside the External Blocks preset pill, for one.
///
/// Same 32pt glass as [GlazeDropdownChip] and [GlazeReorderToggleButton], with
/// no state to show and no chevron: it acts rather than opens a choice. Give it
/// a [label] unless the icon is unmistakable on its own.
class GlazeActionChip extends StatelessWidget {
  final IconData icon;
  final String? label;
  final String tooltip;
  final VoidCallback onTap;

  const GlazeActionChip({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          height: 32,
          child: GlassSurface(
            borderRadius: BorderRadius.circular(16),
            tint: context.cs.surface,
            border: Border.all(
              color: context.cs.primary.withValues(alpha: 0.18),
            ),
            child: Padding(
              // A bare icon keeps the circle; a labelled one gets room for the
              // text without crowding the glyph.
              padding: EdgeInsets.symmetric(horizontal: label == null ? 7 : 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: context.cs.primary),
                  if (label != null) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        label!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.cs.primary,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass toggle that arms dragging for a manually ordered list, shown next to
/// the sort chip while that mode is picked.
///
/// Rows only move while it is on, which leaves the long press free to mean
/// "select" the rest of the time. Filled while armed, so the mode the list is
/// in is never a guess.
class GlazeReorderToggleButton extends StatelessWidget {
  final bool armed;
  final String tooltip;
  final VoidCallback onTap;

  const GlazeReorderToggleButton({
    super.key,
    required this.armed,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 32,
          height: 32,
          child: GlassSurface(
            borderRadius: BorderRadius.circular(16),
            tint: armed ? context.cs.primary : context.cs.surface,
            border: Border.all(
              color: context.cs.primary.withValues(alpha: armed ? 0.9 : 0.18),
            ),
            child: Center(
              child: Icon(
                Icons.swap_vert_rounded,
                size: 18,
                color: armed ? Colors.white : context.cs.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass button that opens a filter sheet, badged with how many filters are
/// currently applied.
class GlazeFilterIconButton extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const GlazeFilterIconButton({
    super.key,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            GlassSurface(
              borderRadius: BorderRadius.circular(16),
              tint: context.cs.surface,
              border: Border.all(
                color: context.cs.primary.withValues(alpha: 0.18),
              ),
              child: Center(
                child: Icon(
                  Icons.filter_list_rounded,
                  size: 18,
                  color: context.cs.primary,
                ),
              ),
            ),
            if (count > 0)
              Positioned(
                top: -2,
                right: -2,
                child: Container(
                  constraints: const BoxConstraints(
                    minWidth: 16,
                    minHeight: 16,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: context.cs.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
