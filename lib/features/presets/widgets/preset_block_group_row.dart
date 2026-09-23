import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/models/preset.dart';
import '../../../core/models/preset_block_groups.dart';
import '../../../shared/theme/app_colors.dart';
import 'preset_block_row.dart';

/// One folder in the preset editor's block list — the agentic editor's folder
/// row applied to a chat preset.
///
/// The row folds its blocks away, toggles them as a unit through the folder's
/// own enabled flag, and accepts a block dragged onto it. The folder itself
/// carries no prompt text: it is metadata on the preset, not a block.
///
/// A checklist folder gives every block its own switch; a pick-one folder
/// (`exclusive`) gives them radio buttons and keeps exactly one enabled.
class PresetBlockGroupRow extends StatefulWidget {
  final PresetBlockGroup group;

  /// Index inside the enclosing [ReorderableListView] — dragging the handle
  /// moves the whole folder. Null for a folder that holds no blocks yet: it has
  /// no place in the block order to move to.
  final int? dragIndex;
  final bool isLast;

  /// Toggles the folder: its blocks stop being sent, keeping their own
  /// switches for when it is turned back on.
  final ValueChanged<bool> onToggleFolder;

  /// Opens the folder's options — rename, selection mode, delete.
  final VoidCallback onOptions;

  final ValueChanged<PresetBlock> onEdit;
  final void Function(PresetBlock block, bool enabled) onToggleBlock;

  /// Picks one block of a pick-one folder, by id.
  final ValueChanged<String> onSelectBlock;

  /// Null hides the stash button on the folder's blocks.
  final ValueChanged<PresetBlock>? onStash;

  /// A block dragged onto the folder, by id.
  final ValueChanged<String> onMoveBlockIn;

  const PresetBlockGroupRow({
    super.key,
    required this.group,
    required this.dragIndex,
    required this.isLast,
    required this.onToggleFolder,
    required this.onOptions,
    required this.onEdit,
    required this.onToggleBlock,
    required this.onSelectBlock,
    required this.onMoveBlockIn,
    this.onStash,
  });

  @override
  State<PresetBlockGroupRow> createState() => _PresetBlockGroupRowState();
}

class _PresetBlockGroupRowState extends State<PresetBlockGroupRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final folder = group.folder!;
    final dragIndex = widget.dragIndex;
    final enabledCount = group.children.where((b) => b.enabled).length;
    final selected = group.selected;
    final subtitle = folder.exclusive
        ? (selected == null ? 'studio_group_none'.tr() : selected.name)
        : 'studio_group_enabled'.tr(
            args: ['$enabledCount', '${group.children.length}'],
          );

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          !group.children.any((block) => block.id == details.data),
      onAcceptWithDetails: (details) => widget.onMoveBlockIn(details.data),
      builder: (context, candidates, _) => Container(
        decoration: BoxDecoration(
          color: candidates.isEmpty
              ? null
              : context.cs.primary.withValues(alpha: 0.08),
          border: Border(
            bottom: BorderSide(
              color: const Color(0x33808080),
              width: widget.isLast ? 0 : 1,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Opacity(
              opacity: folder.enabled ? 1.0 : 0.5,
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Row(
                  children: [
                    if (dragIndex != null)
                      ReorderableDragStartListener(
                        index: dragIndex,
                        child: SizedBox(
                          width: 30,
                          height: 44,
                          child: Center(
                            child: Text(
                              '≡',
                              style: TextStyle(
                                fontSize: 20,
                                color: context.cs.onSurfaceVariant.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      )
                    else
                      const SizedBox(width: 30, height: 44),
                    Icon(
                      folder.exclusive
                          ? Icons.radio_button_checked
                          : Icons.folder_outlined,
                      size: 16,
                      color: context.cs.primary.withValues(alpha: 0.8),
                    ),
                    const SizedBox(width: 8),
                    if (folder.exclusive) ...[
                      _pickOneBadge(context),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              folder.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: context.cs.onSurface,
                              ),
                            ),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: context.cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    _iconButton(
                      context,
                      icon: Icons.more_horiz,
                      onTap: widget.onOptions,
                    ),
                    Transform.scale(
                      scale: 0.8,
                      alignment: Alignment.centerRight,
                      child: Switch(
                        value: folder.enabled,
                        onChanged: widget.onToggleFolder,
                        activeThumbColor: context.cs.primary,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, right: 12),
                      child: AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(
                          Icons.expand_more,
                          size: 20,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded && group.children.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(62, 4, 16, 12),
                child: Text(
                  'preset_folder_empty_blocks'.tr(),
                  style: TextStyle(
                    fontSize: 12,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ),
            if (_expanded)
              for (var i = 0; i < group.children.length; i++)
                PresetBlockRow(
                  key: ValueKey(group.children[i].id),
                  block: group.children[i],
                  index: dragIndex ?? 0,
                  isLast: i == group.children.length - 1,
                  draggable: false,
                  indent: 16,
                  moveDragData: group.children[i].id,
                  onEdit: () => widget.onEdit(group.children[i]),
                  onToggle: folder.exclusive
                      ? null
                      : (enabled) =>
                            widget.onToggleBlock(group.children[i], enabled),
                  trailing: folder.exclusive
                      ? _radio(context, group.children[i])
                      : null,
                  onStash: widget.onStash == null || group.children[i].isStatic
                      ? null
                      : () => widget.onStash!(group.children[i]),
                ),
          ],
        ),
      ),
    );
  }

  /// Radio glyph for a pick-one folder's block. The picked one is inert —
  /// unpicking without picking something else would empty the folder.
  Widget _radio(BuildContext context, PresetBlock block) => IconButton(
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
    onPressed: block.enabled ? null : () => widget.onSelectBlock(block.id),
    icon: Icon(
      block.enabled ? Icons.radio_button_checked : Icons.radio_button_off,
      size: 20,
      color: block.enabled ? context.cs.primary : context.cs.onSurfaceVariant,
    ),
  );

  Widget _pickOneBadge(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: context.cs.primary.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      'studio_badge_pick_one'.tr(),
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        color: context.cs.primary,
        letterSpacing: 0.2,
      ),
    ),
  );

  Widget _iconButton(
    BuildContext context, {
    required IconData icon,
    required VoidCallback onTap,
  }) => SizedBox(
    width: 36,
    height: 44,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Icon(icon, size: 20, color: context.cs.onSurfaceVariant),
      ),
    ),
  );
}
