import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../core/models/memory_book.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_bottom_sheet.dart';
import 'memory_books_controls.dart';

const Color _kOrange = Color(0xFFFF9800);
const Color _kDanger = Color(0xFFFF5252);
const Color _kCyan = Color(0xFF26C6DA);

/// One approved memory in the "Approved" tab.
///
/// Laid out like a Prompt Inspector message card: a plaque whose hairline is
/// tinted by state, a title line, the counters, then a two-line preview of the
/// body. Tapping the plaque is Edit; Delete lives in the row's overflow rather
/// than as a permanent chip.
///
/// State is the outline, not a word. A pill spelling out "needs rebuild" on
/// every affected row repeated what the orange hairline already said, and on
/// the three-quarters of rows that are simply active it said nothing at all.
class MemoryEntryCard extends StatelessWidget {
  final MemoryEntry entry;

  /// `indexed` / `error` / `none`, or null while the statuses are still being
  /// read from the embedding repo.
  final String? embeddingStatus;

  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const MemoryEntryCard({
    super.key,
    required this.entry,
    required this.embeddingStatus,
    required this.onEdit,
    required this.onDelete,
  });

  bool get _isActive => entry.status == 'active';

  @override
  Widget build(BuildContext context) {
    final title = entry.title.isNotEmpty
        ? entry.title
        : 'memory_books_untitled_memory'.tr();
    final ledgerRange = entry.ledgerRange.trim();
    final displayTitle = ledgerRange.isEmpty ? title : '$title · $ledgerRange';
    // Active is the normal state: it gets the plaque's neutral hairline and no
    // badge, so the rows that do need attention are the ones that stand out.
    return MemoryRow(
      accent: _isActive ? null : _kOrange,
      onTap: onEdit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _isActive
                        ? context.cs.onSurface
                        : context.cs.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              ?_buildIndexIcon(),
              if (!_isActive) ...[
                const SizedBox(width: 6),
                MemoryStatusIcon(
                  icon: Icons.build_circle_outlined,
                  label: 'memory_books_entry_needs_rebuild'.tr(),
                  color: _kOrange,
                ),
              ],
              const SizedBox(width: 2),
              MemoryRowMenuButton(
                title: displayTitle,
                itemsBuilder: (menuContext) => [
                  BottomSheetItem(
                    icon: Icons.edit_outlined,
                    label: 'action_edit'.tr(),
                    onTap: () {
                      Navigator.of(menuContext, rootNavigator: true).pop();
                      onEdit();
                    },
                  ),
                  BottomSheetItem(
                    icon: Icons.delete_outline,
                    label: 'btn_delete'.tr(),
                    isDestructive: true,
                    onTap: () {
                      Navigator.of(menuContext, rootNavigator: true).pop();
                      onDelete();
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            _subtitle(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: context.cs.onSurfaceVariant.withValues(alpha: 0.75),
            ),
          ),
          if (entry.content.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              entry.content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _subtitle() {
    final keys = entry.keys.take(3).join(', ');
    final messages = 'memory_messages_n'.plural(entry.messageIds.length);
    return keys.isEmpty ? messages : '$messages • $keys';
  }

  /// The vector-index state. Was a `MemoryPill` reading `idx` — a token with no
  /// translation and nothing for a screen reader to say.
  Widget? _buildIndexIcon() => switch (embeddingStatus) {
    'indexed' => MemoryStatusIcon(
      icon: Icons.scatter_plot_rounded,
      label: 'memory_books_filter_indexed'.tr(),
      color: _kCyan,
    ),
    'error' => MemoryStatusIcon(
      icon: Icons.error_outline_rounded,
      label: 'memory_books_badge_index_error'.tr(),
      color: _kDanger,
    ),
    _ => null,
  };
}
