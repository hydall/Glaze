import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../services/summary_generation_service.dart';
import 'summary_nothing_to_compact_note.dart' show summaryTokenCount;

/// "This chat now" in the summary settings: where the prompt stands and what
/// each kind of compaction would do to it, as a bar and a few numbers rather
/// than a paragraph.
///
/// The bar is the prompt's room ([SummaryRunOutlook.total]) split into the
/// fixed part, the summary and the history no block covers; the tick marks
/// the automatic trigger while auto compaction is on. Under it, what "Compact
/// history" would keep and retell with the manual tail as set, and — with
/// auto compaction on — where it starts and what it leaves.
class SummaryOutlookCard extends StatelessWidget {
  final SummaryRunOutlook outlook;

  /// The raw tail "Compact history" keeps, in tokens.
  final int manualTailTokens;
  final bool autoEnabled;

  const SummaryOutlookCard({
    super.key,
    required this.outlook,
    required this.manualTailTokens,
    required this.autoEnabled,
  });

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final history = outlook.historyTokens;
    final manualKeeps = math.min(history, manualTailTokens);
    final manualRetells = history - manualKeeps;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _PromptBar(
            outlook: outlook,
            triggerTokens: autoEnabled ? outlook.triggerTokens : null,
            fixedColor: cs.outline,
            summaryColor: cs.primary.withValues(alpha: 0.5),
            historyColor: cs.primary,
          ),
          const SizedBox(height: 10),
          _Row(
            label: 'summary_outlook_total'.tr(),
            value: outlook.total,
            strong: true,
          ),
          _Row(
            label: 'summary_outlook_fixed'.tr(),
            value: outlook.fixedTokens,
            dot: cs.outline,
          ),
          _Row(
            label: 'summary_outlook_summary'.tr(),
            value: outlook.summaryTokens,
            dot: cs.primary.withValues(alpha: 0.5),
          ),
          _Row(
            label: 'summary_outlook_history'.tr(),
            value: history,
            dot: cs.primary,
          ),
          const SizedBox(height: 8),
          _Caption('summary_outlook_manual'.tr()),
          _Row(label: 'summary_outlook_keeps'.tr(), value: manualKeeps),
          _Row(label: 'summary_outlook_retells'.tr(), value: manualRetells),
          if (autoEnabled) ...[
            const SizedBox(height: 8),
            _Caption('summary_outlook_auto'.tr()),
            _Row(
              label: 'summary_outlook_starts_at'.tr(),
              value: outlook.triggerTokens,
            ),
            _Row(
              label: 'summary_outlook_keeps'.tr(),
              value: outlook.tailTokens,
            ),
            if (outlook.floorOnly) ...[
              const SizedBox(height: 6),
              Text(
                'summary_outlook_floor_only'.tr(),
                style: TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _PromptBar extends StatelessWidget {
  final SummaryRunOutlook outlook;
  final int? triggerTokens;
  final Color fixedColor;
  final Color summaryColor;
  final Color historyColor;

  const _PromptBar({
    required this.outlook,
    required this.triggerTokens,
    required this.fixedColor,
    required this.summaryColor,
    required this.historyColor,
  });

  @override
  Widget build(BuildContext context) {
    final total = math.max(
      1,
      math.max(
        outlook.total,
        outlook.fixedTokens + outlook.summaryTokens + outlook.historyTokens,
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        double w(int tokens) => width * tokens / total;
        final trigger = triggerTokens;
        return SizedBox(
          height: 14,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                top: 3,
                bottom: 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: ColoredBox(
                    color: context.cs.onSurface.withValues(alpha: 0.08),
                    child: Row(
                      children: [
                        Container(
                          width: w(outlook.fixedTokens),
                          color: fixedColor,
                        ),
                        Container(
                          width: w(outlook.summaryTokens),
                          color: summaryColor,
                        ),
                        Container(
                          width: w(outlook.historyTokens),
                          color: historyColor,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (trigger != null)
                Positioned(
                  left: (w(trigger) - 1).clamp(0, width - 2),
                  top: 0,
                  bottom: 0,
                  width: 2,
                  child: ColoredBox(color: context.cs.onSurface),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Caption extends StatelessWidget {
  final String text;

  const _Caption(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: context.cs.primary,
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  final String label;
  final int value;
  final Color? dot;
  final bool strong;

  const _Row({
    required this.label,
    required this.value,
    this.dot,
    this.strong = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final style = TextStyle(
      fontSize: 13,
      color: strong ? cs.onSurface : cs.onSurfaceVariant,
      fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          if (dot case final color?) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(label, style: style)),
          Text(
            summaryTokenCount(value),
            style: style.copyWith(
              color: cs.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
