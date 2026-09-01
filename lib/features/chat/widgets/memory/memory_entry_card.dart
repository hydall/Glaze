import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../core/models/memory_book.dart';
import '../../../../shared/theme/app_colors.dart';
import 'memory_books_controls.dart';

const Color _kGreen = Color(0xFF4CAF50);
const Color _kOrange = Color(0xFFFF9800);
const Color _kDanger = Color(0xFFFF5252);
const Color _kCyan = Color(0xFF26C6DA);
const Color _kMuted = Color(0xFF8A8A8A);

/// One approved memory in the "Approved" tab.
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
    return MemoryCard(
      accent: entry.status == 'needs_rebuild' ? _kOrange : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _isActive
                            ? context.cs.onSurface
                            : context.cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(),
                      style: TextStyle(
                        fontSize: 12,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildBadges(),
            ],
          ),
          if (entry.content.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              entry.content,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 6,
            runSpacing: 6,
            children: [
              MemoryActionChip(
                label: 'action_edit'.tr(),
                color: context.cs.primary,
                onTap: onEdit,
              ),
              MemoryActionChip(
                label: 'btn_delete'.tr(),
                color: _kDanger,
                onTap: onDelete,
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
    final messages =
        '${entry.messageIds.length} ${'memory_books_entry_messages'.tr()}';
    return keys.isEmpty ? '$status • $messages' : '$status • $messages • $keys';
  }

  Widget _buildBadges() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        switch (embeddingStatus) {
          'indexed' => const MemoryPill(
            label: 'idx',
            color: _kCyan,
            fontSize: 10,
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          ),
          'error' => const MemoryPill(
            label: '!',
            color: _kOrange,
            fontSize: 10,
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          ),
          'none' => const MemoryPill(
            label: '○',
            color: _kMuted,
            fontSize: 10,
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          ),
          _ => const SizedBox.shrink(),
        },
        const SizedBox(width: 4),
        MemoryPill(
          label: _isActive
              ? 'memory_books_badge_active'.tr()
              : 'memory_books_badge_rebuild'.tr(),
          color: _isActive ? _kGreen : _kOrange,
        ),
      ],
    );
  }
}
