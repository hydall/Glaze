import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/db/app_db.dart' show CardEvolutionWriterCallRow;
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_expansion_tile.dart';
import '../card_rewriter_labels.dart';
import '../card_rewriter_recovery_view_service.dart';

/// One interrupted writer chain: what it was doing when it stopped, the
/// requests it had checkpointed, and the four ways out — continue, retry the
/// failed request, correct its response by hand, or drop the chain.
class CardRewriterRecoveryTile extends StatelessWidget {
  const CardRewriterRecoveryTile({
    super.key,
    required this.recovery,
    required this.busy,
    required this.onContinue,
    required this.onRetry,
    required this.onCorrect,
    required this.onDelete,
  });

  final CardRewriterRecoveryView recovery;
  final bool busy;
  final VoidCallback onContinue;
  final ValueChanged<CardEvolutionWriterCallRow> onRetry;
  final ValueChanged<CardEvolutionWriterCallRow> onCorrect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final frontier = recovery.frontier;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlazeExpansionTile(
        surface: true,
        leading: Icon(
          Icons.pause_circle_outline,
          size: 20,
          color: context.cs.error,
        ),
        title: Text(
          frontier == null
              ? recovery.calls.isEmpty
                    ? 'card_rewriter_studio_resume_chain'.tr()
                    : 'card_rewriter_studio_finalize_chain'.tr()
              : 'card_rewriter_studio_stage_failed'.tr(
                  namedArgs: {'stage': cardRewriterStageLabel(frontier.stage)},
                ),
        ),
        subtitle: Text(
          'card_rewriter_studio_requests_completed'.tr(
            namedArgs: {
              'completed': '${recovery.completedCount}',
              'total': '${recovery.calls.length}',
            },
          ),
        ),
        children: [
          CardRewriterDetailRow(
            label: 'card_rewriter_studio_claim'.tr(),
            value: recovery.claim.id,
          ),
          if (recovery.claim.failureCode case final code?)
            CardRewriterDetailRow(
              label: 'card_rewriter_studio_failure'.tr(),
              value: code,
            ),
          if (recovery.claim.failureDetail case final detail?)
            CardRewriterDetailRow(
              label: 'card_rewriter_studio_failure_detail'.tr(),
              value: detail,
            ),
          const SizedBox(height: 6),
          for (final call in recovery.calls)
            _WriterCallTile(call: call, isFrontier: call.id == frontier?.id),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              GlazeActionButton(
                icon: Icons.play_arrow_outlined,
                label: 'card_rewriter_studio_continue_chain'.tr(),
                onTap: busy ? null : onContinue,
              ),
              if (frontier?.status == 'failed') ...[
                GlazeActionButton(
                  icon: Icons.refresh,
                  label: 'card_rewriter_studio_retry_request'.tr(),
                  onTap: busy ? null : () => onRetry(frontier!),
                ),
                GlazeActionButton(
                  icon: Icons.edit_outlined,
                  label: 'card_rewriter_studio_correct_response'.tr(),
                  tone: GlazeActionTone.primary,
                  onTap: busy ? null : () => onCorrect(frontier!),
                ),
              ],
              GlazeActionButton(
                icon: Icons.delete_outline_rounded,
                label: 'rewrite_delete'.tr(),
                tone: GlazeActionTone.destructive,
                onTap: busy ? null : onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One checkpointed request of a chain: its stage, its status, and — opened —
/// the exact prompt and response it recorded.
class _WriterCallTile extends StatelessWidget {
  const _WriterCallTile({required this.call, required this.isFrontier});

  final CardEvolutionWriterCallRow call;
  final bool isFrontier;

  @override
  Widget build(BuildContext context) {
    final color = switch (call.status) {
      'completed' => context.cs.primary,
      'failed' => context.cs.error,
      _ => context.cs.tertiary,
    };
    return GlazeExpansionTile(
      showDivider: true,
      childrenPadding: const EdgeInsets.fromLTRB(0, 0, 0, 10),
      leading: Icon(switch (call.status) {
        'completed' => Icons.check_circle_outline,
        'failed' => Icons.error_outline,
        'prepared' => Icons.pause_circle_outline,
        _ => Icons.hourglass_top,
      }, size: 18, color: color),
      title: Text(
        '${call.ordinal}. ${cardRewriterStageLabel(call.stage)}'
        '${call.stageOrdinal > 1 ? ' ${call.stageOrdinal}' : ''}',
      ),
      subtitle: Text(
        isFrontier
            ? 'card_rewriter_studio_call_current'.tr(
                namedArgs: {
                  'status': cardRewriterCallStatusLabel(call.status),
                },
              )
            : cardRewriterCallStatusLabel(call.status),
      ),
      children: [
        CardRewriterDetailRow(
          label: 'card_rewriter_studio_prompt_hash'.tr(),
          value: call.promptHash,
        ),
        if (call.failureCode case final code?)
          CardRewriterDetailRow(
            label: 'card_rewriter_studio_failure'.tr(),
            value: code,
          ),
        if (call.failureDetail case final detail?)
          CardRewriterDetailRow(
            label: 'card_rewriter_studio_failure_detail'.tr(),
            value: detail,
          ),
        if (call.parserCode case final code?)
          CardRewriterDetailRow(
            label: 'card_rewriter_studio_parser'.tr(),
            value: code,
          ),
        if (call.parserDetail case final detail?)
          CardRewriterDetailRow(
            label: 'card_rewriter_studio_parser_detail'.tr(),
            value: detail,
          ),
        const SizedBox(height: 6),
        CardRewriterRawBlock(
          label: 'card_rewriter_studio_prompt'.tr(),
          body: call.prompt,
        ),
        const SizedBox(height: 8),
        CardRewriterRawBlock(
          label: 'card_rewriter_studio_response'.tr(),
          body:
              call.responseText ?? 'card_rewriter_studio_no_response'.tr(),
        ),
      ],
    );
  }
}

/// A `label: value` line of a diagnostics record, selectable so an id or a
/// failure code can be copied out.
class CardRewriterDetailRow extends StatelessWidget {
  const CardRewriterDetailRow({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: SelectableText.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurfaceVariant,
            ),
          ),
          TextSpan(
            text: value,
            style: TextStyle(fontSize: 12, color: context.cs.onSurface),
          ),
        ],
      ),
    ),
  );
}

/// A captured prompt or response, under its own caption.
class CardRewriterRawBlock extends StatelessWidget {
  const CardRewriterRawBlock({
    super.key,
    required this.label,
    required this.body,
  });

  final String label;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: context.cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        SelectableText(
          body,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            height: 1.35,
            color: context.cs.onSurface,
          ),
        ),
      ],
    );
  }
}
