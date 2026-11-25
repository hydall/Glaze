import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/desktop/desktop_layout_provider.dart';
import '../shell/desktop/sidebar_sheet_provider.dart';
import '../shell/nav_height_provider.dart';
import '../state/preset_sort.dart';
import '../theme/app_colors.dart';
import 'glass_surface.dart';
import 'glaze_fab.dart';
import 'glaze_list_item.dart';
import 'glaze_toast.dart';
import 'list_controls.dart';
import 'selection_bar.dart';
import 'sheet_view.dart';

/// The multi-selection a [GlazeListScreen] shows a bar for.
class GlazeListSelection {
  final int count;
  final VoidCallback onCancel;
  final VoidCallback onMore;

  const GlazeListSelection({
    required this.count,
    required this.onCancel,
    required this.onMore,
  });
}

/// The list screen the Presets list set the pattern for, shared by the Regex,
/// Lorebooks and Personas tools: a [SheetView] whose list can step into
/// folders, filter, sort, reorder and multi-select, and whose editor opens in
/// the list's place inside the same sheet.
///
/// * [controls] is pinned under the header, so filters and the sort stay in
///   reach at any scroll offset.
/// * While [selection] is set the selection bar takes over: in the header on
///   desktop (in the controls' place), floating over the list on phones.
/// * The add action is a floating button on phones; on desktop it moves into
///   the header (the sidebar panel's app bar, or the window's title bar), so
///   nothing floats over the list there.
/// * While [editing], the list's chrome steps aside: [editorHeaderBottom],
///   [editorActions] and [editorFab] are the editor's own.
///
/// The back chain is the caller's [onBack] — editor, selection, folder, sheet —
/// and [canPop] must say whether any of those inner levels is open.
class GlazeListScreen extends ConsumerWidget {
  final bool startExpanded;
  final String? title;
  final Widget? titleWidget;
  final bool showBack;
  final bool canPop;
  final VoidCallback? onBack;
  final int? shellBranchIndex;

  /// Header actions of the list, placed before the desktop add action.
  final List<SheetViewAction> actions;
  final Widget? controls;
  final GlazeListSelection? selection;

  final String addLabel;
  final VoidCallback? onAdd;

  /// Wraps the add action wherever it is drawn (a guide anchor).
  final Widget Function(Widget child)? decorateAdd;

  final bool editing;
  final List<SheetViewAction> editorActions;
  final Widget? editorHeaderBottom;
  final Widget? editorFab;

  /// A step back inside the editor, for a desktop window's title bar.
  final VoidCallback? innerBack;

  final Widget body;

  const GlazeListScreen({
    super.key,
    this.startExpanded = false,
    this.title,
    this.titleWidget,
    this.showBack = true,
    this.canPop = true,
    this.onBack,
    this.shellBranchIndex,
    this.actions = const [],
    this.controls,
    this.selection,
    required this.addLabel,
    this.onAdd,
    this.decorateAdd,
    this.editing = false,
    this.editorActions = const [],
    this.editorHeaderBottom,
    this.editorFab,
    this.innerBack,
    required this.body,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desktop = isDesktopLayout(context);
    final selection = editing ? null : this.selection;
    // A phone's selection bar floats where the add button would; on desktop
    // the add action stays in the header beside it.
    final add = !editing && onAdd != null && (desktop || selection == null);

    final Widget? headerBottom;
    if (editing) {
      headerBottom = editorHeaderBottom;
    } else if (selection != null && desktop) {
      headerBottom = GlazeSelectionBar(
        compact: true,
        count: selection.count,
        onCancel: selection.onCancel,
        onMore: selection.onMore,
      );
    } else {
      headerBottom = controls;
    }

    Widget? floating;
    if (selection != null && !desktop) {
      // Above whichever chrome sits at the bottom: the shell nav bar when the
      // screen is a route, the safe-area inset in a sheet.
      final navHeight = ref.watch(navHeightProvider);
      final inset = MediaQuery.paddingOf(context).bottom;
      floating = Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            (navHeight > inset ? navHeight : inset) + 16,
          ),
          child: GlazeSelectionBar(
            count: selection.count,
            onCancel: selection.onCancel,
            onMore: selection.onMore,
          ),
        ),
      );
    }

    return SheetView(
      startExpanded: startExpanded,
      showRouteBackground: false,
      shellBranchIndex: shellBranchIndex,
      title: title,
      titleWidget: titleWidget,
      showBack: showBack,
      canPop: canPop,
      onBack: onBack,
      innerBack: innerBack,
      actions: editing
          ? editorActions
          : [
              ...actions,
              if (add && desktop)
                SheetViewAction(
                  icon:
                      decorateAdd?.call(const Icon(Icons.add)) ??
                      const Icon(Icons.add),
                  tooltip: addLabel,
                  onPressed: onAdd!,
                ),
            ],
      headerBottom: headerBottom,
      floating: floating,
      body: body,
      floatingActionButton: editing
          ? editorFab
          : add && !desktop
          ? _decorated(
              GlazeFab(label: addLabel, tooltip: addLabel, onTap: onAdd!),
            )
          : null,
    );
  }

  Widget _decorated(Widget child) => decorateAdd?.call(child) ?? child;
}

/// The sort of a [GlazeListScreen], for the lists that offer one.
class GlazeListSort {
  final PresetSortMode mode;

  /// Dragging is armed from the toggle beside the sort chip, not by the
  /// manual mode alone: while it is off a long press still selects.
  final bool armed;
  final VoidCallback onToggleReorder;
  final ValueChanged<PresetSortMode> onSelect;

  /// Runs when a mode other than manual is picked: the toggle goes away, so
  /// it must not stay armed behind it.
  final VoidCallback onDisarm;

  const GlazeListSort({
    required this.mode,
    required this.armed,
    required this.onToggleReorder,
    required this.onSelect,
    required this.onDisarm,
  });
}

/// The control row pinned under a [GlazeListScreen]'s header, as on the
/// Presets list: [leading] on the left (a type dropdown, a hint), then the
/// filter button, and the drag toggle and sort chip when the list has a
/// [sort].
class GlazeListControls extends StatelessWidget {
  final Widget? leading;
  final int? filterCount;
  final VoidCallback? onFilter;
  final GlazeListSort? sort;

  const GlazeListControls({
    super.key,
    this.leading,
    this.filterCount,
    this.onFilter,
    this.sort,
  });

  @override
  Widget build(BuildContext context) {
    final sort = this.sort;
    return GlassBackdropGroup(
      child: Row(
        children: [
          if (leading != null) Expanded(child: leading!) else const Spacer(),
          if (onFilter != null) ...[
            const SizedBox(width: 8),
            GlazeFilterIconButton(count: filterCount ?? 0, onTap: onFilter!),
          ],
          if (sort != null) ...[
            const SizedBox(width: 8),
            PresetSortControls(
              mode: sort.mode,
              armed: sort.armed,
              onToggleReorder: sort.onToggleReorder,
              onDisarm: sort.onDisarm,
              onSelect: sort.onSelect,
            ),
          ],
        ],
      ),
    );
  }
}

/// Shows the hint that goes with arming the drag toggle: arming is the only
/// moment the gesture needs explaining, so it is a toast rather than a chip.
void showGlazeDragHint(BuildContext context) =>
    GlazeToast.show(context, 'preset_drag_hint'.tr());

/// The scrolling body of a [GlazeListScreen]: [header] rows (a lead, folder
/// rows, hints, an empty state) over the list's rows.
///
/// Each [levelKey] is one level of the list — the top, or one folder — and
/// stepping between levels cross-fades the whole list instead of cutting.
///
/// With [onReorder] set the rows can be dragged: by a long press when
/// [dragByLongPress] (the Presets list, while its drag toggle is armed), or by
/// a [ReorderableDragStartListener] handle the row draws itself.
class GlazeListBody extends StatelessWidget {
  final Object levelKey;
  final List<Widget> header;
  final int itemCount;
  final String Function(int index) itemKey;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final void Function(int oldIndex, int newIndex)? onReorder;
  final bool dragByLongPress;
  final ScrollController? controller;

  /// Space under each row.
  final double rowGap;

  /// Side padding of the [header] rows. Zero for headers whose blocks bring
  /// their own margin (a menu group).
  final double headerPadding;

  const GlazeListBody({
    super.key,
    required this.levelKey,
    this.header = const [],
    this.itemCount = 0,
    required this.itemKey,
    required this.itemBuilder,
    this.onReorder,
    this.dragByLongPress = false,
    this.controller,
    this.rowGap = 0,
    this.headerPadding = 16,
  });

  @override
  Widget build(BuildContext context) {
    final flat = inSidebarPanel(context);
    final top = MediaQuery.paddingOf(context).top + (flat ? 12 : 8);
    // Room for the floating add button (and the selection bar) at the end.
    final bottom = MediaQuery.paddingOf(context).bottom + 96;

    Widget row(BuildContext context, int i) => Padding(
      padding: EdgeInsets.only(bottom: rowGap),
      child: itemBuilder(context, i),
    );

    final keyIndex = <String, int>{
      for (var i = 0; i < itemCount; i++) itemKey(i): i,
    };
    final reorder = onReorder;
    final Widget rows = reorder != null
        ? SliverReorderableList(
            itemCount: itemCount,
            onReorderItem: reorder,
            itemBuilder: (context, i) => dragByLongPress
                ? ReorderableDelayedDragStartListener(
                    key: ValueKey(itemKey(i)),
                    index: i,
                    child: row(context, i),
                  )
                : KeyedSubtree(
                    key: ValueKey(itemKey(i)),
                    child: row(context, i),
                  ),
          )
        : SliverList.builder(
            itemCount: itemCount,
            itemBuilder: (context, i) =>
                KeyedSubtree(key: ValueKey(itemKey(i)), child: row(context, i)),
            // Rows are matched by key, not position, so a row that goes away
            // does not rebuild every row under it from scratch.
            findChildIndexCallback: (key) =>
                key is ValueKey<String> ? keyIndex[key.value] : null,
          );

    final list = CustomScrollView(
      key: PageStorageKey('glaze_list_$levelKey'),
      controller: controller,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(headerPadding, top, headerPadding, 0),
          sliver: SliverList.list(children: header),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, bottom),
          sliver: rows,
        ),
      ],
    );
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      // Both lists are laid out at full size while they overlap, and a tap
      // during the fade belongs to the one arriving on top.
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: [
          for (final child in previous) IgnorePointer(child: child),
          ?current,
        ],
      ),
      child: KeyedSubtree(key: ValueKey(levelKey), child: list),
    );
  }
}

/// A folder as a row of a [GlazeListBody] — the same card a row is, with a
/// chevron — so folders and rows read as one list.
class GlazeFolderRow extends StatelessWidget {
  final IconData icon;
  final String name;
  final String subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onMenu;

  const GlazeFolderRow({
    super.key,
    this.icon = Icons.folder_rounded,
    required this.name,
    required this.subtitle,
    this.onTap,
    this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    return GlazeListItem(
      leading: GlazeListIcon(icon: icon),
      title: name,
      subtitle: subtitle,
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onMenu != null) GlazeListMenuButton(onTap: onMenu!),
          Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: context.cs.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

/// The trailing check of a row while the list is multi-selecting.
class GlazeSelectionCheck extends StatelessWidget {
  final bool selected;

  const GlazeSelectionCheck({super.key, required this.selected});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(5),
      child: Icon(
        selected
            ? Icons.check_circle_rounded
            : Icons.radio_button_unchecked_rounded,
        size: 22,
        color: selected
            ? context.cs.primary
            : context.cs.onSurfaceVariant.withValues(alpha: 0.5),
      ),
    );
  }
}

/// The centred note a [GlazeListBody] shows where its rows would be.
class GlazeListEmptyNote extends StatelessWidget {
  final String label;

  const GlazeListEmptyNote({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant),
        ),
      ),
    );
  }
}
