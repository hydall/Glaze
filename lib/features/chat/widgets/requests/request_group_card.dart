import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../state/request_timeline.dart';
import 'inspector_surface.dart';
import 'request_stage_label.dart';

/// One group in the timeline — a chat turn or a background job — with its steps
/// in execution order.
///
/// Collapsed it is a single line: what ran, when, how many requests, and
/// whether anything went wrong. That is the density a log needs; the steps are
/// one tap away and a step's payload one more.
class RequestGroupCard extends StatelessWidget {
  const RequestGroupCard({
    super.key,
    required this.group,
    required this.expanded,
    required this.onToggle,
    required this.onOpenEntry,
    this.replyPreview,
    this.turnNumber,
  });

  final RequestGroup group;
  final bool expanded;
  final VoidCallback onToggle;
  final ValueChanged<RequestTimelineEntry> onOpenEntry;

  /// First words of the assistant message this turn produced, when the message
  /// is still in the session — it is what makes a row recognisable.
  final String? replyPreview;
  final int? turnNumber;

  @override
  Widget build(BuildContext context) {
    final color = requestFamilyColor(context, group.leadFamily);
    final started = DateTime.fromMillisecondsSinceEpoch(group.startedAtMs);

    return InspectorPlaque(
      margin: const EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.zero,
      accent: color,
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(width: 3, color: color),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _titleRow(context, color, started),
                          const SizedBox(height: 2),
                          _subtitle(context),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: context.cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(13, 0, 8, 8),
              child: Column(
                children: [
                  for (final entry in group.entries)
                    _StepRow(entry: entry, onTap: () => onOpenEntry(entry)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _titleRow(BuildContext context, Color color, DateTime started) {
    final title = group.kind == RequestGroupKind.turn
        ? (turnNumber == null
              ? 'requests_turn'.tr()
              : 'requests_turn_numbered'.tr(args: ['$turnNumber']))
        : requestFamilyLabel(group.leadFamily);

    return Row(
      children: [
        Icon(requestFamilyIcon(group.leadFamily), size: 14, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
        if (group.hasFailure) ...[
          const SizedBox(width: 6),
          Icon(Icons.error_outline_rounded, size: 13, color: context.cs.error),
        ],
        const Spacer(),
        Text(
          formatRequestTime(started),
          style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _subtitle(BuildContext context) {
    final preview = replyPreview;
    final parts = <String>[
      'requests_request_count'.tr(args: ['${group.requestCount}']),
      if (group.hasRetry) 'requests_had_retry'.tr(),
    ];
    final text = preview == null || preview.isEmpty
        ? parts.join(' · ')
        : '$preview — ${parts.join(' · ')}';
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.entry, required this.onTap});

  final RequestTimelineEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = requestFamilyColor(context, entry.family);
    final model = '${entry.capture.request['model'] ?? ''}';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            Flexible(
              child: Text(
                requestStepLabel(
                  stage: entry.stage,
                  agentId: entry.capture.row.agentId,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: context.cs.onSurface),
              ),
            ),
            if (entry.attempts > 1) ...[
              const SizedBox(width: 6),
              Text(
                '×${entry.attempts}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            ],
            if (entry.failed) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.error_outline_rounded,
                size: 12,
                color: context.cs.error,
              ),
            ],
            const Spacer(),
            if (model.isNotEmpty)
              Flexible(
                child: Text(
                  model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 10,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ),
            Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: context.cs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
