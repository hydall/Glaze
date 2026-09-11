import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../core/platform/haptics.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glass_surface.dart';
import '../../../../shared/widgets/glaze_bottom_sheet.dart';
import 'memory_books_controls.dart';

/// The two actions used day to day, plus an overflow for maintenance.
///
/// Was a row of three tiles and a second row of two, all of one weight — so
/// "Delete indexes" sat next to "Settings" and read as an equally ordinary
/// thing to tap. Settings, reindex and drop-indexes now live behind the
/// overflow, where the destructive one can be marked as such.
class MemoryBooksToolbar extends StatelessWidget {
  final VoidCallback onOpenSettings;
  final VoidCallback onScanChat;
  final VoidCallback onAddEntry;
  final bool isReindexing;
  final VoidCallback onReindex;
  final VoidCallback onDeleteIndexes;

  /// False when the active API preset has vector search switched off — the
  /// reindex / drop-indexes entries are hidden rather than shown as dead ends.
  final bool showIndexActions;

  const MemoryBooksToolbar({
    super.key,
    required this.onOpenSettings,
    required this.onScanChat,
    required this.onAddEntry,
    required this.isReindexing,
    required this.onReindex,
    required this.onDeleteIndexes,
    required this.showIndexActions,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: MemoryActionTile(
              icon: Icons.search_rounded,
              label: 'memory_books_btn_scan_chat'.tr(),
              onTap: onScanChat,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: MemoryActionTile(
              icon: Icons.add_rounded,
              label: 'action_add'.tr(),
              onTap: onAddEntry,
              emphasised: true,
            ),
          ),
          const SizedBox(width: 8),
          _OverflowTile(
            onTap: () => _openOverflow(context),
          ),
        ],
      ),
    );
  }

  void _openOverflow(BuildContext context) {
    Haptics.selectionClick();
    void close() => Navigator.of(context, rootNavigator: true).pop();
    GlazeBottomSheet.show<void>(
      context,
      title: 'memory_books_more_actions'.tr(),
      items: [
        BottomSheetItem(
          icon: Icons.tune_rounded,
          label: 'memory_books_settings_title'.tr(),
          onTap: () {
            close();
            onOpenSettings();
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

/// Square companion to [MemoryActionTile] — same surface, icon only, so the
/// two real actions keep the width.
class _OverflowTile extends StatelessWidget {
  final VoidCallback onTap;

  const _OverflowTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    return GlassSurface(
      borderRadius: radius,
      border: Border.all(color: context.cs.outlineVariant),
      onTap: onTap,
      glowColor: context.cs.primary,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Icon(
          Icons.more_horiz_rounded,
          size: 18,
          color: context.cs.onSurfaceVariant,
        ),
      ),
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
