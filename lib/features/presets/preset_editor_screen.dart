import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/llm/tokenizer.dart';
import '../../core/models/preset.dart';
import '../../core/models/preset_folder.dart';
import '../../core/services/featured_presets.dart';
import '../../core/services/preset_defaults.dart';
import '../../core/state/db_provider.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/time_helpers.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../../shared/widgets/sheet_view.dart';
import '../../shared/widgets/generic_editor.dart';
import '../../shared/widgets/help_tip.dart';
import 'preset_cover_service.dart';
import 'preset_deletion.dart';
import 'preset_image.dart';
import 'preset_list_provider.dart';
import 'preset_export.dart';
import 'widgets/preset_block_row.dart';
import 'widgets/preset_dashboard_card.dart';
import 'widgets/preset_options_sheet.dart';
import '../../core/state/summary_providers.dart';
import '../chat/chat_provider.dart';
import '../settings/app_settings_provider.dart';
import '../chat/widgets/authors_note_sheet.dart';
import '../chat/widgets/memory_sheet.dart';
import '../regex/regex_sheet.dart';

/// The two buttons that act on the prompt block whose editor is open, handed
/// to whichever chrome is hosting [PresetEditorBody] so it can draw them in its
/// header. Stash used to sit in the block's row on the dashboard — one more
/// control in a row that already carries a drag handle, an edit pencil and a
/// switch — and Delete was a full-width red bar pinned under the editor. Both
/// act on the one block being edited, so both belong to that editor's header.
class PresetBlockEditorActions {
  /// Puts the block away (or takes it back out, when it was opened from the
  /// stash) and returns to the block list, the way [onDelete] does.
  final VoidCallback onStash;
  final VoidCallback onDelete;

  /// Whether the open block is currently stashed — decides which way the
  /// button points.
  final bool stashed;

  const PresetBlockEditorActions({
    required this.onStash,
    required this.onDelete,
    required this.stashed,
  });

  IconData get stashIcon =>
      stashed ? Icons.unarchive_outlined : Icons.archive_outlined;

  String get stashTooltip =>
      stashed ? 'action_unstash'.tr() : 'action_stash'.tr();
}

/// [PresetBlockEditorActions] as [GlazeScaffold] takes them.
List<Widget> presetBlockEditorHeaderActions(
  BuildContext context,
  PresetBlockEditorActions actions,
) {
  return [
    IconButton(
      icon: Icon(actions.stashIcon, size: 20),
      tooltip: actions.stashTooltip,
      color: context.cs.onSurfaceVariant,
      onPressed: actions.onStash,
    ),
    IconButton(
      icon: const Icon(Icons.delete_outline, size: 20),
      tooltip: 'action_delete'.tr(),
      color: context.cs.error,
      onPressed: actions.onDelete,
    ),
  ];
}

/// The same two buttons as [SheetView] takes them.
List<SheetViewAction> presetBlockEditorSheetActions(
  BuildContext context,
  PresetBlockEditorActions actions,
) {
  return [
    SheetViewAction(
      icon: Icon(actions.stashIcon, size: 20),
      tooltip: actions.stashTooltip,
      color: context.cs.onSurfaceVariant,
      onPressed: actions.onStash,
    ),
    SheetViewAction(
      icon: const Icon(Icons.delete_outline, size: 20),
      tooltip: 'action_delete'.tr(),
      color: context.cs.error,
      onPressed: actions.onDelete,
    ),
  ];
}

/// Standalone screen wrapper around [PresetEditorBody].
class PresetEditorScreen extends StatefulWidget {
  final Preset? preset;
  final String? charId;
  const PresetEditorScreen({super.key, this.preset, this.charId});

  @override
  State<PresetEditorScreen> createState() => _PresetEditorScreenState();
}

class _PresetEditorScreenState extends State<PresetEditorScreen> {
  final _editorKey = GlobalKey<PresetEditorBodyState>();

  /// Header buttons for the block editor, while one is open.
  PresetBlockEditorActions? _blockActions;

  void _onBack() {
    final handled = _editorKey.currentState?.handleBack() ?? false;
    if (!handled) {
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _onBack();
      },
      child: GlazeScaffold(
        title: widget.preset != null ? 'Edit Preset' : 'New Preset',
        onBack: _onBack,
        actions: _blockActions == null
            ? null
            : presetBlockEditorHeaderActions(context, _blockActions!),
        body: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: PresetEditorBody(
            key: _editorKey,
            preset: widget.preset,
            charId: widget.charId,
            onDeleted: () => Navigator.of(context).pop(),
            onBlockEditorChanged: (actions) =>
                setState(() => _blockActions = actions),
          ),
        ),
      ),
    );
  }
}

/// Embeddable preset editor body — no scaffold, no navigation chrome.
/// Expose [PresetEditorBodyState.save] via a [GlobalKey] to trigger save
/// from an outer widget (e.g. a [SheetView] header action).
class PresetEditorBody extends ConsumerStatefulWidget {
  final Preset? preset;

  /// Active chat used to edit the session-scoped Author's Note block. Null when
  /// the editor is opened outside a chat (the note editor then shows a hint).
  final String? charId;
  final VoidCallback? onDeleted;

  /// Fires with the header buttons for the block whose editor just opened, and
  /// with null when it closes. A host that draws its own chrome renders them;
  /// one that ignores this simply shows no block actions.
  final ValueChanged<PresetBlockEditorActions?>? onBlockEditorChanged;

  const PresetEditorBody({
    super.key,
    this.preset,
    this.charId,
    this.onDeleted,
    this.onBlockEditorChanged,
  });

  @override
  ConsumerState<PresetEditorBody> createState() => PresetEditorBodyState();
}

class PresetEditorBodyState extends ConsumerState<PresetEditorBody> {
  late final _nameCtrl = TextEditingController(text: widget.preset?.name ?? '');
  late String _author = widget.preset?.author ?? '';
  late String? _imagePath = widget.preset?.imagePath;
  late List<PresetBlock> _blocks;
  late List<PresetRegex> _regexes;
  late bool _parseInlineReasoning = widget.preset?.reasoningEnabled ?? false;
  // Read from the preset on every save before, which is the same thing as
  // being uneditable: the Guided Generation block is the one mandatory block
  // whose prompt lives on the preset rather than in `block.content`, and no
  // screen offered a field for it. Held here so the block's editor can change
  // it, the way the Vue editor always could.
  late String? _guidedGenerationPrompt = widget.preset?.guidedGenerationPrompt;
  late String? _guidedImpersonationPrompt =
      widget.preset?.guidedImpersonationPrompt;
  late final _reasoningStartCtrl = TextEditingController(
    text: widget.preset?.reasoningStart ?? '',
  );
  late final _reasoningEndCtrl = TextEditingController(
    text: widget.preset?.reasoningEnd ?? '',
  );
  late final _impersonationPromptCtrl = TextEditingController(
    text: widget.preset?.impersonationPrompt ?? '',
  );
  bool _showAdvanced = false;
  int? _expandedBlockIndex;

  double? _savedScrollOffset;
  late final ScrollController _scrollController = ScrollController();

  Timer? _saveTimer;
  late final String _currentId = widget.preset?.id ?? generateId();
  late final int _createdAt =
      widget.preset?.createdAt ?? currentTimestampSeconds();

  /// Bundled featured presets ship with a fixed author and cover image — both
  /// are read-only here. Cloning one produces a normal, fully editable preset.
  bool get _isFeatured => isFeaturedPreset(widget.preset?.id);

  @override
  void initState() {
    super.initState();
    _blocks = List.from(widget.preset?.blocks ?? defaultPresetBlocks());
    _regexes = List.from(widget.preset?.regexes ?? []);
    _reconcileAuthorsNoteEnabled();
    _reconcileSummaryEnabled();

    _nameCtrl.addListener(_scheduleSave);
    _reasoningStartCtrl.addListener(_scheduleSave);
    _reasoningEndCtrl.addListener(_scheduleSave);
    _impersonationPromptCtrl.addListener(_scheduleSave);
  }

  @override
  void deactivate() {
    // Flush a pending debounced save while the widget is still mounted (ref
    // valid). dispose() runs the same flush, but by then this ConsumerState is
    // unmounting and ref.read is unsafe, so a save deferred to dispose can
    // silently fail (the last <500 ms edit before back would be lost). Mirrors
    // ApiSettingsScreen / RegexSheet.
    if (_saveTimer != null && _saveTimer!.isActive) {
      _saveTimer!.cancel();
      _performSave();
    }
    super.deactivate();
  }

  @override
  void dispose() {
    if (_saveTimer != null && _saveTimer!.isActive) {
      _saveTimer!.cancel();
      _performSave();
    }
    _nameCtrl.dispose();
    _reasoningStartCtrl.dispose();
    _reasoningEndCtrl.dispose();
    _impersonationPromptCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _performSave);
  }

  Future<void> _performSave() async {
    final name = _nameCtrl.text.trim().isEmpty
        ? 'New Preset'
        : _nameCtrl.text.trim();
    final presetToSave = Preset(
      id: _currentId,
      name: name,
      author: _author.trim().isEmpty ? null : _author.trim(),
      imagePath: _imagePath,
      blocks: _blocks,
      regexes: _regexes,
      reasoningEnabled: _parseInlineReasoning,
      reasoningStart: _parseInlineReasoning ? _reasoningStartCtrl.text : null,
      reasoningEnd: _parseInlineReasoning ? _reasoningEndCtrl.text : null,
      guidedGenerationPrompt: _guidedGenerationPrompt,
      guidedImpersonationPrompt: _guidedImpersonationPrompt,
      impersonationPrompt: _impersonationPromptCtrl.text.trim().isEmpty
          ? null
          : _impersonationPromptCtrl.text,
      summaryPrompt: widget.preset?.summaryPrompt,
      createdAt: _createdAt,
    );
    await ref.read(presetListProvider.notifier).updatePreset(presetToSave);
  }

  bool handleBack() {
    if (_expandedBlockIndex != null) {
      _closeBlockEditor();
      return true;
    }
    return false;
  }

  void _openBlockEditor(int index) {
    _saveScrollOffset();
    setState(() => _expandedBlockIndex = index);
    _publishBlockEditorActions();
  }

  void _closeBlockEditor() {
    _saveScrollOffset();
    setState(() => _expandedBlockIndex = null);
    _publishBlockEditorActions();
    _restoreScrollAfterFrame();
  }

  /// Hand the host the header buttons for the block being edited, or null once
  /// the editor is closed. Author's Note and Summary are static blocks — they
  /// cannot be stashed or deleted — so their editors carry no actions.
  void _publishBlockEditorActions() {
    final notify = widget.onBlockEditorChanged;
    if (notify == null) return;
    final index = _expandedBlockIndex;
    if (index == null || _blocks[index].isStatic) {
      notify(null);
      return;
    }
    final block = _blocks[index];
    notify(
      PresetBlockEditorActions(
        stashed: block.isStashed,
        onStash: () {
          _closeBlockEditor();
          if (block.isStashed) {
            _unstashBlock(block.id);
          } else {
            _stashBlock(block.id);
          }
        },
        onDelete: _deleteExpandedBlock,
      ),
    );
  }

  void _deleteExpandedBlock() {
    final index = _expandedBlockIndex;
    if (index == null) return;
    _saveScrollOffset();
    setState(() {
      _blocks.removeAt(index);
      _expandedBlockIndex = null;
    });
    _publishBlockEditorActions();
    _restoreScrollAfterFrame();
    _scheduleSave();
  }

  void _saveScrollOffset() {
    if (_scrollController.hasClients) {
      _savedScrollOffset = _scrollController.offset;
    }
  }

  void _restoreScrollAfterFrame() {
    if (_savedScrollOffset == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _savedScrollOffset != null &&
          _scrollController.hasClients) {
        final target = _savedScrollOffset!.clamp(
          0.0,
          _scrollController.position.maxScrollExtent,
        );
        _scrollController.jumpTo(target);
        _savedScrollOffset = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_expandedBlockIndex != null) {
      final expanded = _blocks[_expandedBlockIndex!];
      // Author's Note edits per-preset role/depth/insertion here; its content
      // (session-scoped) is shown and edited via the linked chat note sheet.
      if (expanded.id == 'authors_note') {
        return _AuthorsNoteBlockEditor(
          key: ValueKey(expanded.id),
          block: expanded,
          charId: widget.charId,
          onSave: (updated) {
            setState(() => _blocks[_expandedBlockIndex!] = updated);
            _scheduleSave();
          },
        );
      }
      // Guided Generation: the block is always enabled and its text is two
      // preset-level prompts, so it gets the same treatment as the other
      // blocks whose content is not in `block.content`.
      if (expanded.id == 'guided_generation') {
        return _GuidedGenerationBlockEditor(
          key: ValueKey(expanded.id),
          block: expanded,
          generationPrompt:
              _guidedGenerationPrompt ?? kDefaultGuidedGenerationPrompt,
          impersonationPrompt:
              _guidedImpersonationPrompt ?? kDefaultGuidedImpersonationPrompt,
          onSave: (updated, generation, impersonation) {
            setState(() {
              _blocks[_expandedBlockIndex!] = updated;
              _guidedGenerationPrompt = generation;
              _guidedImpersonationPrompt = impersonation;
            });
            _scheduleSave();
          },
        );
      }
      // Summary: per-preset role/depth/insertion/prefix here; content (session-
      // scoped, in the summary repo) is shown and edited via the chat sheet.
      if (expanded.id == 'summary') {
        return _SummaryBlockEditor(
          key: ValueKey(expanded.id),
          block: expanded,
          charId: widget.charId,
          onSave: (updated) {
            setState(() => _blocks[_expandedBlockIndex!] = updated);
            _scheduleSave();
          },
        );
      }
      return _BlockEditorInline(
        key: ValueKey(expanded.id),
        block: expanded,
        onSave: (updated) {
          setState(() => _blocks[_expandedBlockIndex!] = updated);
          _scheduleSave();
        },
      );
    }

    return SingleChildScrollView(
      controller: _scrollController,
      key: const ValueKey('dashboard'),
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top,
        bottom:
            MediaQuery.paddingOf(context).bottom +
            MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDashboard(),
          _buildAdvancedToggle(),
          if (_showAdvanced) _buildAdvancedPanel(),
          const SizedBox(height: 60),
        ],
      ),
    );
  }

  // ─── Dashboard card ──────────────────────────────────────────────────────

  Widget _buildDashboard() {
    final displayName = _nameCtrl.text.trim().isEmpty
        ? 'New Preset'
        : _nameCtrl.text.trim();
    final addBlockAtTop =
        ref.watch(appSettingsProvider).value?.addBlockAtTop ?? false;
    final cover = resolvePresetCoverImage(
      presetId: _currentId,
      imagePath: _imagePath,
    );

    final activeBlocks = _blocks.where((b) => !b.isStashed).toList();
    final stashedCount = _blocks.length - activeBlocks.length;
    final tokens = activeBlocks
        .where((b) => b.enabled && b.content.isNotEmpty)
        .fold(0, (sum, b) => sum + estimateTokens(b.content));

    final onCover = cover != null;

    return PresetDashboardCard(
      coverImage: cover,
      onCoverTap: _isFeatured ? null : _pickImage,
      title: displayName,
      subtitle: _author.isNotEmpty ? 'by $_author' : null,
      onTitleTap: _showRenameDialog,
      onMenuTap: _showOptionsMenu,
      utilsLeading: [
        PresetUtilButton(
          icon: Icons.archive_outlined,
          count: stashedCount,
          onTap: _showStashSheet,
          onCover: onCover,
        ),
        PresetUtilButton(
          icon: Icons.code,
          count: _regexes.length,
          onTap: _showRegexSheet,
          onCover: onCover,
        ),
      ],
      utilsTrailing: [
        PresetStatBadge(
          icon: Icons.description,
          label: '${tokens}t',
          onCover: onCover,
        ),
      ],
      // Add block row position follows the app setting (top or bottom).
      addBlockAtTop: addBlockAtTop,
      blockList: activeBlocks.isNotEmpty ? _buildBlockList(activeBlocks) : null,
      onAddBlock: _addBlock,
    );
  }

  Widget _buildBlockList(List<PresetBlock> activeBlocks) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      buildDefaultDragHandles: false,
      itemCount: activeBlocks.length,
      // TODO: migrate to onReorderItem (newIndex semantics differ — see Flutter changelog).
      // ignore: deprecated_member_use
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex -= 1;
          final reordered = List<PresetBlock>.from(activeBlocks);
          final item = reordered.removeAt(oldIndex);
          reordered.insert(newIndex, item);
          var activeIndex = 0;
          for (var i = 0; i < _blocks.length; i++) {
            if (!_blocks[i].isStashed) {
              _blocks[i] = reordered[activeIndex++];
            }
          }
        });
        _scheduleSave();
      },
      itemBuilder: (_, i) {
        final block = activeBlocks[i];
        final sourceIndex = _blocks.indexWhere((b) => b.id == block.id);
        return PresetBlockRow(
          key: ValueKey(block.id),
          block: block,
          index: i,
          isLast: i == activeBlocks.length - 1,
          onEdit: () => _openBlockEditor(sourceIndex),
          onToggle: (v) {
            setState(() {
              _blocks[sourceIndex] = _blocks[sourceIndex].copyWith(enabled: v);
            });
            _scheduleSave();
            // Author's Note enable is one entity for the chat — mirror it onto
            // the session note and every other preset's block.
            if (block.id == 'authors_note') {
              syncAuthorsNoteEnabled(ref, charId: widget.charId, enabled: v);
            } else if (block.id == 'summary') {
              syncSummaryEnabled(ref, charId: widget.charId, enabled: v);
            }
          },
        );
      },
    );
  }

  // ─── Advanced settings ───────────────────────────────────────────────────

  Widget _buildAdvancedToggle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _showAdvanced = !_showAdvanced),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Text(
                'section_advanced_settings'.tr(),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              AnimatedRotation(
                turns: _showAdvanced ? 0.5 : 0,
                duration: const Duration(milliseconds: 300),
                child: Icon(
                  Icons.expand_more,
                  color: context.cs.onSurfaceVariant,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAdvancedPanel() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.cs.outline),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SectionLabel('Reasoning', helpTerm: 'preset-reasoning'),
              const SizedBox(height: 8),
              _SettingsToggle(
                label: 'label_parse_inline_reasoning'.tr(),
                description: 'desc_parse_inline_reasoning'.tr(),
                value: _parseInlineReasoning,
                helpTerm: 'preset-reasoning-inline',
                onChanged: (v) {
                  setState(() => _parseInlineReasoning = v);
                  _scheduleSave();
                },
              ),
              if (_parseInlineReasoning) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _reasoningStartCtrl,
                        style: TextStyle(color: context.cs.onSurface),
                        decoration: _inputDecoration('<think>'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _reasoningEndCtrl,
                        style: TextStyle(color: context.cs.onSurface),
                        decoration: _inputDecoration('</think>'),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              _SectionLabel('section_impersonation'.tr()),
              const SizedBox(height: 8),
              Text(
                'preset_impersonation_desc'.tr(),
                style: TextStyle(
                  color: context.cs.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _impersonationPromptCtrl,
                style: TextStyle(color: context.cs.onSurface),
                minLines: 2,
                maxLines: 5,
                decoration: _inputDecoration(
                  '[Write {{user}}\'s next message.]',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Author's Note (content session-scoped; role/depth per-preset) ────────

  /// On open, make the local authors_note block enable mirror the session note
  /// (the note's on/off is one entity for the chat). Persisted via [_scheduleSave].
  void _reconcileAuthorsNoteEnabled() {
    final charId = widget.charId;
    if (charId == null) return;
    final note = ref.read(chatProvider(charId)).value?.session?.authorsNote;
    if (note == null) return;
    final idx = _blocks.indexWhere((b) => b.id == 'authors_note');
    if (idx == -1 || _blocks[idx].enabled == note.enabled) return;
    _blocks[idx] = _blocks[idx].copyWith(enabled: note.enabled);
    _scheduleSave();
  }

  /// Summary enable is session-scoped and mirrored onto every preset's block.
  /// On open, sync the local block with the current chat summary flag.
  void _reconcileSummaryEnabled() {
    final charId = widget.charId;
    if (charId == null) return;
    final session = ref.read(chatProvider(charId)).value?.session;
    if (session == null) return;
    final idx = _blocks.indexWhere((b) => b.id == 'summary');
    if (idx == -1) return;
    ref.read(summaryEnabledProvider(session.id).future).then((enabled) {
      if (!mounted || _blocks[idx].enabled == enabled) return;
      setState(() {
        _blocks[idx] = _blocks[idx].copyWith(enabled: enabled);
      });
      _scheduleSave();
    });
  }

  // ─── Actions ─────────────────────────────────────────────────────────────

  void _stashBlock(String blockId) {
    final index = _blocks.indexWhere((b) => b.id == blockId);
    if (index == -1 || _blocks[index].isStatic) return;
    setState(() {
      _blocks[index] = _blocks[index].copyWith(isStashed: true);
    });
    _scheduleSave();
  }

  void _unstashBlock(String blockId) {
    final index = _blocks.indexWhere((b) => b.id == blockId);
    if (index == -1) return;
    final atTop = ref.read(appSettingsProvider).value?.addBlockAtTop ?? false;
    setState(() {
      final block = _blocks.removeAt(index).copyWith(isStashed: false);
      if (atTop) {
        _blocks.insert(0, block);
      } else {
        _blocks.add(block);
      }
    });
    _scheduleSave();
  }

  void _showStashSheet() {
    final stashed = _blocks.where((b) => b.isStashed).toList();
    GlazeBottomSheet.show<void>(
      context,
      title: 'stash'.tr(),
      items: stashed.isEmpty
          ? [
              BottomSheetItem(
                label: 'stash_empty'.tr(),
                centered: true,
                onTap: () => Navigator.of(context, rootNavigator: true).pop(),
              ),
            ]
          : [
              for (final block in stashed)
                BottomSheetItem(
                  icon: presetBlockRoleIcon(block.role),
                  label: block.name,
                  hint: block.enabled ? null : 'Disabled',
                  onTap: () {
                    Navigator.of(context, rootNavigator: true).pop();
                    final index = _blocks.indexWhere((b) => b.id == block.id);
                    if (index == -1) return;
                    _openBlockEditor(index);
                  },
                  actions: [
                    BottomSheetAction(
                      icon: Icons.unarchive_outlined,
                      onTap: () {
                        Navigator.of(context, rootNavigator: true).pop();
                        _unstashBlock(block.id);
                      },
                    ),
                    BottomSheetAction(
                      icon: Icons.delete_outline,
                      color: context.cs.error,
                      onTap: () {
                        Navigator.of(context, rootNavigator: true).pop();
                        setState(
                          () => _blocks.removeWhere((b) => b.id == block.id),
                        );
                        _scheduleSave();
                      },
                    ),
                  ],
                ),
            ],
    );
  }

  void _addBlock() {
    final hasMemoryBlock = _blocks.any((b) => b.id == 'memory');
    GlazeBottomSheet.show<void>(
      context,
      title: 'add_block'.tr(),
      items: [
        if (!hasMemoryBlock)
          BottomSheetItem(
            icon: Icons.psychology_alt_outlined,
            label: 'label_memory_book'.tr(),
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _addMemoryBlock();
            },
          ),
        BottomSheetItem(
          icon: Icons.add,
          label: 'label_custom_block'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _addCustomBlock();
          },
        ),
        BottomSheetItem(
          icon: Icons.content_copy_outlined,
          label: 'action_copy_from_preset'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _openCopyBlockPresetPicker();
          },
        ),
      ],
    );
  }

  /// Step 1 of "Copy from Preset": pick which preset to copy a block from.
  void _openCopyBlockPresetPicker() {
    final presets = ref.read(presetListProvider).value ?? const <Preset>[];
    if (presets.isEmpty) return;
    GlazeBottomSheet.show<void>(
      context,
      title: 'action_select_preset'.tr(),
      cardItems: [
        for (final preset in presets)
          BottomSheetCardItem(
            label: preset.name.isEmpty ? 'Default' : preset.name,
            sublabel: (preset.author?.isNotEmpty ?? false)
                ? 'by ${preset.author}'
                : null,
            icon: Icons.description_outlined,
            badge: '${_copyableBlocks(preset).length}',
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _openCopyBlockPicker(preset);
            },
          ),
      ],
    );
  }

  /// Step 2 of "Copy from Preset": pick which block from the chosen preset.
  void _openCopyBlockPicker(Preset preset) {
    final blocks = _copyableBlocks(preset);
    if (blocks.isEmpty) {
      GlazeBottomSheet.show<void>(
        context,
        title: preset.name,
        items: [
          BottomSheetItem(
            label: 'label_no_blocks'.tr(),
            centered: true,
            onTap: () => Navigator.of(context, rootNavigator: true).pop(),
          ),
        ],
      );
      return;
    }
    GlazeBottomSheet.show<void>(
      context,
      title: 'preset_blocks_title'.tr(args: [preset.name]),
      items: [
        for (final block in blocks)
          BottomSheetItem(
            icon: presetBlockRoleIcon(block.role),
            label: block.name,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              _copyBlockFromPreset(block);
            },
          ),
      ],
    );
  }

  /// Non-stashed blocks available to copy. For the preset currently being
  /// edited, use the live in-memory blocks so unsaved edits are reflected.
  List<PresetBlock> _copyableBlocks(Preset preset) {
    final source = preset.id == _currentId ? _blocks : preset.blocks;
    return source.where((block) => !block.isStashed).toList();
  }

  void _copyBlockFromPreset(PresetBlock block) {
    final atTop = ref.read(appSettingsProvider).value?.addBlockAtTop ?? false;
    // Deep-clone via copyWith with a fresh id; demote to a regular custom block
    // and append " (copy)" — matching Glaze's copy-from-preset behaviour.
    final clone = block.copyWith(
      id: generateId(),
      name: '${block.name} (copy)',
      isStatic: false,
      isStashed: false,
    );
    setState(() {
      if (atTop) {
        _blocks.insert(0, clone);
      } else {
        _blocks.add(clone);
      }
    });
    _scheduleSave();
  }

  void _addCustomBlock() {
    final atTop = ref.read(appSettingsProvider).value?.addBlockAtTop ?? false;
    setState(() {
      final block = PresetBlock(
        id: generateId(),
        name: 'Block ${_blocks.length + 1}',
        role: 'system',
        content: '',
      );
      if (atTop) {
        _blocks.insert(0, block);
      } else {
        _blocks.add(block);
      }
    });
    _scheduleSave();
  }

  void _addMemoryBlock() {
    if (_blocks.any((b) => b.id == 'memory')) return;
    setState(() {
      // Insert the Memory Book block just before Chat History so injected
      // memories sit with the other system context, not after the dialogue.
      final chatHistoryIdx = _blocks.indexWhere((b) => b.id == 'chat_history');
      const memoryBlock = PresetBlock(
        id: 'memory',
        name: 'Memory Book',
        role: 'system',
        content: '',
        enabled: true,
        isStatic: true,
      );
      if (chatHistoryIdx != -1) {
        _blocks.insert(chatHistoryIdx, memoryBlock);
      } else {
        _blocks.add(memoryBlock);
      }
    });
    _scheduleSave();
  }

  void _showRenameDialog() {
    showPresetRename(
      context,
      currentName: _nameCtrl.text,
      onRename: (val) {
        setState(() => _nameCtrl.text = val);
        _scheduleSave();
      },
    );
  }

  void _showAuthorDialog() {
    showPresetAuthorDialog(
      context,
      currentAuthor: _author,
      onSubmit: (val) {
        setState(() => _author = val);
        _scheduleSave();
      },
    );
  }

  /// Picks a cover image and stores it next to the character/persona avatars
  /// (so it gets a thumbnail). The preset keeps a *relative*, version-suffixed
  /// path — see `preset_image_paths.dart` for why both matter to cloud sync.
  Future<void> _pickImage() async {
    if (_isFeatured) return;

    final path = await pickPresetCover(ref, _currentId);
    if (path == null || !mounted) return;

    final previous = _imagePath;
    setState(() => _imagePath = path);
    _scheduleSave();

    final storage = await ref.read(imageStorageProvider.future);
    await deleteStoredPresetCover(storage, previous);
  }

  void _removeImage() {
    if (_isFeatured) return;
    final previous = _imagePath;
    setState(() => _imagePath = null);
    _scheduleSave();
    unawaited(
      ref
          .read(imageStorageProvider.future)
          .then((storage) => deleteStoredPresetCover(storage, previous)),
    );
  }

  /// Builds a [Preset] from the live editor state (used for Export and Clone).
  Preset _currentSnapshot() {
    final name = _nameCtrl.text.trim().isEmpty
        ? 'New Preset'
        : _nameCtrl.text.trim();
    return Preset(
      id: _currentId,
      name: name,
      author: _author.trim().isEmpty ? null : _author.trim(),
      imagePath: _imagePath,
      blocks: _blocks,
      regexes: _regexes,
      reasoningEnabled: _parseInlineReasoning,
      reasoningStart: _parseInlineReasoning ? _reasoningStartCtrl.text : null,
      reasoningEnd: _parseInlineReasoning ? _reasoningEndCtrl.text : null,
      guidedGenerationPrompt: _guidedGenerationPrompt,
      guidedImpersonationPrompt: _guidedImpersonationPrompt,
      impersonationPrompt: _impersonationPromptCtrl.text.trim().isEmpty
          ? null
          : _impersonationPromptCtrl.text,
      summaryPrompt: widget.preset?.summaryPrompt,
      createdAt: _createdAt,
    );
  }

  void _showOptionsMenu() {
    showPresetOptions(
      context,
      isFeatured: _isFeatured,
      hasImage: _imagePath != null && _imagePath!.isNotEmpty,
      canDelete: widget.preset != null,
      onRename: _showRenameDialog,
      onSetAuthor: _showAuthorDialog,
      onPickImage: () => unawaited(_pickImage()),
      onRemoveImage: _removeImage,
      // Clone/Export act on the live editor state (including unsaved edits),
      // not on the persisted preset.
      onClone: () => unawaited(_clonePreset()),
      onExport: () => unawaited(exportPreset(context, _currentSnapshot())),
      onDelete: () => unawaited(_deletePreset()),
    );
  }

  Future<void> _clonePreset() async {
    // `clone` assigns a fresh id and a "(copy)" suffixed name.
    await ref.read(presetListProvider.notifier).clone(_currentSnapshot());
    if (mounted) GlazeToast.show(context, 'Preset cloned');
  }

  Future<void> _deletePreset() async {
    final preset = widget.preset;
    if (preset == null) return;
    await deletePresetAndFolderMemberships(ref, preset.id, PresetKind.normal);
    widget.onDeleted?.call();
  }

  Future<void> _showRegexSheet() async {
    _saveTimer?.cancel();
    await _performSave();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      isScrollControlled: true,
      builder: (_) => RegexSheet(presetId: _currentId),
    );
    if (!mounted) return;
    final presets = ref.read(presetListProvider).value ?? [];
    final preset = presets.where((p) => p.id == _currentId).firstOrNull;
    if (preset != null) setState(() => _regexes = List.from(preset.regexes));
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
      ),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.04),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: context.cs.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: context.cs.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: context.cs.primary),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );
  }
}

// ─── _SectionLabel ───────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  final String? helpTerm;
  const _SectionLabel(this.text, {this.helpTerm});

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      style: TextStyle(
        fontSize: 13,
        color: context.cs.onSurfaceVariant,
        fontWeight: FontWeight.w500,
      ),
    );
    if (helpTerm == null) return label;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        label,
        HelpTip(term: helpTerm!),
      ],
    );
  }
}

// ─── _SettingsToggle ─────────────────────────────────────────────────────────

class _SettingsToggle extends StatelessWidget {
  final String label;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? helpTerm;

  const _SettingsToggle({
    required this.label,
    required this.description,
    required this.value,
    required this.onChanged,
    this.helpTerm,
  });

  @override
  Widget build(BuildContext context) {
    final labelWidget = Text(
      label,
      style: TextStyle(fontSize: 14, color: context.cs.onSurface),
    );
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (helpTerm != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    labelWidget,
                    HelpTip(term: helpTerm!),
                  ],
                )
              else
                labelWidget,
              const SizedBox(height: 2),
              Text(
                description,
                style: TextStyle(
                  fontSize: 12,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

// ─── _BlockEditorInline ─────────────────────────────────────────────────────────

/// Editor for one prompt block. Stash and Delete are not here: they are handed
/// to the host's header via [PresetBlockEditorActions].
class _BlockEditorInline extends StatelessWidget {
  final PresetBlock block;
  final ValueChanged<PresetBlock> onSave;

  const _BlockEditorInline({
    super.key,
    required this.block,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final config = [
      GenericEditorSection(
        title: null,
        fields: [
          GenericEditorField(
            key: 'name',
            label: 'placeholder_block_name'.tr(),
            type: 'text',
          ),
          GenericEditorField(
            key: 'role',
            label: 'label_role'.tr(),
            type: 'select',
            options: [
              {'label': 'System', 'value': 'system'},
              {'label': 'User', 'value': 'user'},
              {'label': 'Assistant', 'value': 'assistant'},
            ],
          ),
          GenericEditorField(
            key: 'insertionMode',
            label: 'label_insertion'.tr(),
            type: 'select',
            options: [
              {'label': 'Relative', 'value': 'relative'},
              {'label': 'Depth', 'value': 'depth'},
            ],
          ),
          GenericEditorField(
            key: 'depth',
            label: 'label_depth'.tr(),
            type: 'select',
            options: List.generate(
              20,
              (i) => {'label': '${i + 1}', 'value': i + 1},
            ),
            showIf: (item) => item['insertionMode'] == 'depth',
          ),
          GenericEditorField(
            key: 'appendToLastMessage',
            label: 'label_append_last_user'.tr(),
            type: 'select',
            options: [
              {'label': 'No', 'value': false},
              {'label': 'Yes', 'value': true},
            ],
          ),
          GenericEditorField(
            key: 'sendEmptyBlock',
            label: 'label_send_empty_block'.tr(),
            type: 'switch',
            showIf: (item) => item['appendToLastMessage'] != true,
          ),
          GenericEditorField(
            key: 'content',
            label: 'section_content'.tr(),
            type: 'textarea',
            rows: 5,
            expandable: true,
          ),
        ],
      ),
    ];

    return GenericEditor(
      item: block.toJson(),
      config: config,
      scrollable: true,
      onChanged: (values) {
        onSave(PresetBlock.fromJson(values));
      },
    );
  }
}

// ─── _AuthorsNoteBlockEditor ────────────────────────────────────────────────────

/// Inline editor for the `authors_note` block. Edits the per-preset settings
/// (role / insertion mode / depth) on the block itself, while the note's
/// content + enabled are session-scoped: shown here read-only and edited via the
/// linked chat note sheet. Outside a chat ([charId] == null) a hint is shown.
class _AuthorsNoteBlockEditor extends ConsumerWidget {
  final PresetBlock block;
  final String? charId;
  final ValueChanged<PresetBlock> onSave;

  const _AuthorsNoteBlockEditor({
    super.key,
    required this.block,
    required this.charId,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final note = charId == null
        ? null
        : ref.watch(chatProvider(charId!)).value?.session?.authorsNote;
    final content = note?.content ?? '';

    final config = [
      GenericEditorSection(
        title: null,
        fields: [
          GenericEditorField(
            key: 'role',
            label: 'label_role'.tr(),
            type: 'select',
            options: [
              {'label': 'System', 'value': 'system'},
              {'label': 'User', 'value': 'user'},
              {'label': 'Assistant', 'value': 'assistant'},
            ],
          ),
          GenericEditorField(
            key: 'insertionMode',
            label: 'label_insertion'.tr(),
            type: 'select',
            options: [
              {'label': 'Relative', 'value': 'relative'},
              {'label': 'Depth', 'value': 'depth'},
            ],
          ),
          GenericEditorField(
            key: 'depth',
            label: 'label_depth'.tr(),
            type: 'select',
            options: List.generate(
              20,
              (i) => {'label': '${i + 1}', 'value': i + 1},
            ),
            showIf: (item) => item['insertionMode'] == 'depth',
          ),
        ],
      ),
    ];

    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 16,
          bottom: MediaQuery.paddingOf(context).bottom + 60,
        ),
        children: [
          _linkedSessionContentCard(
            context,
            charId: charId,
            content: content,
            hint:
                "Author's note content is tied to a chat. Open a chat to edit it.",
            onEdit: () => showAuthorsNoteSheet(context, charId),
          ),
          GenericEditor(
            item: block.toJson(),
            config: config,
            scrollable: false,
            onChanged: (values) => onSave(PresetBlock.fromJson(values)),
          ),
        ],
      ),
    );
  }
}

// ─── _SummaryBlockEditor ────────────────────────────────────────────────────────

/// Inline editor for the `summary` block. Edits per-preset settings (role /
/// insertion mode / depth / prefix) on the block; the summary content is
/// session-scoped (stored in the summary repo), shown here and edited via the
/// linked chat summary sheet. Outside a chat ([charId] == null) a hint is shown.
class _SummaryBlockEditor extends ConsumerWidget {
  final PresetBlock block;
  final String? charId;
  final ValueChanged<PresetBlock> onSave;

  const _SummaryBlockEditor({
    super.key,
    required this.block,
    required this.charId,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId = charId == null
        ? null
        : ref.watch(chatProvider(charId!)).value?.session?.id;
    final content = sessionId == null
        ? ''
        : (ref.watch(summaryContentProvider(sessionId)).value ?? '');

    final config = [
      GenericEditorSection(
        title: null,
        fields: [
          GenericEditorField(
            key: 'role',
            label: 'label_role'.tr(),
            type: 'select',
            options: [
              {'label': 'System', 'value': 'system'},
              {'label': 'User', 'value': 'user'},
              {'label': 'Assistant', 'value': 'assistant'},
            ],
          ),
          GenericEditorField(
            key: 'insertionMode',
            label: 'label_insertion'.tr(),
            type: 'select',
            options: [
              {'label': 'Relative', 'value': 'relative'},
              {'label': 'Depth', 'value': 'depth'},
            ],
          ),
          GenericEditorField(
            key: 'depth',
            label: 'label_depth'.tr(),
            type: 'select',
            options: List.generate(
              20,
              (i) => {'label': '${i + 1}', 'value': i + 1},
            ),
            showIf: (item) => item['insertionMode'] == 'depth',
          ),
        ],
      ),
    ];

    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 16,
          bottom: MediaQuery.paddingOf(context).bottom + 60,
        ),
        children: [
          _linkedSessionContentCard(
            context,
            charId: charId,
            content: content,
            hint: 'hint_summary_needs_chat'.tr(),
            onEdit: () => showMemorySheet(context, charId!),
          ),
          GenericEditor(
            item: block.toJson(),
            config: config,
            scrollable: false,
            onChanged: (values) => onSave(PresetBlock.fromJson(values)),
          ),
        ],
      ),
    );
  }
}

/// Editor for the Guided Generation block.
///
/// A 1:1 port of the Vue editor's special case for this block: an explanatory
/// line, the generation prompt, the impersonation prompt, and then the same
/// role/insertion/depth the other blocks carry. Both prompts belong to the
/// preset rather than to the block, so they are handed back separately.
class _GuidedGenerationBlockEditor extends StatelessWidget {
  final PresetBlock block;
  final String generationPrompt;
  final String impersonationPrompt;
  final void Function(PresetBlock block, String generation, String impersonation)
  onSave;

  const _GuidedGenerationBlockEditor({
    super.key,
    required this.block,
    required this.generationPrompt,
    required this.impersonationPrompt,
    required this.onSave,
  });

  static const _generationKey = 'guidedGenerationPrompt';
  static const _impersonationKey = 'guidedImpersonationPrompt';

  @override
  Widget build(BuildContext context) {
    final config = [
      GenericEditorSection(
        title: 'block_guided_generation'.tr(),
        fields: [
          GenericEditorField(
            key: 'info',
            label: '',
            type: 'info',
            text: 'guided_generation_block_hint'.tr(),
          ),
          GenericEditorField(
            key: _generationKey,
            label: 'label_guided_generation_prompt'.tr(),
            type: 'textarea',
            rows: 2,
            expandable: true,
          ),
          GenericEditorField(
            key: _impersonationKey,
            label: 'label_guided_impersonation_prompt'.tr(),
            type: 'textarea',
            rows: 2,
            expandable: true,
          ),
          GenericEditorField(
            key: 'role',
            label: 'label_role'.tr(),
            type: 'select',
            options: [
              {'label': 'System', 'value': 'system'},
              {'label': 'User', 'value': 'user'},
              {'label': 'Assistant', 'value': 'assistant'},
            ],
          ),
          GenericEditorField(
            key: 'insertionMode',
            label: 'label_insertion'.tr(),
            type: 'select',
            options: [
              {'label': 'Relative', 'value': 'relative'},
              {'label': 'Depth', 'value': 'depth'},
            ],
          ),
          GenericEditorField(
            key: 'depth',
            label: 'label_depth'.tr(),
            type: 'select',
            options: List.generate(
              20,
              (i) => {'label': '${i + 1}', 'value': i + 1},
            ),
            showIf: (item) => item['insertionMode'] == 'depth',
          ),
        ],
      ),
    ];

    return Material(
      type: MaterialType.transparency,
      child: GenericEditor(
        item: {
          ...block.toJson(),
          _generationKey: generationPrompt,
          _impersonationKey: impersonationPrompt,
        },
        config: config,
        onChanged: (values) {
          // The two prompts are not block fields, so they are lifted back out
          // before the rest is read as a block — `PresetBlock.fromJson` would
          // drop them, and the preset would silently keep its old text.
          final generation = (values[_generationKey] ?? '').toString();
          final impersonation = (values[_impersonationKey] ?? '').toString();
          final blockJson = Map<String, dynamic>.from(values)
            ..remove(_generationKey)
            ..remove(_impersonationKey);
          onSave(
            PresetBlock.fromJson(blockJson),
            generation,
            impersonation,
          );
        },
      ),
    );
  }
}

// ─── shared content card ─────────────────────────────────────────────────────

/// Card showing the chat-scoped content of a linked block (Author's Note /
/// Summary) with an "Edit content" action, or a hint when no chat is active.
Widget _linkedSessionContentCard(
  BuildContext context, {
  required String? charId,
  required String content,
  required String hint,
  required VoidCallback onEdit,
}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: GlassSurface(
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.cs.outline),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'section_content'.tr(),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: context.cs.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  'preset_content_from_chat'.tr(),
                  style: TextStyle(
                    fontSize: 11,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (charId == null)
              Text(
                hint,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: context.cs.onSurfaceVariant,
                ),
              )
            else ...[
              Text(
                content.isEmpty ? 'Empty' : content,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: content.isEmpty
                      ? context.cs.onSurfaceVariant
                      : context.cs.onSurface.withValues(alpha: 0.9),
                ),
              ),
              const SizedBox(height: 12),
              Material(
                color: context.cs.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  onTap: onEdit,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.edit_outlined,
                          size: 18,
                          color: context.cs.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'preset_edit_content'.tr(),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: context.cs.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
