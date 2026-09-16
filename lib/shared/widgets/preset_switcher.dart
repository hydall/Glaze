import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../state/preset_sort.dart';
import '../theme/app_colors.dart';
import 'glass_surface.dart';
import 'glaze_bottom_sheet.dart';
import 'list_controls.dart';

/// The preset dropdown shared by every screen that runs on a named preset.
///
/// It started on the LLM API screen — an accent pill showing the active preset,
/// tapped to open a sheet of the others, sorted or dragged into place. This
/// file is that pair, lifted out so other screens do not have to reinvent it:
/// [PresetPill] is the button, [PresetSwitcher.show] is the sheet behind it.
///
/// Everything a preset list needs lives in the sheet rather than on the screen.
/// Actions are never loose buttons: the list's own (new, import) sit in one
/// overflow menu in the header, next to the sort control, and a preset's own
/// (export, delete, whatever else the caller adds) sit in the overflow menu on
/// its row.

/// One row of an overflow menu, in the header or on a preset.
class PresetSwitcherAction {
  final IconData icon;
  final String label;
  final bool isDestructive;

  /// Whether the switcher itself closes before [onTap] runs. Creating a preset
  /// usually closes (the next step is editing it); importing usually does not,
  /// so the imported preset appears in the list that is already open.
  final bool closesSwitcher;
  final VoidCallback onTap;

  const PresetSwitcherAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
    this.closesSwitcher = false,
  });
}

/// One row of the switcher.
class PresetSwitcherEntry {
  final String id;
  final String label;
  final String? sublabel;
  final bool isActive;

  /// What alphabetical sorting compares. Defaults to [label].
  final String? sortName;

  /// When the preset was created, for "date added" sorting.
  final int createdAt;
  final List<PresetSwitcherAction> menu;
  final VoidCallback onSelect;

  const PresetSwitcherEntry({
    required this.id,
    required this.label,
    required this.onSelect,
    this.sublabel,
    this.isActive = false,
    this.sortName,
    this.createdAt = 0,
    this.menu = const [],
  });
}

/// The stored sort of the list being shown, plus the ephemeral "dragging is
/// armed" flag the header's toggle writes. Omit it for a list with no order of
/// its own — the switcher then shows the rows exactly as the builder returns
/// them, and no sort control.
class PresetSwitcherSort {
  final AsyncNotifierProvider<PresetSortNotifier, PresetSortState> sort;
  final StateProvider<bool> reorderArmed;

  const PresetSwitcherSort({required this.sort, required this.reorderArmed});
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
    List<PresetSwitcherAction> menu = const [],
    PresetSwitcherSort? sort,
  }) async {
    await GlazeBottomSheet.show<void>(
      context,
      title: title,
      headerAction: _Header(menu: menu, sort: sort),
      cardsBuilder: (context, ref) {
        final entries = entriesBuilder(context, ref);
        final sortState = sort == null
            ? const PresetSortState()
            : ref.watch(sort.sort).value ?? const PresetSortState();
        final sorted = sort == null
            ? entries
            : sortPresetItems(
                entries,
                sortState,
                idOf: (e) => e.id,
                nameOf: (e) => e.sortName ?? e.label,
                createdAtOf: (e) => e.createdAt,
              );
        final reordering =
            sort != null &&
            sortState.mode == PresetSortMode.manual &&
            ref.watch(sort.reorderArmed);

        return BottomSheetCards(
          items: [
            for (final entry in sorted)
              BottomSheetCardItem(
                id: entry.id,
                label: entry.label,
                sublabel: entry.sublabel,
                icon: entry.isActive
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                isActive: entry.isActive,
                actions: [
                  // One overflow button, never a row of loose icons: a preset's
                  // actions are all one tap away and none of them is a
                  // mis-tap's reach from selecting the preset.
                  if (entry.menu.isNotEmpty)
                    BottomSheetAction(
                      icon: Icons.more_vert_rounded,
                      color: context.cs.onSurfaceVariant,
                      onTap: () => _showMenu(context, entry.label, entry.menu),
                    ),
                ],
                onTap: () {
                  Navigator.of(context, rootNavigator: true).pop();
                  entry.onSelect();
                },
              ),
          ],
          onReorder: reordering
              ? (oldIndex, newIndex) =>
                    _onReorder(ref, sort, sorted, oldIndex, newIndex)
              : null,
        );
      },
    );
    if (sort != null && context.mounted) {
      // The armed drag belongs to the open sheet, not to the screen behind it.
      ProviderScope.containerOf(
        context,
        listen: false,
      ).read(sort.reorderArmed.notifier).state = false;
    }
  }

  static void _onReorder(
    WidgetRef ref,
    PresetSwitcherSort sort,
    List<PresetSwitcherEntry> shown,
    int oldIndex,
    int newIndex,
  ) {
    if (oldIndex == newIndex) return;
    final order = [for (final entry in shown) entry.id];
    order.insert(newIndex, order.removeAt(oldIndex));
    ref.read(sort.sort.notifier).setManualOrder(order);
  }

  /// An overflow menu, as its own sheet over the switcher.
  static void _showMenu(
    BuildContext context,
    String title,
    List<PresetSwitcherAction> actions,
  ) {
    GlazeBottomSheet.show<void>(
      context,
      title: title,
      items: [
        for (final action in actions)
          BottomSheetItem(
            label: action.label,
            icon: action.icon,
            isDestructive: action.isDestructive,
            onTap: () {
              // Pops the menu; a second pop closes the switcher under it when
              // the action asked for that.
              Navigator.of(context, rootNavigator: true).pop();
              if (action.closesSwitcher) {
                Navigator.of(context, rootNavigator: true).pop();
              }
              action.onTap();
            },
          ),
      ],
    );
  }
}

/// Sort control plus the list's own overflow menu, in the switcher's header.
class _Header extends ConsumerWidget {
  const _Header({required this.menu, required this.sort});

  final List<PresetSwitcherAction> menu;
  final PresetSwitcherSort? sort;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sortState = sort == null
        ? null
        : ref.watch(sort!.sort).value ?? const PresetSortState();
    final armed = sort == null ? false : ref.watch(sort!.reorderArmed);

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (sortState != null) ...[
          // Only the manually ordered list has an order to drag rows into.
          if (sortState.mode == PresetSortMode.manual) ...[
            GlazeReorderToggleButton(
              armed: armed,
              tooltip: 'sort_reorder'.tr(),
              onTap: () => ref.read(sort!.reorderArmed.notifier).state = !armed,
            ),
            const SizedBox(width: 8),
          ],
          GlazeSortIconChip(
            icon: sortState.mode.icon,
            tooltip: sortState.mode.label,
            onTap: () => _showSortPicker(context, ref, sortState.mode),
          ),
        ],
        if (menu.isNotEmpty)
          IconButton(
            icon: Icon(Icons.more_vert_rounded, color: context.cs.primary),
            tooltip: 'preset_switcher_menu'.tr(),
            onPressed: () => PresetSwitcher._showMenu(
              context,
              'preset_switcher_menu'.tr(),
              menu,
            ),
          ),
      ],
    );

    // One backdrop capture for the row instead of one per chip: these are plain
    // siblings that never overlap. See [GlassBackdropGroup].
    return GlassBackdropGroup(child: row);
  }

  void _showSortPicker(
    BuildContext context,
    WidgetRef ref,
    PresetSortMode current,
  ) {
    showGlazePickerSheet(
      context,
      title: 'sort_by'.tr(),
      items: [
        for (final mode in PresetSortMode.values)
          GlazePickerItem(
            label: mode.label,
            icon: mode.icon,
            hint: mode.hint,
            isActive: mode == current,
            value: mode,
          ),
      ],
      onSelect: (v) {
        final mode = v as PresetSortMode;
        if (mode == current) return;
        // Another mode has no order to drag rows into: the toggle goes away, so
        // it must not stay armed behind it.
        if (mode != PresetSortMode.manual) {
          ref.read(sort!.reorderArmed.notifier).state = false;
        }
        ref.read(sort!.sort.notifier).setMode(mode);
      },
    );
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
