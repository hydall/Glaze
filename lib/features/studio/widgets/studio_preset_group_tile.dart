import 'package:flutter/material.dart';

import '../../../core/models/studio_config.dart';
import '../../../core/models/studio_preset_block_groups.dart';

class StudioPresetGroupTile extends StatelessWidget {
  final StudioPresetBlockGroup group;
  final ValueChanged<String> onSelectExclusive;
  final void Function(StudioPresetBlock block, bool enabled) onToggle;
  final ValueChanged<StudioPresetBlock> onEdit;
  final ValueChanged<StudioPresetBlock>? onDelete;

  const StudioPresetGroupTile({
    super.key,
    required this.group,
    required this.onSelectExclusive,
    required this.onToggle,
    required this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final header = group.header!;
    final title = header.title.replaceFirst(
      RegExp(r'^━[^\p{L}\p{N}]*', unicode: true),
      '',
    );
    final selected = group.children.where((block) => block.enabled).firstOrNull;

    return ExpansionTile(
      key: ValueKey('group_${header.id}'),
      title: Text(title),
      subtitle: group.exclusive
          ? DropdownButton<String>(
              value: selected?.id,
              isExpanded: true,
              hint: const Text('None'),
              underline: const SizedBox.shrink(),
              items: group.children
                  .map(
                    (block) => DropdownMenuItem(
                      value: block.id,
                      child: Text(
                        block.title.isEmpty ? block.id : block.title,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (id) {
                if (id != null) onSelectExclusive(id);
              },
            )
          : Text(
              '${group.children.where((block) => block.enabled).length} enabled',
            ),
      children: [
        if (group.openingBoundary case final boundary?)
          _BoundaryTile(block: boundary, onEdit: onEdit),
        ...group.children.map(
          (block) => ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 32, right: 16),
            title: Text(block.title.isEmpty ? block.id : block.title),
            subtitle: Text('${block.kind} · ${block.role}'),
            trailing: group.exclusive
                ? Icon(
                    block.enabled
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  )
                : Switch(
                    value: block.enabled,
                    onChanged: block.locked
                        ? null
                        : (enabled) => onToggle(block, enabled),
                  ),
            onTap: () => onEdit(block),
            onLongPress: onDelete == null ? null : () => onDelete!(block),
          ),
        ),
        if (group.closingBoundary case final boundary?)
          _BoundaryTile(block: boundary, onEdit: onEdit),
      ],
    );
  }
}

class _BoundaryTile extends StatelessWidget {
  final StudioPresetBlock block;
  final ValueChanged<StudioPresetBlock> onEdit;

  const _BoundaryTile({required this.block, required this.onEdit});

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    contentPadding: const EdgeInsets.only(left: 32, right: 16),
    leading: const Icon(Icons.code, size: 18),
    title: Text(block.title),
    subtitle: Text(block.content, maxLines: 1, overflow: TextOverflow.ellipsis),
    onTap: () => onEdit(block),
  );
}
