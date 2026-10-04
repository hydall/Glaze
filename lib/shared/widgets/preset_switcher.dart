import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../state/preset_sort.dart';
import '../theme/app_colors.dart';
import 'glass_surface.dart';
import 'glaze_bottom_sheet.dart';
import 'glaze_list_item.dart';
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

  /// Whether the row is picked while the sheet is multi-selecting. Ignored when
  /// the sheet has no [PresetSwitcherSelection].
  final bool isSelected;

  /// Leading glyph, overriding the default radio/check treatment (used while
  /// selecting, so a picked row shows a check mark).
  final IconData? icon;

  /// Branded mark shown instead of [icon] when the row is not selecting.
  final String? faviconUrl;

  /// What alphabetical sorting compares. Defaults to [label].
  final String? sortName;

  /// When the preset was created, for "date added" sorting.
  final int createdAt;
  final List<PresetSwitcherAction> menu;

  /// Runs on tap. Whether the sheet closes first depends on [closeOnTap].
  final VoidCallback onSelect;

  /// A long press that does not reorder — multi-select, for a list that has
  /// one. Null while dragging is armed, where the drag listener owns it.
  final VoidCallback? onLongPress;

  /// Whether tapping closes the switcher. False while multi-selecting, where a
  /// tap toggles the row in place.
  final bool closeOnTap;

  const PresetSwitcherEntry({
    required this.id,
    required this.label,
    required this.onSelect,
    this.sublabel,
    this.isActive = false,
    this.isSelected = false,
    this.icon,
    this.faviconUrl,
    this.sortName,
    this.createdAt = 0,
    this.menu = const [],
    this.onLongPress,
    this.closeOnTap = true,
  });
}

/// Multi-select chrome for a switcher that has one. The header swaps the sort
/// and menu controls for [header] while [isActive] is true.
class PresetSwitcherSelection {
  final bool Function(WidgetRef ref) isActive;
  final Widget Function(BuildContext context, WidgetRef ref) header;

  const PresetSwitcherSelection({
    required this.isActive,
    required this.header,
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
    PresetSwitcherSelection? selection,
    PresetSwitcherAction? addAction,
  }) async {
    await GlazeBottomSheet.show<void>(
      context,
      title: title,
      headerAction: _Header(
        menu: menu,
        sort: sort,
        selection: selection,
        addAction: addAction,
      ),
      // A plain child list of the shared row, not the sheet's own card list:
      // the API and External Blocks switchers must read exactly like the
      // prompt-preset list.
      child: Consumer(
        builder: (context, ref, _) {
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

          Widget row(PresetSwitcherEntry entry) {
            return GlazeListItem(
              leading: _SwitcherLeading(entry: entry),
              title: entry.label,
              subtitle: entry.sublabel,
              isActive: entry.isActive,
              onTap: () {
                if (entry.closeOnTap) {
                  Navigator.of(context, rootNavigator: true).pop();
                }
                entry.onSelect();
              },
              onLongPress: entry.onLongPress,
              // One overflow button, never a row of loose icons: a preset's
              // actions are all one tap away and none of them is a mis-tap's
              // reach from selecting the preset.
              trailing: entry.menu.isEmpty
                  ? null
                  : GlazeListMenuButton(
                      tooltip: entry.label,
                      onTap: () => _showMenu(context, entry.label, entry.menu),
                    ),
            );
          }

          final Widget list = reordering
              ? ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  buildDefaultDragHandles: false,
                  itemCount: sorted.length,
                  onReorderItem: (oldIndex, newIndex) =>
                      _onReorder(ref, sort, sorted, oldIndex, newIndex),
                  itemBuilder: (_, i) => ReorderableDelayedDragStartListener(
                    key: ValueKey(sorted[i].id),
                    index: i,
                    child: row(sorted[i]),
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [for (final entry in sorted) row(entry)],
                );

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: list,
          );
        },
      ),
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

/// The 32 px leading tile of a switcher row: the entry's own glyph, a brand
/// favicon when it has one, or the radio/check mark of the active state.
class _SwitcherLeading extends StatelessWidget {
  final PresetSwitcherEntry entry;

  const _SwitcherLeading({required this.entry});

  @override
  Widget build(BuildContext context) {
    final icon =
        entry.icon ??
        (entry.isActive
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_unchecked_rounded);
    final favicon = entry.faviconUrl;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: context.cs.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: favicon != null && !entry.isActive
          ? ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                favicon,
                width: 20,
                height: 20,
                errorBuilder: (_, _, _) =>
                    Icon(icon, size: 18, color: context.cs.primary),
              ),
            )
          : Icon(icon, size: 18, color: context.cs.primary),
    );
  }
}

/// Sort control, multi-select chrome and the list's own overflow menu, in the
/// switcher's header.
class _Header extends ConsumerWidget {
  const _Header({
    required this.menu,
    required this.sort,
    this.selection,
    this.addAction,
  });

  final List<PresetSwitcherAction> menu;
  final PresetSwitcherSort? sort;
  final PresetSwitcherSelection? selection;
  final PresetSwitcherAction? addAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Multi-select owns the header while it is on: the sort and add controls
    // would only compete with the bulk actions.
    final sel = selection;
    if (sel != null && sel.isActive(ref)) {
      return sel.header(context, ref);
    }

    final sortState = sort == null
        ? null
        : ref.watch(sort!.sort).value ?? const PresetSortState();
    final armed = sort == null ? false : ref.watch(sort!.reorderArmed);

    if (sortState == null) {
      final buttons = <Widget>[
        if (addAction != null) _actionIcon(context, addAction!),
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
      ];
      if (buttons.isEmpty) return const SizedBox.shrink();
      return GlassBackdropGroup(
        child: Row(mainAxisSize: MainAxisSize.min, children: buttons),
      );
    }

    return PresetSortControls(
      mode: sortState.mode,
      armed: armed,
      onToggleReorder: () =>
          ref.read(sort!.reorderArmed.notifier).state = !armed,
      // Another mode has no order to drag rows into: the toggle goes away, so
      // it must not stay armed behind it.
      onDisarm: () => ref.read(sort!.reorderArmed.notifier).state = false,
      onSelect: (mode) => ref.read(sort!.sort.notifier).setMode(mode),
      trailing: [
        if (addAction != null) _actionIcon(context, addAction!),
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
  }

  Widget _actionIcon(BuildContext context, PresetSwitcherAction action) {
    return IconButton(
      icon: Icon(action.icon, color: context.cs.primary),
      tooltip: action.label,
      onPressed: () {
        if (action.closesSwitcher) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        action.onTap();
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
