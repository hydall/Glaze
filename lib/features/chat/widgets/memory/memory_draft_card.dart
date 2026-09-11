import 'dart:async';

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
///
/// Stateful only for the elapsed counter: that ticker used to live on the tab
/// and call `setState` on the whole `ListView` five times a second, rebuilding
/// every row and every `GlassSurface` above them to move one number. It now
/// runs here, and only while this card is the one generating.
class MemoryDraftCard extends StatefulWidget {
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

  @override
  State<MemoryDraftCard> createState() => _MemoryDraftCardState();
}

class _MemoryDraftCardState extends State<MemoryDraftCard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant MemoryDraftCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Runs only while this draft is generating *and* has a start time to count
  /// from — without one there is no number to move, so there is nothing to tick.
  void _syncTicker() {
    final wanted = widget.isGenerating && widget.generatingSince != null;
    if (wanted && _ticker == null) {
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted) setState(() {});
      });
    } else if (!wanted) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  MemoryDraft get _draft => widget.draft;

  bool get _needsRegen => _draft.status == 'needs_regeneration';

  bool get _needsGeneration =>
      _draft.content.isEmpty &&
      (_draft.status == 'pending_generation' || _needsRegen);

  @override
  Widget build(BuildContext context) {
    final hasContent = _draft.content.isNotEmpty;
    final title = _draft.title.isNotEmpty
        ? _draft.title
        : 'memory_books_untitled_draft'.tr();
    final ledgerRange = _draft.ledgerRange.trim();
    final displayTitle = ledgerRange.isEmpty ? title : '$title · $ledgerRange';
    return MemoryRow(
      accent: widget.isGenerating
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
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                        color: context.cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _statusLabel(),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: _statusColor(context),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              MemoryPill(
                label: _badgeLabel(),
                icon: _badgeIcon(),
                color: _badgeColor(),
                fontSize: 10,
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 3,
                ),
              ),
            ],
          ),
          if (hasContent) ...[
            const SizedBox(height: 6),
            Text(
              _draft.content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ],
          if (_draft.error != null && _needsRegen) ...[
            const SizedBox(height: 4),
            Text(
              _draft.error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: _kDanger),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (widget.isGenerating)
                MemoryCircleButton(
                  icon: Icons.stop_rounded,
                  label: 'memory_books_btn_stop'.tr(),
                  color: _kAmber,
                  onTap: widget.onCancel,
                )
              else if (_needsGeneration)
                MemoryCircleButton(
                  icon: Icons.auto_awesome_rounded,
                  label: 'memory_books_btn_generate'.tr(),
                  color: _kAmber,
                  onTap: widget.onGenerate,
                )
              else if (hasContent)
                MemoryCircleButton(
                  icon: Icons.check_rounded,
                  label: 'memory_books_btn_approve'.tr(),
                  color: _kGreen,
                  onTap: widget.onApprove,
                ),
              if (hasContent && !widget.isGenerating) ...[
                const SizedBox(width: 4),
                MemoryCircleButton(
                  icon: Icons.refresh_rounded,
                  label: 'memory_books_btn_regenerate'.tr(),
                  color: _kAmber,
                  onTap: widget.onRegenerate,
                ),
                const SizedBox(width: 4),
                MemoryCircleButton(
                  icon: Icons.edit_outlined,
                  label: 'action_edit'.tr(),
                  color: context.cs.primary,
                  onTap: widget.onEdit,
                ),
              ],
              const SizedBox(width: 4),
              MemoryCircleButton(
                icon: Icons.delete_outline,
                label: 'btn_delete'.tr(),
                color: _kDanger,
                onTap: widget.onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _statusLabel() {
    if (widget.isGenerating) {
      final start = widget.generatingSince;
      if (start != null) {
        final elapsed =
            DateTime.now().difference(start).inMilliseconds / 1000.0;
        return 'memory_books_generating_elapsed_n'.tr(
          namedArgs: {'seconds': elapsed.toStringAsFixed(1)},
        );
      }
      return 'memory_books_generating_elapsed'.tr();
    }
    if (_needsRegen) return 'memory_books_badge_needs_regen'.tr();
    if (_draft.content.isEmpty && _draft.status == 'pending_generation') {
      return 'memory_books_needs_generation'.tr();
    }
    if (_draft.content.isNotEmpty) return 'memory_books_pending_approval'.tr();
    return _draft.status;
  }

  Color _statusColor(BuildContext context) {
    if (widget.isGenerating) return _kAmber;
    if (_needsRegen) return _kDanger;
    if (_draft.content.isEmpty) return _kAmber;
    return context.cs.onSurfaceVariant;
  }

  IconData _badgeIcon() {
    if (widget.isGenerating) return Icons.autorenew_rounded;
    if (_needsRegen) return Icons.error_outline_rounded;
    if (_draft.content.isEmpty && _draft.status == 'pending_generation') {
      return Icons.pending_outlined;
    }
    return Icons.drafts_outlined;
  }

  String _badgeLabel() {
    if (widget.isGenerating) return 'memory_books_badge_generating'.tr();
    if (_needsRegen) return 'memory_books_badge_needs_regen'.tr();
    if (_draft.content.isEmpty && _draft.status == 'pending_generation') {
      return 'memory_books_badge_needs_gen'.tr();
    }
    return 'memory_books_badge_draft'.tr();
  }

  Color _badgeColor() {
    if (widget.isGenerating) return _kAmber;
    if (_needsRegen) return _kDanger;
    if (_draft.content.isEmpty && _draft.status == 'pending_generation') {
      return _kAmber;
    }
    return _kCyan;
  }
}
