import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glass_surface.dart';
import 'memory_books_controls.dart';

/// Toolbar of maintenance actions shown above the tabs of the memory-books
/// sheet, laid out as Glaze action tiles instead of Material buttons.
class MemoryBooksToolbar extends StatelessWidget {
  final VoidCallback onOpenSettings;
  final VoidCallback onScanChat;
  final VoidCallback onAddEntry;
  final bool isReindexing;
  final VoidCallback onReindex;
  final VoidCallback onDeleteIndexes;

  /// False when the active API preset has vector search switched off — the
  /// reindex / drop-indexes row is hidden rather than shown as a dead end.
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
    const danger = Color(0xFFFF5252);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: MemoryActionTile(
                  icon: Icons.settings_outlined,
                  label: 'title_settings'.tr(),
                  onTap: onOpenSettings,
                ),
              ),
              const SizedBox(width: 8),
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
            ],
          ),
          if (showIndexActions) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: MemoryActionTile(
                    icon: Icons.storage_rounded,
                    label: isReindexing
                        ? 'btn_indexing'.tr()
                        : 'memory_books_btn_reindex'.tr(),
                    onTap: isReindexing ? null : onReindex,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: MemoryActionTile(
                    icon: Icons.delete_sweep_outlined,
                    label: 'action_delete_indexes'.tr(),
                    onTap: isReindexing ? null : onDeleteIndexes,
                    accent: danger,
                  ),
                ),
              ],
            ),
          ],
        ],
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
                    : '$pendingCount ${'memory_books_needs_generation'.tr()}',
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
