import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../core/models/memory_book.dart';
import '../../../../shared/theme/app_colors.dart';
import 'memory_books_controls.dart';

const Color _kAmber = Color(0xFFFFC107);
const Color _kGreen = Color(0xFF4CAF50);
const Color _kDanger = Color(0xFFFF5252);
const Color _kCyan = Color(0xFF26C6DA);

/// One pending draft in the "Scan drafts" tab.
class MemoryDraftCard extends StatelessWidget {
  final MemoryDraft draft;
  final bool isGenerating;

  /// When the current generation started, used to render the elapsed counter.
  final DateTime? generatingSince;

  final VoidCallback onGenerate;
  final VoidCallback onRegenerate;
  final VoidCallback onCancel;
  final VoidCallback onApprove;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const MemoryDraftCard({
    super.key,
    required this.draft,
    required this.isGenerating,
    required this.generatingSince,
    required this.onGenerate,
    required this.onRegenerate,
    required this.onCancel,
    required this.onApprove,
    required this.onEdit,
    required this.onDelete,
  });

  bool get _needsRegen => draft.status == 'needs_regeneration';

  bool get _needsGeneration =>
      draft.content.isEmpty &&
      (draft.status == 'pending_generation' || _needsRegen);

  @override
  Widget build(BuildContext context) {
    final hasContent = draft.content.isNotEmpty;
    final title = draft.title.isNotEmpty
        ? draft.title
        : 'memory_books_untitled_draft'.tr();
    final ledgerRange = draft.ledgerRange.trim();
    final displayTitle = ledgerRange.isEmpty ? title : '$title · $ledgerRange';
    return MemoryCard(
      accent: isGenerating
          ? _kAmber
          : _needsRegen
          ? _kDanger
          : null,
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
                        color: context.cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _statusLabel(),
                      style: TextStyle(
                        fontSize: 12,
                        color: _statusColor(context),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              MemoryPill(label: _badgeLabel(), color: _badgeColor()),
            ],
          ),
          if (hasContent) ...[
            const SizedBox(height: 8),
            Text(
              draft.content,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ],
          if (draft.error != null && _needsRegen) ...[
            const SizedBox(height: 4),
            Text(
              draft.error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: _kDanger),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 6,
            runSpacing: 6,
            children: [
              if (isGenerating)
                MemoryActionChip(
                  label: 'memory_books_btn_stop'.tr(),
                  color: _kAmber,
                  onTap: onCancel,
                )
              else if (_needsGeneration)
                MemoryActionChip(
                  label: 'memory_books_btn_generate'.tr(),
                  color: _kAmber,
                  onTap: onGenerate,
                )
              else if (hasContent)
                MemoryActionChip(
                  label: 'memory_books_btn_approve'.tr(),
                  color: _kGreen,
                  onTap: onApprove,
                ),
              if (hasContent && !isGenerating)
                MemoryActionChip(
                  label: 'memory_books_btn_regenerate'.tr(),
                  color: _kAmber,
                  onTap: onRegenerate,
                ),
              if (hasContent && !isGenerating)
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

  String _statusLabel() {
    if (isGenerating) {
      final start = generatingSince;
      if (start != null) {
        final elapsed =
            DateTime.now().difference(start).inMilliseconds / 1000.0;
        return '${'memory_books_generating_elapsed'.tr()} '
            '${elapsed.toStringAsFixed(1)}s';
      }
      return 'memory_books_generating_elapsed'.tr();
    }
    if (_needsRegen) return 'memory_books_badge_needs_regen'.tr();
    if (draft.content.isEmpty && draft.status == 'pending_generation') {
      return 'memory_books_needs_generation'.tr();
    }
    if (draft.content.isNotEmpty) return 'memory_books_pending_approval'.tr();
    return draft.status;
  }

  Color _statusColor(BuildContext context) {
    if (isGenerating) return _kAmber;
    if (_needsRegen) return _kDanger;
    if (draft.content.isEmpty) return _kAmber;
    return context.cs.onSurfaceVariant;
  }

  String _badgeLabel() {
    if (isGenerating) return 'memory_books_badge_generating'.tr();
    if (_needsRegen) return 'memory_books_badge_needs_regen'.tr();
    if (draft.content.isEmpty && draft.status == 'pending_generation') {
      return 'memory_books_badge_needs_gen'.tr();
    }
    return 'memory_books_badge_draft'.tr();
  }

  Color _badgeColor() {
    if (isGenerating) return _kAmber;
    if (_needsRegen) return _kDanger;
    if (draft.content.isEmpty && draft.status == 'pending_generation') {
      return _kAmber;
    }
    return _kCyan;
  }
}
