import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/shell/desktop/desktop_layout_provider.dart';
import '../../shared/shell/desktop/sidebar_sheet_provider.dart';
import '../../shared/widgets/menu_group.dart';
import '../../core/import/silly_tavern_preset_parser.dart';
import '../../core/models/preset.dart';
import '../../core/models/preset_folder.dart';
import '../../core/services/featured_presets.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/preset_folder_provider.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/shell/nav_height_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/folder_name_dialog.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/list_controls.dart';
import '../../shared/widgets/sheet_view.dart';
import '../../shared/widgets/glaze_error_dialog.dart';
import '../../shared/widgets/glaze_toast.dart';
import 'preset_connections_sheet.dart';
import 'preset_cover_service.dart';
import 'preset_deletion.dart';
import 'preset_editor_screen.dart';
import 'preset_entry.dart';
import 'preset_export.dart';
import 'preset_image.dart';
import 'preset_list_provider.dart';
import 'preset_selection_provider.dart';
import 'preset_sort.dart';
import 'widgets/add_presets_to_folder_sheet.dart';
import 'widgets/animated_preset_row.dart';
import 'widgets/preset_filter_sheet.dart';
import 'widgets/preset_folders_section.dart';
import 'widgets/preset_options_sheet.dart';
import 'widgets/preset_small_badge.dart';
import '../../shared/widgets/glaze_sheet.dart';
import '../../shared/widgets/selection_bar.dart';
import '../guides/guide_anchor.dart';
import '../guides/guide_service.dart';

/// Nominal height of one preset row (card + the gap below it). Only used to
/// estimate the scroll offset of the active preset before its row is laid out;
/// [Scrollable.ensureVisible] corrects the estimate on the following frame.
const double _kRowExtent = 72;

/// How long the list takes to cross-fade when the user steps into a folder or
/// back out of it.
const Duration _kFolderFade = Duration(milliseconds: 220);

class PresetListScreen extends ConsumerStatefulWidget {
  final bool startExpanded;

  /// Active chat, forwarded to the preset editor so the Author's Note block can
  /// edit the session-scoped note. Null when opened outside a chat.
  final String? charId;
  const PresetListScreen({super.key, this.startExpanded = false, this.charId});

  @override
  ConsumerState<PresetListScreen> createState() => _PresetListScreenState();
}

class _PresetListScreenState extends ConsumerState<PresetListScreen> {
  Preset? _editingPreset;
  bool _isCreating = false;
  GlobalKey<PresetEditorBodyState> _editorKey =
      GlobalKey<PresetEditorBodyState>();

  /// Header buttons for the prompt block whose editor is open inside the
  /// preset editor, or null when none is.
  PresetBlockEditorActions? _blockActions;

  /// Folder currently being browsed, or null at the top level.
  String? _currentFolderId;

  /// Set once the screen has decided which folder to open on (see
  /// [_resolveInitialFolder]). Guards the decision to a single frame — the one
  /// where both the folder list and its membership stream have arrived — so it
  /// can never fight the user's own navigation afterwards.
  bool _didResolveInitialFolder = false;

  /// The folder [_resolveInitialFolder] opened, if it opened one. The auto
  /// reveal is normally confined to the top-level list; inside this one folder
  /// it still runs, because the row it would scroll to is exactly why the
  /// folder was opened.
  String? _autoOpenedFolderId;
  PresetListFilters _filters = const PresetListFilters();

  /// Controller of the list that is currently on top. Each list owns its own
  /// (see [_ScrollHost]) because the folder cross-fade keeps the outgoing one
  /// mounted while the incoming one builds.
  ScrollController? _scrollController;

  /// Key on the header sliver, used to measure what sits above the rows when
  /// estimating the active preset's scroll offset.
  final GlobalKey _headerKey = GlobalKey();

  /// Key on the active preset's row, used to fine-tune that scroll.
  final GlobalKey _activeRowKey = GlobalKey();

  /// The list scrolls to the active preset once per screen open, not on every
  /// rebuild — otherwise the user could never scroll away from it.
  bool _didAutoScroll = false;

  /// Set until that scroll has been made. [_activeRowKey] is only attached
  /// while it holds, so the two lists that overlap during a folder cross-fade
  /// can never claim the same [GlobalKey].
  bool _revealPending = true;

  /// Rows playing their collapse animation. The presets behind them still
  /// exist — the delete is committed once the animation has run — so the list
  /// keeps rendering them, shrinking and untappable, until then.
  final Set<String> _exitingKeys = {};

  /// Dragging is armed from the chip next to the sort picker, not by the manual
  /// mode alone: while it is off a long press still opens multi-select, which is
  /// the gesture users reach for far more often than reordering.
  bool _reorderArmed = false;

  bool get _inEditor => _isCreating || _editingPreset != null;

  @override
  void initState() {
    super.initState();
    // The selection provider outlives this screen, so a selection left behind
    // when the sheet was dismissed would reopen with a stale bar. Reset after
    // the first frame (writing to a provider during initState is not allowed).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(presetSelectionProvider.notifier).clear();
      if (mounted) maybeShowGuide(context, AppGuide.presets);
    });
  }

  // No dispose override: the scroll controllers belong to the lists that use
  // them and are disposed with them — see [_ScrollHost].

  void _openEditor(Preset? preset) {
    setState(() {
      _editingPreset = preset;
      _isCreating = preset == null;
      // A fresh body starts on the block list; anything left over from the last
      // editor would point the header buttons at a block that is gone.
      _blockActions = null;
      // Recreate the editor key so PresetEditorBody's initState fires
      // and picks up the new preset's blocks instead of the old ones.
      _editorKey = GlobalKey<PresetEditorBodyState>();
    });
  }

  void _closeEditor() {
    setState(() {
      _editingPreset = null;
      _isCreating = false;
      _blockActions = null;
    });
  }

  void _handleBack() {
    if (_inEditor) {
      final handled = _editorKey.currentState?.handleBack() ?? false;
      if (!handled) _closeEditor();
      return;
    }
    // Selection mode and the folder view are both "inner" states: back leaves
    // them before it leaves the screen.
    if (ref.read(presetSelectionProvider).active) {
      ref.read(presetSelectionProvider.notifier).clear();
      return;
    }
    if (_currentFolderId != null) {
      _leaveFolder();
      return;
    }
    if (widget.startExpanded) {
      closeExpandedToolScreen(context, ref);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  /// Opens the list on the folder the active preset lives in — see
  /// [initialPresetFolderId] for which folder that is.
  ///
  /// Runs at most once per screen, and only once both the folder list and the
  /// membership stream have a value: reading them mid-load would settle on "no
  /// folder" before the answer had arrived. Assigning [_currentFolderId] during
  /// the build that consumes it is deliberate — the decision is a property of
  /// the first frame, so deferring it to a post-frame `setState` would flash the
  /// top-level list first.
  void _resolveInitialFolder({
    required String? activeId,
    required PresetKind kind,
  }) {
    if (_didResolveInitialFolder || _currentFolderId != null) return;
    final folders = ref.watch(presetFoldersProvider).value;
    final memberships = ref.watch(presetFolderMembershipsProvider).value;
    if (folders == null || memberships == null) return;

    _didResolveInitialFolder = true;
    final target = initialPresetFolderId(
      activeId: activeId,
      kind: kind,
      folders: folders,
      memberships: memberships,
    );
    if (target == null) return;
    _currentFolderId = target;
    _autoOpenedFolderId = target;
  }

  void _openFolder(String id) {
    ref.read(presetSelectionProvider.notifier).clear();
    // The auto-scroll is done with once the user navigates, and its key must be
    // free before a second list is mounted alongside the current one.
    _revealPending = false;
    setState(() => _currentFolderId = id);
  }

  void _leaveFolder() {
    _revealPending = false;
    setState(() => _currentFolderId = null);
  }

  String? _folderName(String id) {
    final folders = ref.watch(presetFoldersProvider).value;
    return folders?.where((f) => f.id == id).firstOrNull?.name;
  }

  @override
  Widget build(BuildContext context) {
    final presets = ref.watch(presetListProvider);
    final activeId = ref.watch(activePresetIdProvider);
    final selection = ref.watch(presetSelectionProvider);
    final desktop = isDesktopLayout(context);

    _resolveInitialFolder(activeId: activeId, kind: PresetKind.normal);
    final folderId = _currentFolderId;

    final String title;
    if (_inEditor) {
      title = _editingPreset != null ? 'Edit Preset' : 'New Preset';
    } else if (folderId != null) {
      title = _folderName(folderId) ?? 'Presets';
    } else {
      title = 'Presets';
    }

    return SheetView(
      startExpanded: widget.startExpanded,
      showRouteBackground: false,
      title: title,
      showBack: true,
      onBack: _handleBack,
      // Opened as a modal sheet, a back gesture unwinds the same chain the
      // header's back button walks — leave the editor, drop the selection, step
      // out of the folder — and only closes the sheet once none of those is
      // left. Without this every one of them would be skipped and the sheet
      // would vanish on the first swipe.
      canPop: !_inEditor && !selection.active && folderId == null,
      // The type dropdown, the filter button and the sort chip belong to the
      // header, not to the scroll content: pinned there they stay reachable at
      // any scroll offset, in the modal sheet and as a fullscreen route alike.
      actions: _blockActions == null
          ? const []
          : presetBlockEditorSheetActions(context, _blockActions!),
      // On desktop the sheet lives in the sidebar, where a bar pinned to the
      // bottom ends up far from the list it acts on: the selection takes the
      // controls row's place in the header instead.
      headerBottom: _inEditor
          ? null
          : selection.active && desktop
          ? GlazeSelectionBar(
              compact: true,
              count: selection.count,
              onCancel: () =>
                  ref.read(presetSelectionProvider.notifier).clear(),
              onMore: () => _showSelectionActions(context, selection),
            )
          : _buildControlsRow(context),
      floating: _inEditor || !selection.active || desktop
          ? null
          : Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, _floatingBottom()),
                child: GlazeSelectionBar(
                  count: selection.count,
                  onCancel: () =>
                      ref.read(presetSelectionProvider.notifier).clear(),
                  onMore: () => _showSelectionActions(context, selection),
                ),
              ),
            ),
      body: _inEditor
          ? PresetEditorBody(
              key: _editorKey,
              preset: _editingPreset,
              charId: widget.charId,
              onDeleted: _closeEditor,
              onBlockEditorChanged: (actions) =>
                  setState(() => _blockActions = actions),
            )
          : presets.when(
              // A save from the editor invalidates the list; keep the rows on
              // screen instead of flashing a spinner while it reloads.
              skipLoadingOnReload: true,
              loading: () => const Center(child: GlazeSpinner()),
              error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
              // The inner Builder reads the MediaQuery padding SheetView
              // overrides for its body (header inset + nav bar), which the
              // outer context doesn't carry.
              data: (list) => Builder(
                builder: (context) => _buildBody(context, list, activeId),
              ),
            ),
    );
  }

  /// The selection bar floats above whichever chrome sits at the bottom: the
  /// shell nav bar when the screen is opened as a route, the safe-area inset
  /// when it is opened as a modal sheet.
  double _floatingBottom() {
    final navHeight = ref.watch(navHeightProvider);
    final inset = MediaQuery.paddingOf(context).bottom;
    return (navHeight > inset ? navHeight : inset) + 16;
  }

  // ─── list ──────────────────────────────────────────────────────────────

  /// Identity of a row inside the list, so its element (and the animation state
  /// riding on it) stays with its preset as the rows around it come and go.
  static String _rowKey(PresetItem item) => 'row_${item.memberKey}';

  Widget _buildBody(
    BuildContext context,
    List<Preset> presets,
    String? activeId,
  ) {
    final folderId = _currentFolderId;
    final memberships =
        ref.watch(presetFolderMembershipsProvider).value ??
        PresetFolderMemberships.empty;
    final selection = ref.watch(presetSelectionProvider);
    final sort = ref.watch(presetSortProvider).value ?? const PresetSortState();
    final hasFolders =
        (ref.watch(presetFoldersProvider).value ?? const []).isNotEmpty;

    final allItems = [for (final p in presets) PresetItem(preset: p)];
    var items = allItems;
    if (folderId != null) {
      final keys = memberships.presetsIn(folderId);
      items = items.where((e) => keys.contains(e.memberKey)).toList();
    } else {
      // A preset filed into a folder lives there, not twice: the top level
      // lists the folders (above) plus the presets that are in none of them.
      items = items
          .where((e) => memberships.foldersOf(e.id, e.kind).isEmpty)
          .toList();
    }
    items = items.where(_filters.matches).toList();
    items = sortPresetItems(items, sort);
    final reordering = sort.mode == PresetSortMode.manual && _reorderArmed;

    bool isActive(PresetItem item) => activeId == item.preset.id;

    final activeIndex = items.indexWhere(isActive);

    // Auto-reveal the active preset the first time the unfiltered list is
    // shown — at the top level, or inside the folder the screen opened on its
    // behalf.
    if (_didResolveInitialFolder &&
        (folderId == null || folderId == _autoOpenedFolderId) &&
        !_filters.isActive) {
      _scheduleAutoScroll(activeIndex);
    }

    final topInset = MediaQuery.paddingOf(context).top;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // In a sidebar panel the rows run edge to edge, one under the other, and
    // start right under the header.
    final flat = inSidebarPanel(context);
    final gutter = flat ? 0.0 : 16.0;

    final rowIndexByKey = <String, int>{
      for (var i = 0; i < items.length; i++) _rowKey(items[i]): i,
    };

    Widget row(int i) {
      final item = items[i];
      final active = isActive(item);
      // Keyed by preset, so a row's state follows its preset when the list
      // reorders and a row that just appeared gets a fresh state — which is
      // what plays its entry animation.
      return AnimatedPresetRow(
        key: ValueKey(_rowKey(item)),
        exiting: _exitingKeys.contains(item.memberKey),
        child: Padding(
          key: _revealPending && i == activeIndex ? _activeRowKey : null,
          padding: EdgeInsets.only(bottom: flat ? 0 : 10),
          child: GuideAnchor(
            // The guide points at the active preset, or the first one when
            // none is active.
            id: i == (activeIndex < 0 ? 0 : activeIndex)
                ? GuideIds.presetsRow
                : null,
            child: _PsCard(
              item: item,
              isActive: active,
              selectionMode: selection.active,
              isSelected: selection.contains(item.id, item.kind),
              onTap: () => _onCardTap(item, active),
              // While dragging is armed a long press lifts the row, so it can't
              // also open multi-select — that moves to the row menu.
              onLongPress: reordering
                  ? null
                  : () => _startSelection(item.id, item.kind),
              onConnections: () =>
                  showPresetConnections(context, item.preset.id),
              onEdit: () => _openEditor(item.preset),
              onMenu: () => _showItemMenu(item),
            ),
          ),
        ),
      );
    }

    final list = _ScrollHost(
      onCreated: (controller) => _scrollController = controller,
      onDisposed: (controller) {
        if (identical(_scrollController, controller)) _scrollController = null;
      },
      builder: (controller) => CustomScrollView(
        controller: controller,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(16, (flat ? 0 : 12) + topInset, 16, 0),
            sliver: SliverToBoxAdapter(
              child: KeyedSubtree(
                // Only while the auto-scroll still needs to measure this block:
                // the two lists that overlap during the folder cross-fade must
                // never both carry the same [GlobalKey].
                key: _revealPending && folderId == null ? _headerKey : null,
                child: folderId == null
                    ? PresetFoldersSection(onOpenFolder: _openFolder)
                    : const SizedBox.shrink(),
              ),
            ),
          ),
          // "No presets" would be a lie at the top level while folders are
          // listed above it — every preset simply lives in one of them.
          if (items.isEmpty && !(folderId == null && hasFolders))
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 40),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: Text(
                    folderId != null
                        ? 'preset_folder_empty'.tr()
                        : 'label_no_presets'.tr(),
                    style: TextStyle(color: context.cs.onSurfaceVariant),
                  ),
                ),
              ),
            )
          else if (reordering)
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: gutter),
              sliver: SliverReorderableList(
                itemCount: items.length,
                onReorderItem: (oldIndex, newIndex) =>
                    _onManualReorder(items, allItems, oldIndex, newIndex),
                itemBuilder: (_, i) => ReorderableDelayedDragStartListener(
                  key: ValueKey(items[i].memberKey),
                  index: i,
                  child: row(i),
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: gutter),
              sliver: SliverList.builder(
                itemCount: items.length,
                itemBuilder: (_, i) => row(i),
                // Without this the delegate matches rows by position, so
                // deleting one rebuilds every row under it from scratch — and
                // each of those would replay its entry animation instead of
                // simply sliding up into the freed slot.
                findChildIndexCallback: (key) =>
                    key is ValueKey<String> ? rowIndexByKey[key.value] : null,
              ),
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              16,
              flat ? 16 : 4,
              16,
              16 + bottomInset,
            ),
            sliver: SliverToBoxAdapter(
              child: GuideAnchor(
                id: GuideIds.presetsAdd,
                child: _buildAddButton(context),
              ),
            ),
          ),
        ],
      ),
    );

    // Stepping into a folder — and back out of it — swaps the whole list, so it
    // cross-fades instead of cutting: the folder's rows appear over the ones
    // they replace rather than snapping into their place.
    return AnimatedSwitcher(
      duration: _kFolderFade,
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      // Both lists are laid out at the viewport's full size while they overlap,
      // so the incoming one is already scrolled and positioned exactly where it
      // will stay once it is opaque.
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: [
          // The list on its way out is still painted, but a tap during the
          // fade belongs to the one arriving on top of it.
          for (final child in previousChildren) IgnorePointer(child: child),
          ?currentChild,
        ],
      ),
      child: KeyedSubtree(key: ValueKey(folderId ?? '#root'), child: list),
    );
  }

  /// Commits a drag in the manually ordered list.
  ///
  /// [visible] is what the user actually dragged over (one folder, one type,
  /// one token range); [all] is every preset there is. The dragged row is
  /// re-anchored inside the *full* order so rows hidden by a filter — or filed
  /// away in a folder — keep the places they had.
  ///
  /// [newIndex] is the row's final index: `onReorderItem` already accounts for
  /// the item being lifted out of [oldIndex] first.
  void _onManualReorder(
    List<PresetItem> visible,
    List<PresetItem> all,
    int oldIndex,
    int newIndex,
  ) {
    if (oldIndex == newIndex) return;
    final sort = ref.read(presetSortProvider).value ?? const PresetSortState();
    final visibleKeys = [for (final e in visible) e.memberKey];
    final moved = visibleKeys.removeAt(oldIndex);
    visibleKeys.insert(newIndex, moved);
    // The row the dragged one now follows; null when it landed first.
    final anchor = newIndex == 0 ? null : visibleKeys[newIndex - 1];

    final full = [
      for (final e in sortPresetItems(
        all,
        sort.copyWith(mode: PresetSortMode.manual),
      ))
        e.memberKey,
    ];
    full.remove(moved);
    final anchorIndex = anchor == null ? -1 : full.indexOf(anchor);
    full.insert(anchorIndex + 1, moved);

    unawaited(ref.read(presetSortProvider.notifier).setManualOrder(full));
  }

  void _onCardTap(PresetItem item, bool isActive) {
    if (ref.read(presetSelectionProvider).active) {
      ref.read(presetSelectionProvider.notifier).toggle(item.id, item.kind);
      return;
    }
    if (isActive) return;
    setActivePreset(ref, item.preset.id);
  }

  /// Jumps the list so the active preset is visible on open. Runs at most once.
  void _scheduleAutoScroll(int index) {
    if (_didAutoScroll || index < 0) return;
    _didAutoScroll = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealIndex(index));
  }

  void _revealIndex(int index) {
    final controller = _scrollController;
    if (!mounted || controller == null || !controller.hasClients) {
      _revealPending = false;
      return;
    }

    final headerBox =
        _headerKey.currentContext?.findRenderObject() as RenderBox?;
    final double headerExtent = headerBox?.size.height ?? 0.0;
    final viewport = controller.position.viewportDimension;
    // Land the row a quarter of the way down the viewport rather than flush
    // against the top edge, so the presets around it stay in context. Cards
    // carrying a cover are taller than [_kRowExtent], so this is only a first
    // approximation.
    final double estimate =
        headerExtent + index * _kRowExtent - viewport * 0.25;
    controller.jumpTo(estimate.clamp(0.0, controller.position.maxScrollExtent));

    // Correct the estimate now that the row itself is built (it is, after that
    // jump — the error stays inside the viewport's cache extent).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _activeRowKey.currentContext;
      // Done with the key from here on: the row drops it on the next rebuild,
      // leaving it free for whichever list the folder cross-fade mounts next.
      _revealPending = false;
      if (!mounted || ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Widget _buildAddButton(BuildContext context) {
    return Material(
      color: context.cs.primary,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        mouseCursor: SystemMouseCursors.click,
        onTap: () => _showAddSheet(context),
        borderRadius: BorderRadius.circular(14),
        splashColor: Colors.white.withValues(alpha: 0.1),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.add, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(
                'preset_add_import'.tr(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── filters ───────────────────────────────────────────────────────────

  /// Control row pinned to the header, mirroring the catalog's: the
  /// filter-sheet button and the sort chip on the right.
  Widget _buildControlsRow(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final mode =
            ref.watch(presetSortProvider).value?.mode ?? PresetSortMode.manual;
        final row = Row(
          children: [
            const Spacer(),
            GlazeFilterIconButton(
              count: _filters.activeCount,
              onTap: () => _showFilterSheet(context),
            ),
            const SizedBox(width: 8),
            // Only the manually ordered list has an order to drag rows into.
            if (mode == PresetSortMode.manual) ...[
              GlazeReorderToggleButton(
                armed: _reorderArmed,
                tooltip: 'sort_reorder'.tr(),
                onTap: _toggleReorderArmed,
              ),
              const SizedBox(width: 8),
            ],
            GlazeSortIconChip(
              icon: mode.icon,
              tooltip: mode.label,
              onTap: () => _showSortPicker(context, mode),
            ),
          ],
        );

        // One backdrop capture for the row instead of one per chip: these are
        // plain siblings that never overlap. See [GlassBackdropGroup].
        return GuideAnchor(
          id: GuideIds.presetsControls,
          child: GlassBackdropGroup(child: row),
        );
      },
    );
  }

  /// Arms or disarms dragging. Arming clears any multi-select — the two modes
  /// claim the same long press, so only one of them can be on.
  void _toggleReorderArmed() {
    final armed = !_reorderArmed;
    setState(() => _reorderArmed = armed);
    if (!armed) return;
    ref.read(presetSelectionProvider.notifier).clear();
    // Arming is the only moment the drag gesture needs explaining, so it is a
    // toast rather than a permanent chip.
    GlazeToast.show(context, 'preset_drag_hint'.tr());
  }

  /// Enters multi-select, disarming a drag left over from the manual mode so a
  /// long press cannot mean both things at once.
  void _startSelection(String presetId, PresetKind kind) {
    if (_reorderArmed) setState(() => _reorderArmed = false);
    ref.read(presetSelectionProvider.notifier).start(presetId, kind);
  }

  void _showSortPicker(BuildContext context, PresetSortMode current) {
    showPresetSortPicker(
      context,
      current: current,
      // Another mode has no order to drag rows into: the toggle goes away, so
      // it must not stay armed behind it.
      onDisarm: () {
        if (_reorderArmed && mounted) setState(() => _reorderArmed = false);
      },
      onSelect: (mode) =>
          unawaited(ref.read(presetSortProvider.notifier).setMode(mode)),
    );
  }

  void _showFilterSheet(BuildContext context) {
    showGlazeSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PresetFilterSheet(
        filters: _filters,
        onApply: (f) {
          if (mounted) setState(() => _filters = f);
        },
      ),
    );
  }

  // ─── per-row overflow menu ─────────────────────────────────────────────

  void _showItemMenu(PresetItem item) => _showPlainMenu(item.preset);

  void _showPlainMenu(Preset preset) {
    final notifier = ref.read(presetListProvider.notifier);
    showPresetOptions(
      context,
      isFeatured: isFeaturedPreset(preset.id),
      hasImage: preset.imagePath != null && preset.imagePath!.isNotEmpty,
      canDelete: true,
      onSelect: () => _startSelection(preset.id, PresetKind.normal),
      onRename: () => showPresetRename(
        context,
        currentName: preset.name,
        onRename: (val) {
          final name = val.trim();
          if (name.isEmpty) return;
          unawaited(notifier.updatePreset(preset.copyWith(name: name)));
        },
      ),
      onSetAuthor: () => showPresetAuthorDialog(
        context,
        currentAuthor: preset.author ?? '',
        onSubmit: (val) => unawaited(
          notifier.updatePreset(
            preset.copyWith(author: val.isEmpty ? null : val),
          ),
        ),
      ),
      onPickImage: () => unawaited(_changeCover(preset)),
      onRemoveImage: () => unawaited(_removeCover(preset)),
      onAddToFolder: () =>
          _showAddToFolder([PresetFolderTarget(preset.id, PresetKind.normal)]),
      onClone: () => unawaited(_clonePreset(preset)),
      onExport: () => unawaited(exportPreset(context, preset)),
      onDelete: () => unawaited(_deleteItems([PresetItem(preset: preset)])),
    );
  }

  /// Collapses the rows of [targets] and only then deletes the presets behind
  /// them, so the list closes the gap on an empty slot instead of yanking a
  /// visible card out from under the ones below it.
  Future<void> _deleteItems(List<PresetItem> targets) async {
    if (targets.isEmpty) return;
    final keys = [for (final item in targets) item.memberKey];
    setState(() => _exitingKeys.addAll(keys));
    await Future<void>.delayed(AnimatedPresetRow.exitDuration);

    try {
      for (final item in targets) {
        // Each delete awaits a DB round-trip; bail out if the screen went away
        // in the meantime rather than reading a disposed ref.
        if (!mounted) return;
        await deletePresetAndFolderMemberships(ref, item.id, item.kind);
      }
    } finally {
      // The rows are gone by now, but a delete that failed would otherwise
      // leave its preset collapsed to nothing and unreachable.
      if (mounted) setState(() => _exitingKeys.removeAll(keys));
    }
  }

  Future<void> _clonePreset(Preset preset) async {
    await ref.read(presetListProvider.notifier).clone(preset);
    if (mounted) GlazeToast.show(context, 'Preset cloned');
  }

  Future<void> _changeCover(Preset preset) async {
    final path = await pickPresetCover(ref, preset.id);
    if (path == null || !mounted) return;
    await ref
        .read(presetListProvider.notifier)
        .updatePreset(preset.copyWith(imagePath: path));
    if (!mounted) return;
    final storage = await ref.read(imageStorageProvider.future);
    await deleteStoredPresetCover(storage, preset.imagePath);
  }

  Future<void> _removeCover(Preset preset) async {
    await ref
        .read(presetListProvider.notifier)
        .updatePreset(preset.copyWith(imagePath: null));
    if (!mounted) return;
    final storage = await ref.read(imageStorageProvider.future);
    await deleteStoredPresetCover(storage, preset.imagePath);
  }

  // ─── add / import ──────────────────────────────────────────────────────

  void _showAddSheet(BuildContext context) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'preset_add_title'.tr(),
      items: [
        BottomSheetItem(
          icon: Icons.add_circle_outline,
          label: 'preset_create_new'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _openEditor(null);
          },
        ),
        BottomSheetItem(
          icon: Icons.file_upload_outlined,
          label: 'action_import'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _importPreset();
          },
        ),
        BottomSheetItem(
          icon: Icons.create_new_folder_rounded,
          label: 'folder_new'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _createFolder(context);
          },
        ),
      ],
    );
  }

  void _createFolder(BuildContext context) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'folder_create_title'.tr(),
      child: FolderNameDialog(
        confirmLabel: 'btn_create'.tr(),
        onSubmit: (name) =>
            ref.read(presetFolderRepoProvider).create(name: name),
      ),
    );
  }

  Future<void> _importPreset() async {
    final ctx = context;
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: Platform.isIOS ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isIOS ? null : ['json'],
        allowMultiple: true,
        withData: true,
      );
    } catch (_) {}
    if (!mounted) return;
    if (result == null || result.files.isEmpty) return;

    final notifier = ref.read(presetListProvider.notifier);
    final imported = <String>[];
    Object? lastError;
    var unreadable = 0;
    var retired = 0;

    for (final picked in result.files) {
      try {
        String jsonString;
        if (picked.bytes != null && picked.bytes!.isNotEmpty) {
          jsonString = utf8.decode(picked.bytes!);
        } else if (picked.path != null && picked.path!.isNotEmpty) {
          jsonString = await File(picked.path!).readAsString();
        } else {
          unreadable++;
          continue;
        }

        final json = jsonDecode(jsonString) as Map<String, dynamic>;

        if (json.containsKey('agentEnabled')) {
          // An agentic (Studio) preset: Studio is gone, so there is nothing to
          // import it into.
          retired++;
        } else {
          final preset = parseSillyTavernPreset(json, picked.name);
          await notifier.add(preset);
          imported.add(preset.name);
        }
      } catch (e) {
        lastError = e;
      }
    }

    if (!ctx.mounted) return;

    if (imported.isEmpty) {
      if (lastError != null) {
        GlazeErrorDialog.show(
          ctx,
          lastError,
          prefix: 'error_import_failed_prefix'.tr(),
        );
      } else if (retired > 0) {
        GlazeToast.show(ctx, 'preset_import_agentic_retired'.tr());
      } else if (unreadable > 0) {
        GlazeToast.show(ctx, 'error_cannot_read_file'.tr());
      }
      return;
    }

    final name = imported.first;
    GlazeToast.show(
      ctx,
      imported.length == 1
          ? 'Imported "$name"'
          : 'Imported ${imported.length} presets',
    );
  }

  // ─── multi-select bulk actions ─────────────────────────────────────────

  /// Resolves the current selection back to items, skipping keys whose preset
  /// disappeared while the sheet was open.
  List<PresetItem> _selectedItems(PresetSelectionState selection) {
    final presets = ref.read(presetListProvider).value ?? const <Preset>[];
    return [
      for (final p in presets) PresetItem(preset: p),
    ].where((e) => selection.keys.contains(e.memberKey)).toList();
  }

  void _showSelectionActions(
    BuildContext context,
    PresetSelectionState selection,
  ) {
    final folderId = _currentFolderId;
    GlazeBottomSheet.show<void>(
      context,
      title: '${selection.count} ${'selected_count'.tr()}',
      items: [
        BottomSheetItem(
          icon: Icons.share_rounded,
          label: 'action_export'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            unawaited(_massExport(context, selection));
          },
        ),
        BottomSheetItem(
          icon: Icons.create_new_folder_outlined,
          label: 'action_add_to_folder'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _showAddToFolder([
              for (final e in _selectedItems(selection))
                PresetFolderTarget(e.id, e.kind),
            ], clearSelectionWhenDone: true);
          },
        ),
        if (folderId != null)
          BottomSheetItem(
            icon: Icons.folder_off_outlined,
            label: 'action_remove_from_folder'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              unawaited(_removeSelectedFromFolder(folderId, selection));
            },
          ),
        BottomSheetItem(
          icon: Icons.delete_rounded,
          label: 'action_delete'.tr(),
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _confirmDeleteSelected(context, selection);
          },
        ),
      ],
    );
  }

  void _showAddToFolder(
    List<PresetFolderTarget> targets, {
    bool clearSelectionWhenDone = false,
  }) {
    if (targets.isEmpty) return;
    showGlazeSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddPresetsToFolderSheet(
        targets: targets,
        onDone: clearSelectionWhenDone
            ? () => ref.read(presetSelectionProvider.notifier).clear()
            : null,
      ),
    );
  }

  Future<void> _massExport(
    BuildContext context,
    PresetSelectionState selection,
  ) async {
    var exported = 0;
    String? lastError;
    for (final item in _selectedItems(selection)) {
      try {
        final path = await savePresetJson(item.preset);
        // Empty path = the user cancelled the save dialog — stop the loop
        // instead of counting the file as exported (or re-prompting).
        if (path.isEmpty) break;
        exported++;
      } catch (e) {
        lastError = '$e';
      }
    }
    if (!context.mounted) return;
    ref.read(presetSelectionProvider.notifier).clear();
    if (exported > 0) {
      GlazeToast.show(context, 'preset_exported_toast'.plural(exported));
    } else if (lastError != null) {
      GlazeToast.show(context, lastError);
    }
  }

  Future<void> _removeSelectedFromFolder(
    String folderId,
    PresetSelectionState selection,
  ) async {
    final repo = ref.read(presetFolderRepoProvider);
    for (final item in _selectedItems(selection)) {
      await repo.removeMember(folderId, item.id, item.kind);
    }
    if (!mounted) return;
    ref.read(presetSelectionProvider.notifier).clear();
  }

  void _confirmDeleteSelected(
    BuildContext context,
    PresetSelectionState selection,
  ) {
    final deletable = _selectedItems(selection);
    if (deletable.isEmpty) {
      GlazeToast.show(context, 'preset_delete_none_toast'.tr());
      return;
    }

    GlazeBottomSheet.show<void>(
      context,
      title: 'action_delete'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'preset_delete_many_confirm'.plural(deletable.length),
      ),
      items: [
        BottomSheetItem(
          label: 'btn_delete'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            ref.read(presetSelectionProvider.notifier).clear();
            // Every selected row collapses together, then the deletes land.
            await _deleteItems(deletable);
          },
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }
}

/// Gives the list it builds a [ScrollController] of its own.
///
/// The folder cross-fade keeps the outgoing list mounted while the incoming one
/// builds, and one controller cannot be attached to two scroll views at the
/// same time. Each host creates its controller with its list and disposes it
/// with it; [onCreated] hands the screen the controller of the list that is
/// currently on top, so the auto-scroll always talks to the live one.
class _ScrollHost extends StatefulWidget {
  final ValueChanged<ScrollController> onCreated;
  final ValueChanged<ScrollController> onDisposed;
  final Widget Function(ScrollController controller) builder;

  const _ScrollHost({
    required this.onCreated,
    required this.onDisposed,
    required this.builder,
  });

  @override
  State<_ScrollHost> createState() => _ScrollHostState();
}

class _ScrollHostState extends State<_ScrollHost> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.onCreated(_controller);
  }

  @override
  void dispose() {
    widget.onDisposed(_controller);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_controller);
}

// ─── ps-card ─────────────────────────────────────────────────────────────────

class _PsCard extends ConsumerWidget {
  final PresetItem item;
  final bool isActive;

  /// While the list is multi-selecting, the row's action buttons give way to a
  /// check mark and a tap anywhere on the card toggles it.
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback onTap;

  /// Null while the list is drag-ordered — the drag listener owns the long
  /// press there.
  final VoidCallback? onLongPress;
  final VoidCallback onMenu;
  final VoidCallback? onConnections;
  final VoidCallback? onEdit;

  const _PsCard({
    required this.item,
    required this.isActive,
    required this.selectionMode,
    required this.isSelected,
    required this.onTap,
    required this.onMenu,
    this.onLongPress,
    this.onConnections,
    this.onEdit,
  });

  /// Height of a card that shows a cover image. Plain cards keep their
  /// intrinsic (single-row) height.
  static const double _coverHeight = 132;

  /// Border width of the active card, and of any card carrying artwork.
  static const double _accentBorderWidth = 2;

  /// How long the active highlight takes to cross-fade when the selection
  /// moves between presets.
  static const _activeFade = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cover = presetCoverImage(item.preset);

    final connections = ref.watch(presetConnectionsProvider);
    final hasCharBinding = connections.character.values.contains(
      item.preset.id,
    );
    final hasChatBinding = connections.chat.values.contains(item.preset.id);

    // A card filled with artwork needs a real frame even when idle — a hairline
    // disappears against the cover (same treatment as the Tools hero card).
    final idleBorder = cover != null
        ? context.cs.outlineVariant
        : context.cs.outline;
    final idleWidth = cover != null ? _accentBorderWidth : 1.0;
    final activeBorder = context.cs.primary.withValues(alpha: 0.5);
    // GlassSurface multiplies a tint's own alpha into the theme's element
    // opacity, and only falls back to `surface × elementOpacity` when no tint
    // is given. A theme whose UI colour is translucent (8-digit hex) therefore
    // renders a card handed `surfaceContainerHighest` verbatim thinner than
    // every other glass surface in the app. Pinning both tints to full alpha
    // makes the multiplication a no-op, so an idle card is exactly the app's
    // plain glass and the active one is that same glass plus the highlight.
    final baseTint = context.cs.surfaceContainerHighest.withValues(alpha: 1.0);
    final activeTint = Color.alphaBlend(
      context.cs.primary.withValues(alpha: 0.12),
      baseTint,
    );

    // While selecting, the highlight tracks the checkbox rather than which
    // preset is in effect.
    final highlighted = selectionMode ? isSelected : isActive;
    final flat = inSidebarPanel(context);
    // Flat, the text lines up with every other row of a sidebar panel.
    final rowPadding = flat
        ? const EdgeInsets.symmetric(horizontal: 16, vertical: 10)
        : const EdgeInsets.all(10);

    final Widget content;
    if (cover == null) {
      content = Padding(
        padding: rowPadding,
        child: _buildRow(
          context,
          hasChatBinding: hasChatBinding,
          hasCharBinding: hasCharBinding,
          onCover: false,
        ),
      );
    } else {
      content = _buildCover(
        context,
        cover,
        padding: rowPadding,
        hasChatBinding: hasChatBinding,
        hasCharBinding: hasCharBinding,
      );
    }

    // A row of a sidebar panel: no card, no rounding — the highlight is a
    // fill and a bar down its edge, and a rule separates it from the next.
    if (flat) {
      return TweenAnimationBuilder<double>(
        tween: Tween<double>(
          begin: highlighted ? 1.0 : 0.0,
          end: highlighted ? 1.0 : 0.0,
        ),
        duration: _activeFade,
        curve: Curves.easeOut,
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          onTap: onTap,
          onLongPress: onLongPress,
          child: content,
        ),
        builder: (context, t, child) => FlatGroupSurface(
          color: context.cs.primary.withValues(alpha: 0.12 * t),
          accent: context.cs.primary.withValues(alpha: t),
          child: child!,
        ),
      );
    }

    // `begin` only applies on the first build, so a card that is already active
    // when the list opens starts highlighted instead of animating in; later
    // changes to `end` fade the border (and its tint) between the two states.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(
        begin: highlighted ? 1.0 : 0.0,
        end: highlighted ? 1.0 : 0.0,
      ),
      duration: _activeFade,
      curve: Curves.easeOut,
      child: content,
      builder: (context, t, child) => GlassSurface(
        enableRipple: true,
        tint: Color.lerp(baseTint, activeTint, t),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Color.lerp(idleBorder, activeBorder, t)!,
          width: idleWidth + (_accentBorderWidth - idleWidth) * t,
        ),
        onTap: onTap,
        onLongPress: onLongPress,
        child: child!,
      ),
    );
  }

  /// Taller card: the cover fills it, a scrim keeps the text legible and the
  /// usual info row sits at the bottom.
  Widget _buildCover(
    BuildContext context,
    ImageProvider cover, {
    required EdgeInsets padding,
    required bool hasChatBinding,
    required bool hasCharBinding,
  }) {
    return SizedBox(
      height: _coverHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image(
            image: cover,
            fit: BoxFit.cover,
            // A missing/corrupt file falls back to the plain glass surface
            // rather than Flutter's error box.
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x33000000), Color(0xD9000000)],
              ),
            ),
          ),
          Padding(
            padding: padding,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildRow(
                  context,
                  hasChatBinding: hasChatBinding,
                  hasCharBinding: hasCharBinding,
                  onCover: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Shared info row. Over a cover the leading icon is dropped (the art already
  /// identifies the preset) and the text switches to light-on-dark.
  Widget _buildRow(
    BuildContext context, {
    required bool hasChatBinding,
    required bool hasCharBinding,
    required bool onCover,
  }) {
    final primaryText = onCover ? Colors.white : context.cs.onSurface;
    final secondaryText = onCover
        ? Colors.white.withValues(alpha: 0.75)
        : context.cs.onSurfaceVariant;
    final preset = item.preset;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (!onCover) ...[
          // Circular icon
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: context.cs.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.description_outlined,
              size: 20,
              color: context.cs.primary,
            ),
          ),
          const SizedBox(width: 12),
        ],
        // Info
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                preset.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: primaryText,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  PresetSmallBadge(
                    icon: Icons.description,
                    label: '${item.tokens}',
                    foreground: secondaryText,
                    onCover: onCover,
                  ),
                  if (preset.author != null && preset.author!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'by ${preset.author}',
                        style: TextStyle(fontSize: 12, color: secondaryText),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (selectionMode)
          _SelectionCheck(selected: isSelected, onCover: onCover)
        else ...[
          // Connection badge — tappable, colour shows binding type
          _ConnBadge(
            isActive: isActive,
            hasChatBinding: hasChatBinding,
            hasCharBinding: hasCharBinding,
            onTap: onConnections ?? () {},
          ),
          const SizedBox(width: 4),
          _RowIconButton(
            icon: Icons.edit_outlined,
            color: secondaryText,
            onTap: onEdit,
          ),
          _RowIconButton(
            icon: Icons.more_vert,
            color: secondaryText,
            onTap: onMenu,
          ),
        ],
      ],
    );
  }
}

// ─── shared small widgets ─────────────────────────────────────────────────────

class _RowIconButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const _RowIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 34,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }
}

/// Check mark that replaces a row's action buttons while multi-selecting.
class _SelectionCheck extends StatelessWidget {
  final bool selected;
  final bool onCover;

  const _SelectionCheck({required this.selected, required this.onCover});

  @override
  Widget build(BuildContext context) {
    final idle = onCover
        ? Colors.white.withValues(alpha: 0.7)
        : context.cs.onSurfaceVariant.withValues(alpha: 0.5);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Icon(
        selected
            ? Icons.check_circle_rounded
            : Icons.radio_button_unchecked_rounded,
        size: 22,
        color: selected ? context.cs.primary : idle,
      ),
    );
  }
}

/// Tappable link badge that shows the preset's binding scope visually.

class _ConnBadge extends StatelessWidget {
  final bool isActive;
  final bool hasChatBinding;
  final bool hasCharBinding;
  final VoidCallback onTap;

  const _ConnBadge({
    required this.isActive,
    required this.hasChatBinding,
    required this.hasCharBinding,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color color;
    if (hasChatBinding) {
      color = const Color(0xFFFF9500); // orange — chat binding
    } else if (hasCharBinding) {
      color = const Color(0xFFAF52DE); // purple — character binding
    } else if (isActive) {
      color = const Color(0xFF34C759); // green — global active
    } else {
      color = context.cs.onSurfaceVariant.withValues(alpha: 0.5); // grey
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: (hasChatBinding || hasCharBinding || isActive)
                ? color.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.link, size: 16, color: color),
        ),
      ),
    );
  }
}
