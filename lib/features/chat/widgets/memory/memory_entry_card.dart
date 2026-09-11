import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../core/models/memory_book.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_bottom_sheet.dart';
import 'memory_books_controls.dart';

const Color _kGreen = Color(0xFF4CAF50);
const Color _kOrange = Color(0xFFFF9800);
const Color _kDanger = Color(0xFFFF5252);
const Color _kCyan = Color(0xFF26C6DA);

/// One approved memory in the "Approved" tab.
///
/// A row, not a card: the status is a dot and a left edge rather than two
/// pills, and Edit/Delete moved from a permanent chip pair into the row's
/// overflow. Tapping the row is Edit, which is what the chip was for.
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
    return MemoryRow(
      accent: _isActive ? null : _kOrange,
      onTap: onEdit,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5, right: 10, left: 4),
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: _isActive ? _kGreen : _kOrange,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                    color: _isActive
                        ? context.cs.onSurface
                        : context.cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _subtitle(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          _buildBadges(),
          MemoryRowMenuButton(
            title: displayTitle,
            itemsBuilder: (sheetContext) => [
              BottomSheetItem(
                icon: Icons.edit_outlined,
                label: 'action_edit'.tr(),
                onTap: () {
                  Navigator.of(sheetContext, rootNavigator: true).pop();
                  onEdit();
                },
              ),
              BottomSheetItem(
                icon: Icons.delete_outline,
                label: 'btn_delete'.tr(),
                isDestructive: true,
                onTap: () {
                  Navigator.of(sheetContext, rootNavigator: true).pop();
                  onDelete();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _subtitle() {
    final status = _isActive
        ? 'memory_books_entry_active'.tr()
        : 'memory_books_entry_needs_rebuild'.tr();
    final keys = entry.keys.take(3).join(', ');
    final messages = 'memory_messages_n'.plural(entry.messageIds.length);
    return keys.isEmpty ? '$status • $messages' : '$status • $messages • $keys';
  }

  /// Only the index state is a badge now; the active/rebuild state is carried
  /// by the dot and the left edge, so the row never shows two pills at once.
  Widget _buildBadges() {
    return switch (embeddingStatus) {
      'indexed' => const MemoryPill(
        label: 'idx',
        color: _kCyan,
        fontSize: 10,
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      ),
      'error' => MemoryPill(
        label: 'memory_books_badge_index_error'.tr(),
        color: _kDanger,
        fontSize: 10,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}
