import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/models/preset.dart';
import '../../../core/models/preset_block_groups.dart';
import '../../../shared/theme/app_colors.dart';
import 'preset_block_row.dart';

/// One folder in the preset editor's block list — the agentic editor's folder
/// row applied to a chat preset.
///
/// The row folds its blocks away, toggles them as a unit through the header's
/// own enabled flag, and accepts a block dragged onto it. Expanded, it shows
/// the header prompt first (so the folder's own text stays editable), then the
/// blocks it owns.
class PresetBlockGroupRow extends StatefulWidget {
  final PresetBlockGroup group;

  /// Index inside the enclosing [ReorderableListView] — dragging the handle
  /// moves the whole folder.
  final int dragIndex;
  final bool isLast;

  /// Toggles the folder: its blocks stop being sent, keeping their own
  /// switches for when it is turned back on.
  final ValueChanged<bool> onToggleFolder;

  /// Drops the folder while keeping its blocks.
  final VoidCallback onDelete;

  /// Opens a block (the header prompt included) in the block editor.
  final ValueChanged<PresetBlock> onEdit;

  final void Function(PresetBlock block, bool enabled) onToggleBlock;

  /// Null hides the stash button on the folder's blocks.
  final ValueChanged<PresetBlock>? onStash;

  /// A block dragged onto the folder header, by id.
  final ValueChanged<String> onMoveBlockIn;

  const PresetBlockGroupRow({
    super.key,
    required this.group,
    required this.dragIndex,
    required this.isLast,
    required this.onToggleFolder,
    required this.onDelete,
    required this.onEdit,
    required this.onToggleBlock,
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
    final header = group.header!;
    final title = presetGroupTitle(header);
    final enabledCount = group.children.where((b) => b.enabled).length;

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          details.data != header.id &&
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
              opacity: header.enabled ? 1.0 : 0.5,
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Row(
                  children: [
                    ReorderableDragStartListener(
                      index: widget.dragIndex,
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
                    ),
                    Icon(
                      Icons.folder_outlined,
                      size: 16,
                      color: context.cs.primary.withValues(alpha: 0.8),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: context.cs.onSurface,
                              ),
                            ),
                            Text(
                              'studio_group_enabled'.tr(
                                args: [
                                  '$enabledCount',
                                  '${group.children.length}',
                                ],
                              ),
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
                    SizedBox(
                      width: 36,
                      height: 44,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: widget.onDelete,
                          borderRadius: BorderRadius.circular(20),
                          child: Icon(
                            Icons.delete_outline,
                            size: 20,
                            color: context.cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    Transform.scale(
                      scale: 0.8,
                      alignment: Alignment.centerRight,
                      child: Switch(
                        value: header.enabled,
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
            if (_expanded) ...[
              PresetBlockRow(
                key: ValueKey('preset_group_prompt_${header.id}'),
                block: header.copyWith(
                  name: 'studio_group_header_prompt'.tr(),
                ),
                index: widget.dragIndex,
                isLast: group.children.isEmpty,
                draggable: false,
                indent: 16,
                onEdit: () => widget.onEdit(header),
              ),
              for (var i = 0; i < group.children.length; i++)
                PresetBlockRow(
                  key: ValueKey(group.children[i].id),
                  block: group.children[i],
                  index: widget.dragIndex,
                  isLast: i == group.children.length - 1,
                  draggable: false,
                  indent: 16,
                  moveDragData: group.children[i].id,
                  onEdit: () => widget.onEdit(group.children[i]),
                  onToggle: (enabled) =>
                      widget.onToggleBlock(group.children[i], enabled),
                  onStash: widget.onStash == null || group.children[i].isStatic
                      ? null
                      : () => widget.onStash!(group.children[i]),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
