import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_colors.dart';
import 'glass_surface.dart';
import 'glaze_bottom_sheet.dart';

/// The preset dropdown shared by every screen that runs on a named preset.
///
/// It started on the LLM API screen — an accent pill showing the active preset,
/// tapped to open a sheet of the others. This file is that pair, lifted out so
/// the panel does not have to reinvent it: [PresetPill] is the button,
/// [PresetSwitcher.show] is the sheet behind it.
///
/// Everything a preset list needs lives in the sheet rather than on the screen:
/// creating and importing sit in the header, exporting and deleting sit on the
/// row they belong to. The screen keeps the pill and nothing else.

/// An icon button in the switcher's header — "new preset", "import".
class PresetSwitcherHeaderAction {
  final IconData icon;
  final String? tooltip;

  /// Whether the sheet closes before [onTap] runs. Creating a preset usually
  /// closes (the next step is editing it); importing usually does not, so the
  /// imported preset appears in the list that is already open.
  final bool closesSheet;
  final VoidCallback onTap;

  const PresetSwitcherHeaderAction({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.closesSheet = false,
  });
}

/// A trailing icon button on one row — "export", "delete".
class PresetSwitcherRowAction {
  final IconData icon;
  final Color? color;
  final bool closesSheet;
  final VoidCallback onTap;

  const PresetSwitcherRowAction({
    required this.icon,
    required this.onTap,
    this.color,
    this.closesSheet = false,
  });
}

/// One row of the switcher.
class PresetSwitcherEntry {
  final String id;
  final String label;
  final String? sublabel;
  final bool isActive;

  /// Icon shown in place of the radio button. Null keeps the radio.
  final IconData? icon;
  final List<PresetSwitcherRowAction> actions;

  /// Whether picking this row closes the sheet. A picker closes; a list that
  /// stays open to be edited further does not.
  final bool closesSheet;
  final VoidCallback onSelect;

  const PresetSwitcherEntry({
    required this.id,
    required this.label,
    required this.onSelect,
    this.sublabel,
    this.isActive = false,
    this.icon,
    this.actions = const [],
    this.closesSheet = true,
  });
}

/// Builds the rows on every rebuild of the open sheet, so creating, importing
/// or deleting a preset updates the list in place instead of closing it.
typedef PresetSwitcherEntriesBuilder =
    List<PresetSwitcherEntry> Function(BuildContext context, WidgetRef ref);

class PresetSwitcher {
  const PresetSwitcher._();

  static Future<void> show(
    BuildContext context, {
    required String title,
    required PresetSwitcherEntriesBuilder entriesBuilder,
    List<PresetSwitcherHeaderAction> headerActions = const [],
  }) {
    return GlazeBottomSheet.show<void>(
      context,
      title: title,
      headerAction: headerActions.isEmpty
          ? null
          : Builder(
              builder: (context) => GlassBackdropGroup(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final action in headerActions)
                      IconButton(
                        icon: Icon(action.icon, color: context.cs.primary),
                        tooltip: action.tooltip,
                        onPressed: () => _run(
                          context,
                          closesSheet: action.closesSheet,
                          onTap: action.onTap,
                        ),
                      ),
                  ],
                ),
              ),
            ),
      cardsBuilder: (context, ref) => BottomSheetCards(
        items: [
          for (final entry in entriesBuilder(context, ref))
            BottomSheetCardItem(
              id: entry.id,
              label: entry.label,
              sublabel: entry.sublabel,
              icon:
                  entry.icon ??
                  (entry.isActive
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded),
              isActive: entry.isActive,
              actions: [
                for (final action in entry.actions)
                  BottomSheetAction(
                    icon: action.icon,
                    color: action.color ?? context.cs.onSurfaceVariant,
                    onTap: () => _run(
                      context,
                      closesSheet: action.closesSheet,
                      onTap: action.onTap,
                    ),
                  ),
              ],
              onTap: () => _run(
                context,
                closesSheet: entry.closesSheet,
                onTap: entry.onSelect,
              ),
            ),
        ],
      ),
    );
  }

  static void _run(
    BuildContext context, {
    required bool closesSheet,
    required VoidCallback onTap,
  }) {
    if (closesSheet) Navigator.of(context, rootNavigator: true).pop();
    onTap();
  }
}

/// The accent pill that opens a [PresetSwitcher]. Tapping it is the only way
/// into preset management, so it is never hidden — a null [onTap] greys it out
/// rather than removing it.
class PresetPill extends StatelessWidget {
  const PresetPill({
    required this.label,
    required this.onTap,
    this.maxWidth = 220,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = enabled ? context.cs.primary : context.cs.onSurfaceVariant;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        constraints: BoxConstraints(maxWidth: maxWidth),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.keyboard_arrow_down_rounded, color: color, size: 16),
          ],
        ),
      ),
    );
  }
}
