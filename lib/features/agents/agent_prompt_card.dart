import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../core/llm/tokenizer.dart';
import '../../core/models/agent_definition.dart';
import '../../core/models/preset.dart';
import '../../core/models/preset_block_groups.dart';
import '../../core/utils/id_generator.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/confirm_delete_sheet.dart';
import '../../shared/widgets/folder_name_dialog.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../presets/widgets/preset_block_group_row.dart';
import '../presets/widgets/preset_block_row.dart';
import '../presets/widgets/preset_dashboard_card.dart';
import 'agent_block_editor.dart';

/// The agent's prompt, edited the way a preset is: blocks dragged into order,
/// checklist and pick-one folders, a stash, and a block editor per block.
///
/// Holds no state of its own: every action builds the next agent from
/// [agent] and reports it through [onChanged].
class AgentPromptCard extends StatelessWidget {
  final AgentDefinition agent;
  final ValueChanged<AgentDefinition> onChanged;

  /// Mirrors the `addBlockAtTop` app setting.
  final bool addBlockAtTop;

  const AgentPromptCard({
    super.key,
    required this.agent,
    required this.onChanged,
    this.addBlockAtTop = false,
  });

  List<PresetBlock> get _active =>
      agent.blocks.where((b) => !b.isStashed).toList();

  @override
  Widget build(BuildContext context) {
    final active = _active;
    final stashed = agent.blocks.length - active.length;
    final tokens = agent.activeBlocks
        .where((b) => b.enabled && b.content.isNotEmpty)
        .fold(0, (sum, b) => sum + estimateTokens(b.content));
    return PresetDashboardCard(
      leading: Icon(Icons.smart_toy_outlined, color: context.cs.primary),
      title: 'agents_section_prompt'.tr(),
      subtitle: 'agents_prompt_hint'.tr(),
      onMenuTap: () => _addMenu(context),
      utilsLeading: [
        PresetUtilButton(
          icon: Icons.archive_outlined,
          count: stashed,
          onTap: () => _showStash(context),
        ),
      ],
      utilsTrailing: [
        PresetStatBadge(icon: Icons.description, label: '${tokens}t'),
      ],
      addBlockAtTop: addBlockAtTop,
      blockList: active.isEmpty ? null : _blockList(context, active),
      onAddBlock: () => _addMenu(context),
    );
  }

  // ─── Block list ──────────────────────────────────────────────────────────

  Widget _blockList(BuildContext context, List<PresetBlock> active) {
    final folders = agent.blockFolders;
    final rows = groupPresetBlocks(active, folders);
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          findPresetFolderForBlock(active, folders, details.data) != null,
      onAcceptWithDetails: (details) => _writeActive(
        movePresetBlockOutOfFolder(blocks: _active, blockId: details.data),
      ),
      builder: (context, _, _) => ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        buildDefaultDragHandles: false,
        itemCount: rows.length,
        // ignore: deprecated_member_use
        onReorder: (oldIndex, newIndex) {
          if (newIndex > oldIndex) newIndex -= 1;
          final reordered = [...rows];
          reordered.insert(newIndex, reordered.removeAt(oldIndex));
          _writeActive(flattenPresetBlockGroups(reordered));
        },
        itemBuilder: (context, i) => _row(context, rows, i),
      ),
    );
  }

  Widget _row(BuildContext context, List<PresetBlockGroup> rows, int index) {
    final row = rows[index];
    final isLast = index == rows.length - 1;
    if (row.isFolder) {
      final folder = row.folder!;
      return PresetBlockGroupRow(
        key: ValueKey('folder_${folder.id}'),
        group: row,
        dragIndex: row.children.isEmpty ? null : index,
        isLast: isLast,
        onToggleFolder: (enabled) => onChanged(
          agent.copyWith(
            blockFolders: togglePresetBlockFolder(
              agent.blockFolders,
              folder.id,
              enabled,
            ),
          ),
        ),
        onOptions: () => _folderOptions(context, folder),
        onEdit: (block) => _edit(context, block.id),
        onToggleBlock: _setEnabled,
        onSelectBlock: (blockId) => _writeActive(
          selectExclusivePresetBlock(
            blocks: _active,
            folderId: folder.id,
            blockId: blockId,
          ),
        ),
        onStash: (block) => _setStashed(block.id, true),
        onMoveBlockIn: (blockId) => _writeActive(
          movePresetBlockIntoFolder(
            blocks: _active,
            blockId: blockId,
            folder: folder,
          ),
        ),
      );
    }
    final block = row.standalone!;
    return PresetBlockRow(
      key: ValueKey(block.id),
      block: block,
      index: index,
      isLast: isLast,
      moveDragData: agent.blockFolders.isEmpty ? null : block.id,
      onEdit: () => _edit(context, block.id),
      onToggle: (enabled) => _setEnabled(block, enabled),
      onStash: () => _setStashed(block.id, true),
    );
  }

  // ─── Block actions ───────────────────────────────────────────────────────

  /// Writes a reordered active list back into the non-stashed slots, so
  /// stashed blocks keep the positions they were archived at.
  void _writeActive(List<PresetBlock> nextActive) {
    final blocks = [...agent.blocks];
    if (nextActive.length != blocks.where((b) => !b.isStashed).length) return;
    var next = 0;
    for (var i = 0; i < blocks.length; i++) {
      if (!blocks[i].isStashed) blocks[i] = nextActive[next++];
    }
    onChanged(agent.copyWith(blocks: blocks));
  }

  void _replace(String blockId, PresetBlock Function(PresetBlock) change) {
    onChanged(
      agent.copyWith(
        blocks: [for (final b in agent.blocks) b.id == blockId ? change(b) : b],
      ),
    );
  }

  void _setEnabled(PresetBlock block, bool enabled) =>
      _replace(block.id, (b) => b.copyWith(enabled: enabled));

  void _setStashed(String blockId, bool stashed) {
    if (stashed) {
      _replace(blockId, (b) => b.copyWith(isStashed: true));
      return;
    }
    // Unstashing brings the block back at the end (or top) of the list.
    final blocks = [...agent.blocks];
    final index = blocks.indexWhere((b) => b.id == blockId);
    if (index == -1) return;
    final block = blocks.removeAt(index).copyWith(isStashed: false);
    addBlockAtTop ? blocks.insert(0, block) : blocks.add(block);
    onChanged(agent.copyWith(blocks: blocks));
  }

  void _delete(String blockId) => onChanged(
    agent.copyWith(
      blocks: [
        for (final b in agent.blocks)
          if (b.id != blockId) b,
      ],
    ),
  );

  void _edit(BuildContext context, String blockId, {AgentDefinition? from}) {
    // The editor reports every keystroke; each one patches the agent the
    // previous one produced, not the one this card was built with.
    var current = from ?? agent;
    final block = current.blocks.where((b) => b.id == blockId).firstOrNull;
    if (block == null) return;
    void apply(AgentDefinition next) {
      current = next;
      onChanged(next);
    }

    unawaited(
      showAgentBlockEditor(
        context,
        block: block,
        stashed: block.isStashed,
        onChanged: (edited) => apply(
          current.copyWith(
            blocks: [
              for (final b in current.blocks) b.id == blockId ? edited : b,
            ],
          ),
        ),
        onStash: (stashed) => apply(
          current.copyWith(
            blocks: [
              for (final b in current.blocks)
                b.id == blockId ? b.copyWith(isStashed: stashed) : b,
            ],
          ),
        ),
        onDelete: () => apply(
          current.copyWith(
            blocks: [
              for (final b in current.blocks)
                if (b.id != blockId) b,
            ],
          ),
        ),
      ),
    );
  }

  void _addBlock(BuildContext context) {
    final block = PresetBlock(
      id: 'block_${generateId()}',
      name: 'agents_block_new'.tr(),
      role: 'system',
      content: '',
    );
    final next = agent.copyWith(
      blocks: addBlockAtTop
          ? [block, ...agent.blocks]
          : [...agent.blocks, block],
    );
    onChanged(next);
    _edit(context, block.id, from: next);
  }

  void _addMenu(BuildContext context) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'add_block'.tr(),
      items: [
        BottomSheetItem(
          icon: Icons.add,
          label: 'label_custom_block'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _addBlock(context);
          },
        ),
        BottomSheetItem(
          icon: Icons.create_new_folder_outlined,
          label: 'folder_new'.tr(),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _chooseFolderKind(context);
          },
        ),
      ],
    );
  }

  void _showStash(BuildContext context) {
    final stashed = agent.blocks.where((b) => b.isStashed).toList();
    void close() => Navigator.of(context, rootNavigator: true).pop();
    GlazeBottomSheet.show<void>(
      context,
      title: 'stash'.tr(),
      items: stashed.isEmpty
          ? [
              BottomSheetItem(
                label: 'stash_empty'.tr(),
                centered: true,
                onTap: close,
              ),
            ]
          : [
              for (final block in stashed)
                BottomSheetItem(
                  icon: presetBlockRoleIcon(block.role),
                  label: block.name,
                  onTap: () {
                    close();
                    _edit(context, block.id);
                  },
                  actions: [
                    BottomSheetAction(
                      icon: Icons.unarchive_outlined,
                      onTap: () {
                        close();
                        _setStashed(block.id, false);
                      },
                    ),
                    BottomSheetAction(
                      icon: Icons.delete_outline,
                      color: context.cs.error,
                      onTap: () {
                        close();
                        _delete(block.id);
                      },
                    ),
                  ],
                ),
            ],
    );
  }

  // ─── Folders ─────────────────────────────────────────────────────────────

  void _folderOptions(BuildContext context, PresetBlockFolder folder) {
    void close() => Navigator.of(context, rootNavigator: true).pop();
    GlazeBottomSheet.show<void>(
      context,
      title: folder.name,
      items: [
        BottomSheetItem(
          icon: Icons.edit_outlined,
          label: 'action_rename'.tr(),
          onTap: () {
            close();
            GlazeBottomSheet.show<void>(
              context,
              title: 'folder_rename_title'.tr(),
              child: FolderNameDialog(
                initialName: folder.name,
                confirmLabel: 'action_rename'.tr(),
                onSubmit: (name) => onChanged(
                  agent.copyWith(
                    blockFolders: renamePresetBlockFolder(
                      agent.blockFolders,
                      folder.id,
                      name,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        BottomSheetItem(
          icon: folder.exclusive ? Icons.checklist : Icons.radio_button_checked,
          label: folder.exclusive
              ? 'preset_folder_mode_checklist'.tr()
              : 'preset_folder_mode_pick_one'.tr(),
          hint: folder.exclusive
              ? null
              : 'preset_folder_mode_pick_one_hint'.tr(),
          onTap: () {
            close();
            final next = setPresetFolderExclusive(
              folders: agent.blockFolders,
              blocks: agent.blocks,
              folderId: folder.id,
              exclusive: !folder.exclusive,
            );
            onChanged(
              agent.copyWith(blocks: next.blocks, blockFolders: next.folders),
            );
          },
        ),
        BottomSheetItem(
          icon: Icons.delete_outline,
          label: 'action_delete'.tr(),
          isDestructive: true,
          onTap: () async {
            close();
            final confirmed = await confirmDeleteSheet(
              context,
              title: 'folder_delete_title'.tr(),
              description: 'preset_block_folder_delete_confirm'.tr(
                args: [folder.name],
              ),
            );
            if (!confirmed) return;
            onChanged(
              agent.copyWith(
                blocks: clearPresetFolderMembership(agent.blocks, folder.id),
                blockFolders: [
                  for (final f in agent.blockFolders)
                    if (f.id != folder.id) f,
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  void _chooseFolderKind(BuildContext context) {
    void create(bool exclusive) {
      Navigator.of(context, rootNavigator: true).pop();
      GlazeBottomSheet.show<void>(
        context,
        title: 'folder_create_title'.tr(),
        child: FolderNameDialog(
          confirmLabel: 'action_create'.tr(),
          onSubmit: (name) => onChanged(
            agent.copyWith(
              blockFolders: [
                ...agent.blockFolders,
                PresetBlockFolder(
                  id: generateId(),
                  name: name.trim(),
                  exclusive: exclusive,
                ),
              ],
            ),
          ),
        ),
      );
    }

    GlazeBottomSheet.show<void>(
      context,
      title: 'folder_create_title'.tr(),
      items: [
        BottomSheetItem(
          icon: Icons.checklist,
          label: 'preset_folder_mode_checklist'.tr(),
          hint: 'preset_folder_mode_checklist_hint'.tr(),
          onTap: () => create(false),
        ),
        BottomSheetItem(
          icon: Icons.radio_button_checked,
          label: 'preset_folder_mode_pick_one'.tr(),
          hint: 'preset_folder_mode_pick_one_hint'.tr(),
          onTap: () => create(true),
        ),
      ],
    );
  }
}
