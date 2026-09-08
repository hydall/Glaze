import 'package:flutter/material.dart';

import '../../../core/models/lorebook.dart';
import '../../../shared/theme/app_colors.dart';

class LorebookEntryBadge extends StatelessWidget {
  final String label;
  final Color color;

  const LorebookEntryBadge({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class LorebookEntryTile extends StatelessWidget {
  final LorebookEntry entry;
  final String? embeddingStatus;
  final String? embeddingError;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const LorebookEntryTile({
    super.key,
    required this.entry,
    this.embeddingStatus,
    this.embeddingError,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      color: Colors.white.withValues(alpha: 0.03),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: ListTile(
        dense: true,
        leading: Switch(
          value: entry.enabled,
          onChanged: (_) => onToggle(),
          activeThumbColor: context.cs.primary,
        ),
        title: Text(
          entry.comment.isNotEmpty
              ? entry.comment
              : (entry.keys.isNotEmpty ? entry.keys.join(', ') : 'Entry'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: entry.enabled
                ? context.cs.onSurface
                : context.cs.onSurfaceVariant,
          ),
        ),
        subtitle: Text(
          '${entry.keys.length} keys | order ${entry.order}${entry.constant ? ' | constant' : ''}',
          style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (entry.constant)
              const LorebookEntryBadge(label: 'const', color: Colors.purple),
            if (entry.vectorSearch) ...[
              const LorebookEntryBadge(label: 'vec', color: Colors.cyan),
              if (embeddingStatus == 'indexed')
                const LorebookEntryBadge(label: 'idx', color: Colors.green),
              if (embeddingStatus == 'error')
                Tooltip(
                  message: embeddingError ?? 'Error',
                  child: LorebookEntryBadge(
                    label: embeddingError ?? 'err',
                    color: Colors.orange,
                  ),
                ),
            ],
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: onEdit,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: onDelete,
            ),
          ],
        ),
        onTap: onEdit,
      ),
    );
  }
}
