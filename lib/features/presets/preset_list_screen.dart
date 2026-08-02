import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/import/silly_tavern_preset_parser.dart';
import '../../core/models/preset.dart';
import '../../core/models/preset_folder.dart';
import '../../core/models/studio_config.dart';
import '../../core/services/featured_presets.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/active_studio_preset_provider.dart';
import '../../core/state/preset_folder_provider.dart';
import '../../core/utils/time_helpers.dart';
import '../studio/studio_preset_stats.dart';
import '../studio/studio_preset_workflow_provider.dart';
import '../studio/widgets/studio_preset_options_sheet.dart';
import 'studio_preset_editor_screen.dart';
import 'studio_preset_export.dart';
import '../../shared/shell/nav_height_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/folder_name_dialog.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
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
import 'widgets/add_presets_to_folder_sheet.dart';
import 'widgets/preset_filter_sheet.dart';
import 'widgets/preset_folders_section.dart';
import 'widgets/preset_options_sheet.dart';

/// Nominal height of one preset row (card + the gap below it). Only used to
/// estimate the scroll offset of the active preset before its row is laid out;
/// [Scrollable.ensureVisible] corrects the estimate on the following frame.
const double _kRowExtent = 72;

class PresetListScreen extends ConsumerStatefulWidget {
  final bool startExpanded;

  /// Active chat, forwarded to the preset editor so the Author's Note block can
  /// edit the session-scoped note. Null when opened outside a chat.
  final String? charId;
  const PresetListScreen({
    super.key,
    this.startExpanded = false,
    this.charId,
  });

  @override
  ConsumerState<PresetListScreen> createState() => _PresetListScreenState();
}

class _PresetListScreenState extends ConsumerState<PresetListScreen> {
  Preset? _editingPreset;
  bool _isCreating = false;
  String? _editingStudioId;
  GlobalKey<PresetEditorBodyState> _editorKey =
      GlobalKey<PresetEditorBodyState>();
  GlobalKey<StudioPresetEditorBodyState> _studioEditorKey =
      GlobalKey<StudioPresetEditorBodyState>();

  /// Folder currently being browsed, or null at the top level.
  String? _currentFolderId;
  PresetListFilters _filters = const PresetListFilters();

  final ScrollController _scrollController = ScrollController();

  /// Key on the header sliver, used to measure what sits above the rows when
  /// estimating the active preset's scroll offset.
  final GlobalKey _headerKey = GlobalKey();

  /// Key on the active preset's row, used to fine-tune that scroll.
  final GlobalKey _activeRowKey = GlobalKey();

  /// The list scrolls to the active preset once per screen open, not on every
  /// rebuild — otherwise the user could never scroll away from it.
  bool _didAutoScroll = false;

  bool get _inEditor => _isCreating || _editingPreset != null;
  bool get _inStudioEditor => _editingStudioId != null;
  bool get _inAnyEditor => _inEditor || _inStudioEditor;

  @override
  void initState() {
    super.initState();
    // The selection provider outlives this screen, so a selection left behind
    // when the sheet was dismissed would reopen with a stale bar. Reset after
    // the first frame (writing to a provider during initState is not allowed).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(presetSelectionProvider.notifier).clear();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _openEditor(Preset? preset) {
    setState(() {
      _editingPreset = preset;
      _isCreating = preset == null;
      // Recreate the editor key so PresetEditorBody's initState fires
      // and picks up the new preset's blocks instead of the old ones.
      _editorKey = GlobalKey<PresetEditorBodyState>();
    });
  }

  void _openStudioEditor(String presetId) {
    setState(() {
      _editingStudioId = presetId;
      // Fresh key so the editor's state re-initialises for the new preset.
      _studioEditorKey = GlobalKey<StudioPresetEditorBodyState>();
    });
  }

  void _closeEditor() {
    setState(() {
      _editingPreset = null;
      _isCreating = false;
      _editingStudioId = null;
    });
  }

  void _handleBack() {
    if (_inStudioEditor) {
      final handled = _studioEditorKey.currentState?.handleBack() ?? false;
      if (!handled) _closeEditor();
      return;
    }
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
      setState(() => _currentFolderId = null);
      return;
    }
    if (widget.startExpanded) {
      context.go('/tools');
    } else {
      Navigator.of(context).maybePop();
    }
  }

  String? _folderName(String id) {
    final folders = ref.watch(presetFoldersProvider).value;
    return folders?.where((f) => f.id == id).firstOrNull?.name;
  }

  @override
  Widget build(BuildContext context) {
    final presets = ref.watch(presetListProvider);
    final activeId = ref.watch(activePresetIdProvider);
    final studioPresets = ref.watch(studioPresetListProvider);
    final activeStudioId =
        ref.watch(activeStudioPresetProvider).value ?? 'default';
    // The Studio master switch is the single "which kind is in effect" flag:
    // ON → an agentic preset is active, OFF → a plain preset is active. Using
    // it as the discriminator keeps the two lists mutually exclusive so exactly
    // one card is ever highlighted.
    final studioEnabled = ref.watch(studioFeatureEnabledProvider);
    final selection = ref.watch(presetSelectionProvider);
    final folderId = _currentFolderId;

    final String title;
    if (_inStudioEditor) {
      title = 'Edit Agentic Preset';
    } else if (_inEditor) {
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
      actions: _inAnyEditor
          ? const []
          : [
              SheetViewAction(
                icon: Icon(
                  Icons.tune_rounded,
                  size: 20,
                  color: _filters.isActive
                      ? context.cs.primary
                      : context.cs.onSurfaceVariant,
                ),
                tooltip: 'catalog_filters'.tr(),
                onPressed: () => _showFilterSheet(context),
              ),
            ],
      floating: _inAnyEditor || !selection.active
          ? null
          : Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, _floatingBottom()),
                child: _SelectionBar(
                  count: selection.count,
                  onCancel: () =>
                      ref.read(presetSelectionProvider.notifier).clear(),
                  onMore: () => _showSelectionActions(context, selection),
                ),
              ),
            ),
      body: _inStudioEditor
          ? StudioPresetEditorBody(
              key: _studioEditorKey,
              presetId: _editingStudioId!,
              onClose: _closeEditor,
            )
          : _inEditor
          ? PresetEditorBody(
              key: _editorKey,
              preset: _editingPreset,
              charId: widget.charId,
              onDeleted: _closeEditor,
            )
          : presets.when(
              // A save from the editor invalidates the list; keep the rows on
              // screen instead of flashing a spinner while it reloads.
              skipLoadingOnReload: true,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('${'title_error'.tr()}: $e')),
              // The inner Builder reads the MediaQuery padding SheetView
              // overrides for its body (header inset + nav bar), which the
              // outer context doesn't carry.
              data: (list) => Builder(
                builder: (context) => _buildBody(
                  context,
                  list,
                  activeId,
                  studioPresets.value ?? const [],
                  activeStudioId,
                  studioEnabled,
                ),
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

  Widget _buildBody(
    BuildContext context,
    List<Preset> presets,
    String? activeId,
    List<StudioPreset> studioList,
    String activeStudioId,
    bool studioEnabled,
  ) {
    final folderId = _currentFolderId;
    final memberships =
        ref.watch(presetFolderMembershipsProvider).value ??
        PresetFolderMemberships.empty;
    final selection = ref.watch(presetSelectionProvider);

    var items = <PresetItem>[
      for (final p in presets) PresetItem(preset: p),
      for (final sp in studioList) PresetItem(studioPreset: sp),
    ];
    if (folderId != null) {
      final keys = memberships.presetsIn(folderId);
      items = items.where((e) => keys.contains(e.memberKey)).toList();
    }
    items = items.where(_filters.matches).toList();

    // Studio ON ⇒ only an agentic preset can be active; Studio OFF ⇒ only a
    // plain preset can be active. So the two kinds never both highlight.
    bool isActive(PresetItem item) => item.isAgentic
        ? (studioEnabled && item.studioPreset!.id == activeStudioId)
        : (!studioEnabled && activeId == item.preset!.id);

    final activeIndex = items.indexWhere(isActive);

    // Auto-reveal the active preset the first time the plain (unfiltered,
    // top-level) list is shown.
    if (folderId == null && !_filters.isActive) {
      _scheduleAutoScroll(activeIndex);
    }

    final topInset = MediaQuery.paddingOf(context).top;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(16, 12 + topInset, 16, 0),
          sliver: SliverToBoxAdapter(
            child: KeyedSubtree(
              key: _headerKey,
              child: folderId == null
                  ? PresetFoldersSection(
                      onOpenFolder: (id) {
                        ref.read(presetSelectionProvider.notifier).clear();
                        setState(() => _currentFolderId = id);
                      },
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
        if (items.isEmpty)
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
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.builder(
              itemCount: items.length,
              itemBuilder: (_, i) {
                final item = items[i];
                final active = isActive(item);
                return Padding(
                  key: i == activeIndex ? _activeRowKey : null,
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _PsCard(
                    item: item,
                    isActive: active,
                    selectionMode: selection.active,
                    isSelected: selection.contains(item.id, item.kind),
                    onTap: () => _onCardTap(item, active),
                    onLongPress: () => ref
                        .read(presetSelectionProvider.notifier)
                        .start(item.id, item.kind),
                    onConnections: item.isAgentic
                        ? null
                        : () => showPresetConnections(context, item.preset!.id),
                    onEdit: item.isAgentic
                        ? () => _openStudioEditor(item.studioPreset!.id)
                        : () => _openEditor(item.preset),
                    onMenu: () => _showItemMenu(item),
                  ),
                );
              },
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 16 + bottomInset),
          sliver: SliverToBoxAdapter(child: _buildAddButton(context)),
        ),
      ],
    );
  }

  void _onCardTap(PresetItem item, bool isActive) {
    if (ref.read(presetSelectionProvider).active) {
      ref.read(presetSelectionProvider.notifier).toggle(item.id, item.kind);
      return;
    }
    if (isActive) return;
    if (item.isAgentic) {
      ref.read(activeStudioPresetProvider.notifier).set(item.studioPreset!.id);
      ref.read(studioFeatureEnabledProvider.notifier).enable();
    } else {
      setActivePreset(ref, item.preset!.id);
      // Switching to a plain preset turns Studio off so the agentic pipeline
      // stops overriding it.
      ref.read(studioFeatureEnabledProvider.notifier).setEnabled(false);
    }
  }

  /// Jumps the list so the active preset is visible on open. Runs at most once.
  void _scheduleAutoScroll(int index) {
    if (_didAutoScroll || index < 0) return;
    _didAutoScroll = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealIndex(index));
  }

  void _revealIndex(int index) {
    if (!mounted || !_scrollController.hasClients) return;

    final headerBox =
        _headerKey.currentContext?.findRenderObject() as RenderBox?;
    final double headerExtent = headerBox?.size.height ?? 0.0;
    final viewport = _scrollController.position.viewportDimension;
    // Land the row a quarter of the way down the viewport rather than flush
    // against the top edge, so the presets around it stay in context. Cards
    // carrying a cover are taller than [_kRowExtent], so this is only a first
    // approximation.
    final double estimate =
        headerExtent + index * _kRowExtent - viewport * 0.25;
    _scrollController.jumpTo(
      estimate.clamp(0.0, _scrollController.position.maxScrollExtent),
    );

    // Correct the estimate now that the row itself is built (it is, after that
    // jump — the error stays inside the viewport's cache extent).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _activeRowKey.currentContext;
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
        onTap: () => _showAddSheet(context),
        borderRadius: BorderRadius.circular(14),
        splashColor: Colors.white.withValues(alpha: 0.1),
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Text(
                'Add / Import',
                style: TextStyle(
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

  void _showFilterSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PresetFilterSheet(
        filters: _filters,
        showTypeFilter:
            (ref.read(studioPresetListProvider).value ?? const []).isNotEmpty,
        onApply: (f) {
          if (mounted) setState(() => _filters = f);
        },
      ),
    );
  }

  // ─── per-row overflow menu ─────────────────────────────────────────────

  void _showItemMenu(PresetItem item) {
    if (item.isAgentic) {
      _showAgenticMenu(item.studioPreset!);
    } else {
      _showPlainMenu(item.preset!);
    }
  }

  void _showPlainMenu(Preset preset) {
    final notifier = ref.read(presetListProvider.notifier);
    showPresetOptions(
      context,
      isFeatured: isFeaturedPreset(preset.id),
      hasImage: preset.imagePath != null && preset.imagePath!.isNotEmpty,
      canDelete: true,
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
      onAddToFolder: () => _showAddToFolder([
        PresetFolderTarget(preset.id, PresetKind.normal),
      ]),
      onClone: () => unawaited(_clonePreset(preset)),
      onExport: () => unawaited(exportPreset(context, preset)),
      onDelete: () => unawaited(
        deletePresetAndFolderMemberships(ref, preset.id, PresetKind.normal),
      ),
    );
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

  void _showAgenticMenu(StudioPreset preset) {
    showStudioPresetOptions(
      context,
      preset: preset,
      onRename: () => showStudioPresetRename(
        context,
        preset: preset,
        onRename: (name) => unawaited(_renameAgentic(preset, name)),
      ),
      onClone: () => unawaited(_cloneAgentic(preset)),
      onAddToFolder: () => _showAddToFolder([
        PresetFolderTarget(preset.id, PresetKind.agentic),
      ]),
      onExport: () => unawaited(exportStudioPreset(context, preset)),
      onDelete: () => unawaited(_deleteAgentic(preset)),
    );
  }

  Future<void> _renameAgentic(StudioPreset preset, String name) async {
    await ref
        .read(studioPresetRepoProvider)
        .upsert(
          preset.copyWith(name: name, updatedAt: currentTimestampSeconds()),
        );
    if (mounted) ref.invalidate(studioPresetListProvider);
  }

  Future<void> _cloneAgentic(StudioPreset preset) async {
    final now = currentTimestampSeconds();
    await ref
        .read(studioPresetRepoProvider)
        .upsert(
          preset.copyWith(
            id: 'studio_$now',
            name: '${preset.name} (copy)',
            blocks: [...preset.blocks],
            agentEnabled: {...preset.agentEnabled},
            updatedAt: now,
          ),
        );
    if (!mounted) return;
    ref.invalidate(studioPresetListProvider);
    GlazeToast.show(context, 'studio_preset_cloned'.tr());
  }

  Future<void> _deleteAgentic(StudioPreset preset) async {
    final ok = await confirmStudioDelete(
      context,
      title: 'studio_delete_preset'.tr(),
      description: 'studio_confirm_delete_preset'.tr(args: [preset.name]),
    );
    if (!ok || !mounted) return;
    await deletePresetAndFolderMemberships(ref, preset.id, PresetKind.agentic);
  }

  // ─── add / import ──────────────────────────────────────────────────────

  void _showAddSheet(BuildContext context) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'Add Preset',
      items: [
        BottomSheetItem(
          icon: Icons.add_circle_outline,
          label: 'Create New Preset',
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _openEditor(null);
          },
        ),
        BottomSheetItem(
          icon: Icons.smart_toy_outlined,
          label: 'Add Agentic Preset',
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _createAgenticPreset();
          },
        ),
        BottomSheetItem(
          icon: Icons.file_upload_outlined,
          label: 'Import from File',
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

  Future<void> _createAgenticPreset() async {
    final ctx = context;
    try {
      final repo = ref.read(studioPresetRepoProvider);
      // Fresh installs never seed the built-in default preset (it only ships
      // via the DB upgrade migration), so back-fill it here — otherwise there
      // is nothing for createPreset to clone and the tap silently no-ops.
      await repo.ensureDefaultSeeded();
      final service = ref.read(studioPresetWorkflowServiceProvider);
      final presets = await repo.getAll();
      final result = await service.createPreset(
        name: 'New Agentic Preset',
        availablePresets: presets,
      );
      if (!ctx.mounted) return;
      if (result != null) {
        ref.invalidate(studioPresetListProvider);
        GlazeToast.show(ctx, 'Created "${result.preset.name}"');
      } else {
        GlazeToast.show(ctx, 'Failed to create agentic preset');
      }
    } catch (_) {
      if (ctx.mounted) {
        GlazeToast.show(ctx, 'Failed to create agentic preset');
      }
    }
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
    final studioWorkflow = ref.read(studioPresetWorkflowServiceProvider);
    final imported = <String>[];
    Object? lastError;
    var unreadable = 0;

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
          final studioPreset = StudioPreset.fromJson(json);
          await studioWorkflow.importPreset(
            imported: studioPreset,
            name: studioPreset.name,
          );
          imported.add(studioPreset.name);
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
        GlazeErrorDialog.show(ctx, lastError, prefix: 'Import failed: ');
      } else if (unreadable > 0) {
        GlazeToast.show(ctx, 'Cannot read file');
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
    final studio =
        ref.read(studioPresetListProvider).value ?? const <StudioPreset>[];
    return <PresetItem>[
      for (final p in presets) PresetItem(preset: p),
      for (final sp in studio) PresetItem(studioPreset: sp),
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
    showModalBottomSheet<void>(
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
        if (item.isAgentic) {
          await saveStudioPresetJson(item.studioPreset!);
        } else {
          await savePresetJson(item.preset!);
        }
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
    // The built-in `default` agentic preset is re-seeded on demand, so deleting
    // it would only look like it worked.
    final deletable = _selectedItems(selection)
        .where((e) => !(e.isAgentic && e.id == 'default'))
        .toList();
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
            for (final item in deletable) {
              // Each delete awaits a DB round-trip; bail out if the screen went
              // away in the meantime rather than reading a disposed ref.
              if (!mounted) return;
              await deletePresetAndFolderMemberships(ref, item.id, item.kind);
            }
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

// ─── ps-card ─────────────────────────────────────────────────────────────────

class _PsCard extends ConsumerWidget {
  final PresetItem item;
  final bool isActive;

  /// While the list is multi-selecting, the row's action buttons give way to a
  /// check mark and a tap anywhere on the card toggles it.
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onMenu;
  final VoidCallback? onConnections;
  final VoidCallback? onEdit;

  const _PsCard({
    required this.item,
    required this.isActive,
    required this.selectionMode,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
    required this.onMenu,
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
    // Agentic presets share the plain preset's frame, active cross-fade and row
    // layout — they only differ in the leading icon and the badges they carry,
    // and never have a cover, connections or an inline editor.
    final cover = item.isAgentic ? null : presetCoverImage(item.preset!);

    var hasCharBinding = false;
    var hasChatBinding = false;
    if (!item.isAgentic) {
      final connections = ref.watch(presetConnectionsProvider);
      hasCharBinding = connections.character.values.contains(item.preset!.id);
      hasChatBinding = connections.chat.values.contains(item.preset!.id);
    }

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

    final Widget content;
    if (item.isAgentic) {
      content = Padding(
        padding: const EdgeInsets.all(10),
        child: _buildAgenticRow(context),
      );
    } else if (cover == null) {
      content = Padding(
        padding: const EdgeInsets.all(10),
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
        hasChatBinding: hasChatBinding,
        hasCharBinding: hasCharBinding,
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
            padding: const EdgeInsets.all(10),
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
    final preset = item.preset!;

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
                  _SmallBadge(
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

  /// Agentic counterpart of [_buildRow]: same circular icon + name + badge-row
  /// layout as a plain preset, so both kinds render identically. Differs only
  /// in the leading glyph and the badges (token estimate + requests-per-turn),
  /// and has no connection badge.
  Widget _buildAgenticRow(BuildContext context) {
    final sp = item.studioPreset!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: context.cs.primary.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.smart_toy_outlined,
            size: 20,
            color: context.cs.primary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sp.name.isNotEmpty ? sp.name : 'Agentic Preset',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: context.cs.onSurface,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  _SmallBadge(
                    icon: Icons.memory,
                    label: '${item.tokens}',
                    foreground: context.cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  _SmallBadge(
                    icon: Icons.bolt,
                    label: 'studio_requests_per_turn'.tr(
                      args: ['${studioPresetRequestCount(sp)}'],
                    ),
                    foreground: context.cs.onSurfaceVariant,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (selectionMode)
          _SelectionCheck(selected: isSelected, onCover: false)
        else ...[
          // Agentic presets are global, so there is no per-chat/character
          // connection badge like a plain preset has.
          _RowIconButton(
            icon: Icons.edit_outlined,
            color: context.cs.onSurfaceVariant,
            onTap: onEdit,
          ),
          _RowIconButton(
            icon: Icons.more_vert,
            color: context.cs.onSurfaceVariant,
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

class _SmallBadge extends StatelessWidget {
  final IconData icon;
  final String label;

  /// Overrides the icon/label colour (set when the badge sits on a cover).
  final Color? foreground;

  /// Over a cover the near-transparent black pill disappears, so a light
  /// scrim is used instead.
  final bool onCover;
  const _SmallBadge({
    required this.icon,
    required this.label,
    this.foreground,
    this.onCover = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = foreground ?? context.cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: onCover
            ? Colors.black.withValues(alpha: 0.35)
            : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
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

    return GestureDetector(
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
    );
  }
}

/// Bottom selection bar shown while multi-selecting presets. Mirrors the chat's
/// message-selection bar: a glass pill with a cancel button, the selected
/// count, and a "more" button that opens the bulk-actions sheet.
class _SelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onCancel;
  final VoidCallback onMore;

  const _SelectionBar({
    required this.count,
    required this.onCancel,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      elevation: 0,
      borderRadius: BorderRadius.circular(28),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(28),
        tint: context.cs.surface,
        border: Border.all(color: context.cs.primary.withValues(alpha: 0.18)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              const SizedBox(width: 8),
              _CircleIconBtn(icon: Icons.close_rounded, onTap: onCancel),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '$count ${'selected_count'.tr()}',
                  style: TextStyle(
                    color: context.cs.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _CircleIconBtn(
                icon: Icons.more_horiz_rounded,
                onTap: count > 0 ? onMore : null,
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _CircleIconBtn({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 40,
        height: 40,
        child: GlassSurface(
          borderRadius: BorderRadius.circular(20),
          tint: context.cs.surface,
          border: Border.all(
            color: context.cs.primary.withValues(alpha: 0.18),
          ),
          child: Center(
            child: Icon(
              icon,
              size: 20,
              color: onTap != null
                  ? context.cs.primary
                  : context.cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }
}
