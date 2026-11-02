import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/models/summary_block.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import 'memory/memory_books_controls.dart';

const Color _kOrange = Color(0xFFFF9800);
const Color _kAmber = Color(0xFFFFC107);
const Color _kGreen = Color(0xFF4CAF50);
const Color _kDanger = Color(0xFFFF5252);
const Color _kCyan = Color(0xFF26C6DA);

/// One block of the summary chain in the Summary tab.
///
/// Built from the parts a Memory Books draft row is (`MemoryDraftCard`), so
/// the two tabs of the Memory sheet read as one surface: the plaque, the state
/// pill, the action tiles and the round action buttons. While the block is
/// written again the card counts the seconds and offers Stop; the draft that
/// run leaves takes the block's place on the card, waiting for Approve, and
/// tapping the row edits it — as a memory draft waits and is edited. The
/// block itself keeps its text in the prompt until the draft is approved.
///
/// Archived blocks are shown read-only: no selection, no menu, no actions.
class SummaryBlockCard extends StatelessWidget {
  final SummaryBlock block;
  final String title;

  /// The block's source messages changed: it is not sent.
  final bool stale;

  /// The draft's source messages changed after it was written: it can only
  /// be regenerated or discarded.
  final bool draftStale;

  final bool selected;
  final VoidCallback? onToggleSelected;

  /// Edits the draft when the block has one, the block otherwise. Null for
  /// the archive.
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  /// Null for a note and for the archive: neither is written by the
  /// summarizer again.
  final VoidCallback? onRegenerate;

  /// Shortens the block to the block size, as a draft. Null unless the block
  /// is live, past that size and without a draft.
  final VoidCallback? onShorten;

  /// When the run writing this block again started; null while none is.
  final DateTime? generatingSince;

  final VoidCallback? onStop;
  final VoidCallback? onApprove;
  final VoidCallback? onDiscardDraft;

  /// Another change to the chain is running: the summarizer is taken.
  final bool busy;

  const SummaryBlockCard({
    super.key,
    required this.block,
    required this.title,
    this.stale = false,
    this.draftStale = false,
    this.selected = false,
    this.onToggleSelected,
    this.onEdit,
    this.onDelete,
    this.onRegenerate,
    this.onShorten,
    this.generatingSince,
    this.onStop,
    this.onApprove,
    this.onDiscardDraft,
    this.busy = false,
  });

  bool get _generating => generatingSince != null;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final draft = block.draft;
    final settled = draft != null && !_generating;
    return MemoryRow(
      accent: _generating
          ? _kAmber
          : settled && draftStale
          ? _kDanger
          : stale
          ? _kOrange
          : selected
          ? cs.primary
          : null,
      // While the block is being written there is nothing safe to edit, so
      // the row is inert, as a generating memory draft's is.
      onTap: _generating ? null : onEdit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (onToggleSelected != null) ...[
                InkResponse(
                  onTap: onToggleSelected,
                  radius: 18,
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: selected ? cs.primary : cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ),
              if (stale)
                MemoryStatusIcon(
                  icon: Icons.build_circle_outlined,
                  label: 'summary_block_stale'.tr(),
                  color: _kOrange,
                ),
              if (_generating || draft != null) ...[
                const SizedBox(width: 8),
                _pill(),
              ] else if (onEdit != null && onDelete != null)
                MemoryRowMenuButton(
                  title: title,
                  itemsBuilder: (menuContext) => [
                    BottomSheetItem(
                      icon: Icons.edit_outlined,
                      label: 'action_edit'.tr(),
                      onTap: () {
                        Navigator.of(menuContext, rootNavigator: true).pop();
                        onEdit!();
                      },
                    ),
                    BottomSheetItem(
                      icon: Icons.delete_outline,
                      label: 'btn_delete'.tr(),
                      isDestructive: true,
                      onTap: () {
                        Navigator.of(menuContext, rootNavigator: true).pop();
                        onDelete!();
                      },
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 3),
          _status(context),
          const SizedBox(height: 6),
          Text(
            draft?.content ?? block.content,
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: cs.onSurfaceVariant,
            ),
          ),
          // The tile a Memory Books draft has under its body: the action is
          // worth a word, not an unlabelled glyph in the menu.
          if ((onRegenerate != null || onShorten != null) && !_generating) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (onRegenerate != null)
                  Expanded(
                    child: MemoryActionTile(
                      icon: Icons.refresh_rounded,
                      label: 'memory_books_btn_regenerate'.tr(),
                      accent: _kAmber,
                      onTap: busy ? null : onRegenerate,
                    ),
                  ),
                if (onRegenerate != null && onShorten != null)
                  const SizedBox(width: 8),
                if (onShorten != null)
                  Expanded(
                    child: MemoryActionTile(
                      icon: Icons.compress_rounded,
                      label: 'summary_block_shorten'.tr(),
                      accent: _kCyan,
                      onTap: busy ? null : onShorten,
                    ),
                  ),
              ],
            ),
          ],
          if (_generating || settled) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_generating)
                  MemoryCircleButton(
                    icon: Icons.stop_rounded,
                    label: 'memory_books_btn_stop'.tr(),
                    color: _kAmber,
                    onTap: () => onStop?.call(),
                  )
                else ...[
                  if (!draftStale) ...[
                    MemoryCircleButton(
                      icon: Icons.check_rounded,
                      label: 'memory_books_btn_approve'.tr(),
                      color: _kGreen,
                      onTap: () => onApprove?.call(),
                    ),
                    const SizedBox(width: 4),
                  ],
                  MemoryCircleButton(
                    icon: Icons.delete_outline,
                    label: 'summary_draft_discard'.tr(),
                    color: _kDanger,
                    onTap: () => onDiscardDraft?.call(),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _pill() {
    final (label, icon, color) = _generating
        ? (
            'memory_books_badge_generating'.tr(),
            Icons.autorenew_rounded,
            _kAmber,
          )
        : draftStale
        ? (
            'memory_books_badge_needs_regen'.tr(),
            Icons.error_outline_rounded,
            _kDanger,
          )
        : ('memory_books_badge_draft'.tr(), Icons.drafts_outlined, _kCyan);
    return MemoryPill(
      label: label,
      icon: icon,
      color: color,
      fontSize: 10,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    );
  }

  Widget _status(BuildContext context) {
    final since = generatingSince;
    if (since != null) return SummaryElapsedLabel(since: since);
    final draft = block.draft;
    final (text, color) = draft != null && draftStale
        ? ('summary_draft_stale'.tr(), _kDanger)
        : draft != null
        ? (
            [
              'memory_books_pending_approval'.tr(),
              ..._sizes(draft.tokens, draft.sourceTokens),
            ].join(' • '),
            null,
          )
        : stale
        ? ('summary_block_stale'.tr(), _kOrange)
        : (
            [
              if (!block.isNote)
                'memory_messages_n'.plural(block.messageIds.length),
              ..._sizes(block.tokens, block.sourceTokens),
            ].join(' • '),
            null,
          );
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        color: color ?? context.cs.onSurfaceVariant.withValues(alpha: 0.75),
      ),
    );
  }

  static List<String> _sizes(int tokens, int sourceTokens) => [
    'summary_tokens_n'.tr(args: ['$tokens']),
    if (sourceTokens > 0) 'summary_from_tokens_n'.tr(args: ['$sourceTokens']),
  ];
}

/// "Generating… 12.3s", counted from [since]. Shared with the tab's own
/// compaction progress line.
///
/// Ticks on its own so only this line rebuilds, five times a second — the
/// reason `MemoryDraftCard` moved its ticker off the tab.
class SummaryElapsedLabel extends StatefulWidget {
  final DateTime since;

  const SummaryElapsedLabel({super.key, required this.since});

  @override
  State<SummaryElapsedLabel> createState() => SummaryElapsedLabelState();
}

class SummaryElapsedLabelState extends State<SummaryElapsedLabel> {
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds =
        DateTime.now().difference(widget.since).inMilliseconds / 1000.0;
    return Text(
      'memory_books_generating_elapsed_n'.tr(
        namedArgs: {'seconds': seconds.toStringAsFixed(1)},
      ),
      style: const TextStyle(fontSize: 11, color: _kAmber),
    );
  }
}
