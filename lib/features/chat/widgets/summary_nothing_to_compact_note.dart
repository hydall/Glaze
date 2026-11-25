import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../state/summary_compaction_provider.dart';

/// 12345 as "12 345": thousands set apart, no locale machinery.
String summaryTokenCount(int n) {
  final digits = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(' ');
    out.write(digits[i]);
  }
  return out.toString();
}

/// What "Compact history" says when it found nothing to retell.
///
/// Not an error — the run did what it is set to do — so a muted note rather
/// than `GlazeErrorBlock`, with the numbers that explain it: how much history
/// the summary does not cover, and how much of it the manual tail keeps as
/// written. When the tail is what held the run back, the note offers to
/// retell everything but the newest messages instead.
class SummaryNothingToCompactNote extends StatelessWidget {
  final SummaryNothingToCompact result;

  /// Retells all but the newest messages; null while the chain is held.
  final VoidCallback? onCompactNewest;
  final VoidCallback onDismiss;

  const SummaryNothingToCompactNote({
    super.key,
    required this.result,
    required this.onCompactNewest,
    required this.onDismiss,
  });

  String _message() {
    final args = {
      'history': summaryTokenCount(result.historyTokens),
      'tail': summaryTokenCount(result.tailTokens),
    };
    if (result.historyTokens == 0) return 'summary_nothing_all_summarized'.tr();
    if (!result.keptTail) {
      return 'summary_nothing_newest_only'.tr(namedArgs: args);
    }
    if (result.historyTokens <= result.tailTokens) {
      return 'summary_nothing_in_tail'.tr(namedArgs: args);
    }
    return 'summary_nothing_too_small'.tr(namedArgs: args);
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return GlassSurface(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: cs.outlineVariant),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'summary_nothing_title'.tr(),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: cs.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'btn_close'.tr(),
                  onPressed: onDismiss,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                _message(),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            if (result.canCompactNewestOnly) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GlazeActionButton(
                  icon: Icons.compress_rounded,
                  label: 'summary_compact_newest'.tr(),
                  expand: true,
                  onTap: onCompactNewest,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
