import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/ledger_prompt_injection_mode.dart';
import '../../core/models/ledger_prompt_injection_policy.dart';
import '../../core/models/preset_folder.dart';
import '../../core/models/studio_config.dart';
import '../../core/models/studio_preset_block_groups.dart';
import '../../core/models/studio_preset_block_reorder.dart';
import '../../core/state/db_provider.dart';
import '../../core/utils/id_generator.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_spinner.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/folder_name_dialog.dart';
import '../settings/app_settings_provider.dart';
import '../studio/studio_agent_toggle.dart';
import '../studio/studio_injection_points.dart';
import '../studio/studio_preset_stats.dart';
import '../studio/widgets/studio_block_editor_inline.dart';
import '../studio/widgets/studio_block_section_list.dart';
import '../studio/widgets/studio_preset_options_sheet.dart';
import 'preset_deletion.dart';
import 'studio_preset_export.dart';
import 'widgets/preset_dashboard_card.dart';

/// Full editor for a single agentic (Studio) preset, rendered inline inside the
/// [PresetListScreen] SheetView.
///
/// Built from the plain [PresetEditorBody]'s parts, in two boxes: the identity
/// dashboard (name, overflow menu, stat badges) and the pipeline. Editing a
/// block replaces the body with the shared [GenericEditor], and back returns to
/// the dashboard.
///
/// The pipeline box holds the whole preset at once, split into one section per
/// injection point (§5) in pipeline order. A section reads as the stage itself:
/// its header, the agents that run there with their settings, then the blocks
/// addressed to them. Dragging a block under another section header re-targets
/// it to that stage.
class StudioPresetEditorBody extends ConsumerStatefulWidget {
  final String presetId;
  final VoidCallback onClose;

  const StudioPresetEditorBody({
    super.key,
    required this.presetId,
    required this.onClose,
  });

  @override
  ConsumerState<StudioPresetEditorBody> createState() =>
      StudioPresetEditorBodyState();
}

class StudioPresetEditorBodyState
    extends ConsumerState<StudioPresetEditorBody> {
  StudioPreset? _preset;
  bool _loading = true;
  String? _editingBlockId;
  Timer? _saveTimer;

  final ScrollController _scrollController = ScrollController();
  double? _savedScrollOffset;

  /// `(injectionPoint, label)` pairs in the order the sections are rendered:
  /// the pipeline order a turn actually runs in (§5). Blocks for a specific
  /// agent are fed in during pre-generation, so they sit right after it.
  /// Resolved per build so a locale switch relabels the sections.
  List<(String, String)> get _sections => [
    for (final point in studioInjectionPoints)
      (point, studioInjectionPointLabel(point)),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void deactivate() {
    _flushSave();
    super.deactivate();
  }

  @override
  void dispose() {
    _flushSave();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final preset = await ref
        .read(studioPresetRepoProvider)
        .getById(widget.presetId);
    if (!mounted) return;
    setState(() {
      _preset = preset;
      _loading = false;
    });
  }

  /// Closes the inline block editor if open; returns true when it handled back.
  bool handleBack() {
    if (_editingBlockId != null) {
      _flushSave();
      setState(() => _editingBlockId = null);
      _restoreScrollAfterFrame();
      return true;
    }
    return false;
  }

  // ── Persistence ────────────────────────────────────────────────────────────

  /// Persists [next] immediately (used for discrete edits: toggles, add/delete).
  Future<void> _persistNow(StudioPreset next) async {
    final stamped = next.copyWith(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    setState(() => _preset = stamped);
    await ref.read(studioPresetRepoProvider).upsert(stamped);
    ref.invalidate(studioPresetListProvider);
  }

  /// Updates in memory now and debounces the write (used while typing content).
  void _persistDebounced(StudioPreset next) {
    setState(
      () => _preset = next.copyWith(
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _flushSave);
  }

  void _flushSave() {
    if (_saveTimer?.isActive != true) return;
    _saveTimer!.cancel();
    final preset = _preset;
    if (preset == null) return;
    // ref is still valid in deactivate(); dispose() flush is a best-effort.
    unawaited(ref.read(studioPresetRepoProvider).upsert(preset));
    ref.invalidate(studioPresetListProvider);
  }

  // ── Scroll position across the inline editor ───────────────────────────────

  void _saveScrollOffset() {
    if (_scrollController.hasClients) {
      _savedScrollOffset = _scrollController.offset;
    }
  }

  void _restoreScrollAfterFrame() {
    if (_savedScrollOffset == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _savedScrollOffset == null ||
          !_scrollController.hasClients) {
        return;
      }
      _scrollController.jumpTo(
        _savedScrollOffset!.clamp(
          0.0,
          _scrollController.position.maxScrollExtent,
        ),
      );
      _savedScrollOffset = null;
    });
  }

  void _openBlock(StudioPresetBlock block) {
    // The grouper synthesizes a "Tense" header that has no stored block — it
    // has nothing to edit, so tapping it is a no-op rather than an editor that
    // opens onto nothing.
    final preset = _preset;
    if (preset == null || !preset.blocks.any((b) => b.id == block.id)) return;
    _saveScrollOffset();
    setState(() => _editingBlockId = block.id);
  }

  // ── Agent toggles ──────────────────────────────────────────────────────────

  Future<void> _toggleAgent(String specId, bool value) async {
    final preset = _preset;
    if (preset == null) return;
    await _persistNow(applyStudioAgentToggle(preset, specId, value));
  }

  Future<void> _setLedgerPromptInjection(LedgerPromptInjectionMode mode) async {
    final preset = _preset;
    if (preset == null) return;
    await _persistNow(
      preset.copyWith(
        runtime: preset.runtime.copyWith(
          requestedLedgerPromptInjectionMode: mode,
          requestedLedgerPromptInjectionAlgorithmVersion:
              mode == LedgerPromptInjectionMode.gapFiller
              ? ledgerPromptInjectionAlgorithmVersion
              : null,
          ledgerEngine: StudioLedgerEngine.currentReconciled,
        ),
      ),
    );
  }

  // ── Block ops ──────────────────────────────────────────────────────────────

  Future<void> _toggleBlock(StudioPresetBlock block, bool enabled) async {
    final preset = _preset;
    if (preset == null) return;
    await _persistNow(
      preset.copyWith(
        blocks: updateStudioPresetBlockRespectingGroups(
          preset.blocks,
          block.copyWith(enabled: enabled),
        ),
      ),
    );
  }

  Future<void> _selectExclusive(
    StudioPresetBlockGroup group,
    String selectedId,
  ) async {
    final preset = _preset;
    if (preset == null) return;
    await _persistNow(
      preset.copyWith(
        blocks: selectExclusiveStudioBlock(preset.blocks, group, selectedId),
      ),
    );
  }

  Future<void> _toggleGroup(StudioPresetBlockGroup group, bool enabled) async {
    final preset = _preset;
    if (preset == null) return;
    await _persistNow(
      preset.copyWith(
        blocks: toggleStudioPresetBlockGroup(preset.blocks, group, enabled),
      ),
    );
  }

  void _onBlockChanged(StudioPresetBlock updated) {
    final preset = _preset;
    if (preset == null) return;
    _persistDebounced(
      preset.copyWith(
        blocks: updateStudioPresetBlockRespectingGroups(preset.blocks, updated),
      ),
    );
  }

  /// Asks whether to create a block or folder before choosing its stage.
  void _addBlock() {
    final preset = _preset;
    if (preset == null) return;
    GlazeBottomSheet.show<void>(
      context,
      title: 'add_block'.tr(),
      items: [
        BottomSheetItem(
          icon: Icons.note_add_outlined,
          label: 'studio_add_prompt_block'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _chooseInjectionPoint(_createBlock);
          },
        ),
        BottomSheetItem(
          icon: Icons.create_new_folder_outlined,
          label: 'studio_add_folder'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _chooseInjectionPoint(_nameAndCreateFolder);
          },
        ),
      ],
    );
  }

  void _chooseInjectionPoint(ValueChanged<String> onSelected) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'studio_choose_stage'.tr(),
      items: [
        for (final section in _sections)
          BottomSheetItem(
            icon: Icons.add,
            label: section.$2,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              onSelected(section.$1);
            },
          ),
      ],
    );
  }

  Future<void> _createBlock(String injectionPoint) async {
    final preset = _preset;
    if (preset == null) return;
    final maxOrder = preset.blocks.fold<int>(
      -1,
      (m, b) => b.order > m ? b.order : m,
    );
    // New blocks carry no legacy `kind`/`section`, so the §5 migrator never
    // rewrites their explicit mode/injectionPoint.
    final draft = StudioPresetBlock(
      id: generateId(),
      title: 'New Block',
      section: '',
      role: 'system',
      mode: 'direct',
      injectionPoint: injectionPoint,
      order: maxOrder + 1,
    );
    await _persistNow(preset.copyWith(blocks: [...preset.blocks, draft]));
    if (mounted) _openBlock(draft);
  }

  void _nameAndCreateFolder(String injectionPoint) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'studio_add_folder'.tr(),
      child: FolderNameDialog(
        confirmLabel: 'studio_create'.tr(),
        onSubmit: (name) => unawaited(_createFolder(injectionPoint, name)),
      ),
    );
  }

  Future<void> _createFolder(String injectionPoint, String name) async {
    final preset = _preset;
    if (preset == null) return;
    final maxOrder = preset.blocks.fold<int>(
      -1,
      (maximum, block) => block.order > maximum ? block.order : maximum,
    );
    final id = generateId();
    final header = StudioPresetBlock(
      id: id,
      title: '━ $name',
      section: '',
      role: 'system',
      mode: 'direct',
      injectionPoint: injectionPoint,
      order: maxOrder + 1,
    );
    final close = StudioPresetBlock(
      id: '${id}_group_close',
      title: 'Closing tag',
      section: '',
      role: 'system',
      enabled: false,
      mode: 'direct',
      injectionPoint: injectionPoint,
      groupBoundary: 'close',
      order: maxOrder + 2,
    );
    await _persistNow(
      preset.copyWith(blocks: [...preset.blocks, header, close]),
    );
  }

  Future<void> _deleteBlock(StudioPresetBlock block) async {
    final preset = _preset;
    if (preset == null) return;
    final ok = await confirmStudioDelete(
      context,
      title: 'blocks_delete_block'.tr(),
      description: 'studio_confirm_delete_block'.tr(
        args: [block.title.isNotEmpty ? block.title : block.id],
      ),
    );
    if (!ok) return;
    await _persistNow(
      preset.copyWith(
        blocks: preset.blocks
            .where((b) => b.id != block.id)
            .toList(growable: false),
      ),
    );
    if (mounted && _editingBlockId == block.id) {
      setState(() => _editingBlockId = null);
    }
  }

  Future<void> _deleteGroup(StudioPresetBlockGroup group) async {
    final preset = _preset;
    final header = group.header;
    if (preset == null || header == null) return;
    final title = header.title
        .replaceFirst(RegExp(r'^━[^\p{L}\p{N}]*', unicode: true), '')
        .trim();
    final ok = await confirmStudioDelete(
      context,
      title: 'studio_delete_folder'.tr(),
      description: 'studio_confirm_delete_folder'.tr(
        args: [title.isEmpty ? header.id : title],
      ),
    );
    if (!ok) return;
    await _persistNow(
      preset.copyWith(
        blocks: dissolveStudioPresetBlockGroup(
          all: preset.blocks,
          group: group,
        ),
      ),
    );
  }

  void _moveBlockToGroup(String blockId, StudioPresetBlockGroup group) {
    final preset = _preset;
    if (preset == null) return;
    unawaited(
      _persistNow(
        preset.copyWith(
          blocks: moveStudioPresetBlockToGroup(
            all: preset.blocks,
            blockId: blockId,
            targetGroup: group,
          ),
        ),
      ),
    );
  }

  void _moveBlockToSection(String blockId, String injectionPoint) {
    final preset = _preset;
    if (preset == null) return;
    unawaited(
      _persistNow(
        preset.copyWith(
          blocks: moveStudioPresetBlockToSection(
            all: preset.blocks,
            blockId: blockId,
            injectionPoint: injectionPoint,
          ),
        ),
      ),
    );
  }

  // ── Reordering ─────────────────────────────────────────────────────────────

  /// Applies a drag. Dropping a row under a different section header re-targets
  /// its injection point — the section list resolves which stage each row
  /// landed in and reports the placements.
  void _onReorder(List<StudioPresetRowPlacement> placements) {
    final preset = _preset;
    if (preset == null) return;
    final blocks = reorderStudioPresetBlocks(
      all: preset.blocks,
      rows: placements,
    );
    if (identical(blocks, preset.blocks)) return;
    unawaited(_persistNow(preset.copyWith(blocks: blocks)));
  }

  // ── Preset-level actions ───────────────────────────────────────────────────

  void _showRenameDialog() {
    final preset = _preset;
    if (preset == null) return;
    showStudioPresetRename(
      context,
      preset: preset,
      onRename: (name) => unawaited(_persistNow(preset.copyWith(name: name))),
    );
  }

  Future<void> _clonePreset() async {
    final preset = _preset;
    if (preset == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Cloning stays passive on purpose (the plain preset editor behaves the
    // same): the copy is created but the active selection does not move.
    final clone = preset.copyWith(
      id: 'studio_$now',
      name: '${preset.name} (copy)',
      blocks: [...preset.blocks],
      agentEnabled: {...preset.agentEnabled},
      updatedAt: now,
    );
    await ref.read(studioPresetRepoProvider).upsert(clone);
    ref.invalidate(studioPresetListProvider);
    if (mounted) GlazeToast.show(context, 'studio_preset_cloned'.tr());
  }

  Future<void> _deletePreset() async {
    final preset = _preset;
    if (preset == null) return;
    final ok = await confirmStudioDelete(
      context,
      title: 'studio_delete_preset'.tr(),
      description: 'studio_confirm_delete_preset'.tr(args: [preset.name]),
    );
    if (!ok) return;
    _saveTimer?.cancel();
    await deletePresetAndFolderMemberships(ref, preset.id, PresetKind.agentic);
    if (!mounted) return;
    widget.onClose();
  }

  void _showOptionsMenu() {
    final preset = _preset;
    if (preset == null) return;
    showStudioPresetOptions(
      context,
      preset: preset,
      onRename: _showRenameDialog,
      onClone: () => unawaited(_clonePreset()),
      onExport: () => unawaited(exportStudioPreset(context, preset)),
      onDelete: () => unawaited(_deletePreset()),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: GlazeSpinner());
    }
    final preset = _preset;
    if (preset == null) {
      return Center(child: Text('studio_preset_not_found'.tr()));
    }

    final editing = _editingBlockId == null
        ? null
        : preset.blocks.where((b) => b.id == _editingBlockId).firstOrNull;
    if (editing != null) {
      final headerPrompt = isStudioPresetGroupHeader(editing);
      return StudioBlockEditorInline(
        key: ValueKey(editing.id),
        block: editing,
        onChanged: _onBlockChanged,
        onDelete: () => _deleteBlock(editing),
        headerPrompt: headerPrompt,
      );
    }

    return SingleChildScrollView(
      controller: _scrollController,
      key: const ValueKey('studio_dashboard'),
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top,
        bottom:
            MediaQuery.paddingOf(context).bottom +
            MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDashboard(preset),
          _buildBlocksCard(preset),
          const SizedBox(height: 60),
        ],
      ),
    );
  }

  /// Identity box: name, overflow menu and the preset-wide stats. The agents
  /// and the blocks each get a box of their own below it.
  Widget _buildDashboard(StudioPreset preset) {
    return PresetDashboardCard(
      leading: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: context.cs.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          Icons.smart_toy_outlined,
          size: 26,
          color: context.cs.primary,
        ),
      ),
      title: preset.name.isNotEmpty
          ? preset.name
          : 'studio_preset_fallback_name'.tr(),
      subtitle: 'studio_preset_subtitle'.tr(),
      onTitleTap: _showRenameDialog,
      onMenuTap: _showOptionsMenu,
      // All three stats read as the same pill.
      utilsTrailing: [
        PresetStatBadge(
          icon: Icons.smart_toy_outlined,
          label: '${studioPresetEnabledAgentCount(preset)}',
        ),
        const SizedBox(width: 8),
        PresetStatBadge(
          icon: Icons.bolt,
          label: 'studio_requests_per_turn'.tr(
            args: ['${studioPresetRequestCount(preset)}'],
          ),
        ),
        const SizedBox(width: 8),
        PresetStatBadge(
          icon: Icons.description,
          label: '${studioPresetTokenEstimate(preset)}t',
        ),
      ],
    );
  }

  /// Blocks box: every injection point rendered at once, plus the add row.
  Widget _buildBlocksCard(StudioPreset preset) {
    final addBlockAtTop =
        ref.watch(appSettingsProvider).value?.addBlockAtTop ?? false;
    final list = StudioBlockSectionList(
      preset: preset,
      sections: _sections,
      onReorder: _onReorder,
      onEdit: _openBlock,
      onToggle: _toggleBlock,
      onSelectExclusive: _selectExclusive,
      onToggleGroup: _toggleGroup,
      onDelete: _deleteBlock,
      onDeleteGroup: _deleteGroup,
      onMoveToGroup: _moveBlockToGroup,
      onMoveToSection: _moveBlockToSection,
      onToggleAgent: _toggleAgent,
      onLedgerPromptInjectionChanged: (mode) =>
          unawaited(_setLedgerPromptInjection(mode)),
    );
    return PresetCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Card title: the sections below are all one thing — the preset's
          // prompt blocks — and their own headers are stage names, not a name
          // for the whole list.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              'studio_blocks_title'.tr(),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: context.cs.onSurface,
              ),
            ),
          ),
          if (addBlockAtTop) ...[
            PresetAddBlockRow(onTap: _addBlock, atTop: true),
            list,
          ] else ...[
            list,
            PresetAddBlockRow(onTap: _addBlock),
          ],
        ],
      ),
    );
  }
}
