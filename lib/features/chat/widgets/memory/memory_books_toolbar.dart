import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../core/platform/haptics.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glass_surface.dart';
import '../../../../shared/widgets/glaze_bottom_sheet.dart';
import 'memory_books_controls.dart';

/// Everything the screen can *do*, behind one extended FAB.
///
/// Was a row of three tiles and a second row of two, all of one weight — so
/// "Delete indexes" sat next to "Settings" and read as an equally ordinary
/// thing to tap, and five buttons occupied the top of the screen before a
/// single memory. The imperative actions are a sheet now, and the declarative
/// ones went to the sheet header's settings button.
class MemoryBooksActionsFab extends StatelessWidget {
  final VoidCallback onScanChat;
  final VoidCallback onAddEntry;
  final bool isReindexing;
  final VoidCallback onReindex;
  final VoidCallback onDeleteIndexes;

  /// False when the active API preset has semantic search switched off — the
  /// reindex / drop-indexes entries are hidden rather than shown as dead ends.
  final bool showIndexActions;

  /// Bulk draft deletion, offered only while there is more than one draft to
  /// delete. It used to sit inline in the drafts section header, where a long
  /// localized label and the header's own title ellipsised each other.
  final VoidCallback? onDeleteAllDrafts;

  const MemoryBooksActionsFab({
    super.key,
    required this.onScanChat,
    required this.onAddEntry,
    required this.isReindexing,
    required this.onReindex,
    required this.onDeleteIndexes,
    required this.showIndexActions,
    this.onDeleteAllDrafts,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Haptics.selectionClick();
        _open(context);
      },
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: context.cs.primary,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(blurRadius: 16, color: Color(0x80000000)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.add_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(
              'memory_books_fab'.tr(),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    void close() => Navigator.of(context, rootNavigator: true).pop();
    GlazeBottomSheet.show<void>(
      context,
      title: 'memory_books_fab'.tr(),
      items: [
        BottomSheetItem(
          icon: Icons.search_rounded,
          label: 'memory_books_btn_scan_chat'.tr(),
          hint: 'memory_books_scan_chat_hint'.tr(),
          onTap: () {
            close();
            onScanChat();
          },
        ),
        BottomSheetItem(
          icon: Icons.edit_note_rounded,
          label: 'memory_books_add_manual'.tr(),
          onTap: () {
            close();
            onAddEntry();
          },
        ),
        if (onDeleteAllDrafts != null)
          BottomSheetItem(
            icon: Icons.delete_outline,
            label: 'memory_books_delete_all_pending'.tr(),
            isDestructive: true,
            onTap: () {
              close();
              onDeleteAllDrafts!();
            },
          ),
        if (showIndexActions) ...[
          BottomSheetItem(
            icon: Icons.storage_rounded,
            label: isReindexing
                ? 'btn_indexing'.tr()
                : 'memory_books_btn_reindex'.tr(),
            onTap: isReindexing
                ? () {}
                : () {
                    close();
                    onReindex();
                  },
          ),
          BottomSheetItem(
            icon: Icons.delete_sweep_outlined,
            label: 'action_delete_indexes'.tr(),
            isDestructive: true,
            onTap: isReindexing
                ? () {}
                : () {
                    close();
                    onDeleteIndexes();
                  },
          ),
        ],
      ],
    );
  }
}

/// Panel offering to fill every draft that still has no content, shown only
/// while drafts are pending generation or a batch is running.
class MemoryBatchPanel extends StatelessWidget {
  final int pendingCount;
  final bool isGenerating;
  final VoidCallback onGenerateBatch;

  const MemoryBatchPanel({
    super.key,
    required this.pendingCount,
    required this.isGenerating,
    required this.onGenerateBatch,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.cs.primary.withValues(alpha: 0.25)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isGenerating
                    ? 'memory_books_badge_generating'.tr()
                    : 'memory_books_needs_generation_n'.plural(pendingCount),
                style: TextStyle(
                  fontSize: 14,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              MemoryActionTile(
                icon: Icons.auto_awesome_rounded,
                label: isGenerating
                    ? 'memory_books_btn_generate_remaining'.tr()
                    : 'memory_books_btn_generate_batch'.tr(),
                onTap: pendingCount > 0 ? onGenerateBatch : null,
                emphasised: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
