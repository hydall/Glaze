import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/llm/context_calculator.dart';
import '../../../shared/theme/app_colors.dart';

final kSourceMeta = <String, SourceMeta>{
  'preset': SourceMeta(
    label: 'subtab_preset'.tr(),
    color: const Color(0xFF4ECDC4),
  ),
  'description': SourceMeta(
    label: 'label_description'.tr(),
    color: const Color(0xFFFF6B6B),
  ),
  'personality': SourceMeta(
    label: 'label_personality'.tr(),
    color: const Color(0xFFD4A5E5),
  ),
  'scenario': SourceMeta(
    label: 'label_scenario'.tr(),
    color: const Color(0xFFB8D4E3),
  ),
  'mesExamples': SourceMeta(
    label: 'token_source_mes_examples'.tr(),
    color: const Color(0xFFC9B1FF),
  ),
  'depthPrompt': SourceMeta(
    label: 'token_source_depth_prompt'.tr(),
    color: const Color(0xFFE8A0BF),
  ),
  'persona': SourceMeta(
    label: 'tab_personas'.tr(),
    color: const Color(0xFF81ECEC),
  ),
  'authorsNote': SourceMeta(
    label: 'magic_authors_notes'.tr(),
    color: const Color(0xFFFFD93D),
  ),
  'summary': SourceMeta(
    label: 'token_source_summary'.tr(),
    color: const Color(0xFF95E1D3),
  ),
  'memory': SourceMeta(
    label: 'token_source_memory'.tr(),
    color: const Color(0xFFA8E6CF),
  ),
  'lorebook': SourceMeta(
    label: 'token_source_keyword_lorebook'.tr(),
    color: const Color(0xFFF4A261),
  ),
  'lorebooks': SourceMeta(
    label: 'token_source_lorebooks_macro'.tr(),
    color: const Color(0xFFE8985E),
  ),
  'vectorLore': SourceMeta(
    label: 'token_source_vector_lorebook'.tr(),
    color: const Color(0xFFE76F51),
  ),
  'lorebookReserve': SourceMeta(
    label: 'token_source_lorebook_reserve'.tr(),
    color: const Color(0xFFA8DADC),
  ),
  'history': SourceMeta(
    label: 'token_source_history'.tr(),
    color: const Color(0xFF6C5CE7),
  ),
};

class SourceMeta {
  final String label;
  final Color color;
  const SourceMeta({required this.label, required this.color});
}

class BarRow {
  final String key;
  final String label;
  final int tokens;
  final Color color;
  const BarRow({
    required this.key,
    required this.label,
    required this.tokens,
    required this.color,
  });
}

int tokensForKey(TokenBreakdown bd, String key) {
  return switch (key) {
    'lorebookReserve' => _unusedLorebookReserve(bd),
    'vectorLore' => bd.vectorLoreTokens,
    'preset' => bd.presetNetTokens,
    _ =>
      (bd.sourceTokens[key] ?? 0) > 0
          ? bd.sourceTokens[key]!
          : (bd.macroTokens[key] ?? 0),
  };
}

int _unusedLorebookReserve(TokenBreakdown bd) {
  final actual =
      (bd.sourceTokens['lorebook'] ?? 0) + (bd.macroTokens['lorebooks'] ?? 0);
  // Vector lorebook entries also consume the reserve budget; without
  // subtracting them, the "Lorebook Reserve" row would inflate by
  // vectorLoreTokens and double-count what the dedicated "Vector Lorebook"
  // row already shows.
  final used = actual + bd.vectorLoreTokens;
  return bd.lorebookReserveTokens > used ? bd.lorebookReserveTokens - used : 0;
}

List<BarRow> buildOrderedRows(TokenBreakdown bd, List<String> keys) {
  final rows = <BarRow>[];
  for (final key in keys) {
    final tokens = tokensForKey(bd, key);
    if (tokens <= 0) continue;
    final meta = kSourceMeta[key] ?? SourceMeta(label: key, color: Colors.grey);
    rows.add(
      BarRow(key: key, label: meta.label, tokens: tokens, color: meta.color),
    );
  }
  return rows;
}

class HeroCard extends StatelessWidget {
  final int used;
  final int contextSize;
  final int remaining;
  final double historyFill;

  const HeroCard({
    super.key,
    required this.used,
    required this.contextSize,
    required this.remaining,
    required this.historyFill,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: [
            context.cs.primary,
            Color.lerp(context.cs.primary, Colors.black, 0.2)!,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        children: [
          Text(
            fmtNum(used),
            style: const TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1.1,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'tokenizer_used_of'.tr(args: [fmtNum(contextSize)]).toUpperCase(),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.white70,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: KpiItem(
                    value: fmtNum(remaining),
                    label: 'label_remaining'.tr(),
                  ),
                ),
                Container(
                  width: 1,
                  height: 28,
                  color: Colors.white.withValues(alpha: 0.2),
                ),
                Expanded(
                  child: KpiItem(
                    value: '${historyFill.round()}%',
                    label: 'label_history_fill'.tr(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String fmtNum(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

class KpiItem extends StatelessWidget {
  final String value;
  final String label;
  const KpiItem({super.key, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.65),
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

class TokenizerLayout extends StatelessWidget {
  final TokenBreakdown breakdown;
  final int contextSize;
  const TokenizerLayout({
    super.key,
    required this.breakdown,
    required this.contextSize,
  });

  static const _mainKeys = [
    'description',
    'personality',
    'scenario',
    'mesExamples',
    'depthPrompt',
    'preset',
    'persona',
    'authorsNote',
    'summary',
    'memory',
    'history',
  ];
  static const _reserveKeys = [
    'lorebook',
    'lorebooks',
    'vectorLore',
    'lorebookTotal',
    'lorebookReserve',
  ];

  @override
  Widget build(BuildContext context) {
    final mainItems = buildOrderedRows(breakdown, _mainKeys);
    final reserveItems = buildOrderedRows(breakdown, _reserveKeys);

    final List<BarRow> combinedBreakdownItems = [...mainItems, ...reserveItems];
    final hasKeywordLore =
        (breakdown.sourceTokens['lorebook'] ?? 0) > 0 ||
        (breakdown.macroTokens['lorebooks'] ?? 0) > 0;
    if (breakdown.lorebookTotal > 0 &&
        hasKeywordLore &&
        breakdown.vectorLoreTokens > 0) {
      combinedBreakdownItems.add(
        BarRow(
          key: 'lorebookTotal',
          label: 'token_source_lorebook_total'.tr(),
          tokens: breakdown.lorebookTotal,
          color: Colors.transparent,
        ),
      );
    }

    final totalMain = mainItems.fold<int>(0, (s, r) => s + r.tokens);
    final totalReserve = reserveItems.fold<int>(0, (s, r) => s + r.tokens);
    final emptyTokens = contextSize - totalMain - totalReserve;
    final ctxPct = contextSize > 0 ? 1.0 / contextSize : 0.0;

    // Build segment data for the bar painter
    final segments = <_BarSegment>[];
    for (final item in mainItems) {
      segments.add(
        _BarSegment(
          fraction: item.tokens.toDouble() * ctxPct,
          color: item.color,
        ),
      );
    }
    if (emptyTokens > 0) {
      segments.add(
        _BarSegment(
          fraction: emptyTokens.toDouble() * ctxPct,
          color: Colors.transparent,
        ),
      );
    }
    for (final item in reserveItems) {
      segments.add(
        _BarSegment(
          fraction: item.tokens.toDouble() * ctxPct,
          color: item.color,
        ),
      );
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: CustomPaint(
                painter: _BarChartPainter(
                  segments: segments,
                  backgroundColor: context.cs.surfaceContainerHighest,
                  borderRadius: 12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: combinedBreakdownItems
                  .map((row) => _breakdownRow(context, row, breakdown))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _breakdownRow(BuildContext context, BarRow row, TokenBreakdown bd) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          if (row.key == 'lorebookTotal')
            const SizedBox(width: 8)
          else
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: row.color,
                shape: BoxShape.circle,
              ),
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              row.label,
              style: TextStyle(
                fontSize: 14,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            _rowTokenText(bd, row),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  String _rowTokenText(TokenBreakdown bd, BarRow row) {
    return '${row.tokens}';
  }
}

/// Amber accent for the cutoff notice. A semantic status with no token behind
/// it, hoisted per `docs/UI_KIT.md` § Colours.
const Color _cutoffAccent = Color(0xFFE0A030);

/// How much of the history did not make it into the prompt.
///
/// Not a failure — it is what a long chat in a finite window looks like. The
/// gear leads to the connection's Context section, where the window and the
/// trim mode that produced this number actually live.
class CutoffWarning extends StatelessWidget {
  final int cutoffCount;
  final VoidCallback? onOpenSettings;

  const CutoffWarning({
    super.key,
    required this.cutoffCount,
    this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
      decoration: BoxDecoration(
        color: _cutoffAccent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _cutoffAccent.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, size: 18, color: _cutoffAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'count_message_didnt_fit'.plural(cutoffCount),
              style: const TextStyle(fontSize: 13, color: _cutoffAccent),
            ),
          ),
          if (onOpenSettings != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.settings_outlined, size: 18),
              color: _cutoffAccent,
              tooltip: 'context_open_api_settings'.tr(),
              onPressed: onOpenSettings,
            ),
        ],
      ),
    );
  }
}

class _BarSegment {
  final double fraction;
  final Color color;
  _BarSegment({required this.fraction, required this.color});
}

class _BarChartPainter extends CustomPainter {
  final List<_BarSegment> segments;
  final Color backgroundColor;
  final double borderRadius;

  _BarChartPainter({
    required this.segments,
    required this.backgroundColor,
    required this.borderRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(borderRadius),
    );

    // Draw background
    final bgPaint = Paint()..color = backgroundColor;
    canvas.drawRRect(rrect, bgPaint);

    canvas.save();
    canvas.clipRRect(rrect);

    // Draw base gradient (simulating the container's gradient from before)
    final rect = Offset.zero & size;
    final gradient = LinearGradient(
      colors: [
        Colors.white.withValues(alpha: 0.05),
        Colors.white.withValues(alpha: 0.12),
        Colors.white.withValues(alpha: 0.02),
        Colors.transparent,
      ],
      stops: const [0, 0.2, 0.5, 1],
    );
    final shaderPaint = Paint()..shader = gradient.createShader(rect);
    canvas.drawRect(rect, shaderPaint);

    double currentY = 0;
    for (final segment in segments) {
      if (segment.fraction <= 0) continue;
      final height = segment.fraction * size.height;
      if (height <= 0) continue;

      final segmentRect = Rect.fromLTWH(0, currentY, size.width, height);

      if (segment.color != Colors.transparent) {
        final darken = Color.lerp(segment.color, Colors.black, 0.15)!;
        final segmentGradient = LinearGradient(colors: [segment.color, darken]);
        final segmentPaint = Paint()
          ..shader = segmentGradient.createShader(segmentRect);

        canvas.drawRect(segmentRect, segmentPaint);

        // Draw borders
        final borderPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
        borderPaint.color = Colors.white.withValues(alpha: 0.1);
        canvas.drawLine(segmentRect.topLeft, segmentRect.topRight, borderPaint);

        borderPaint.color = Colors.black.withValues(alpha: 0.1);
        canvas.drawLine(
          segmentRect.bottomLeft,
          segmentRect.bottomRight,
          borderPaint,
        );
      }

      currentY += height;
    }

    canvas.restore();

    // Draw outer box shadows (inner shadow effect)
    final path = Path()..addRRect(rrect);

    canvas.save();
    canvas.clipRRect(rrect);

    final innerShadowPaint1 = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..maskFilter = const MaskFilter.blur(BlurStyle.inner, 2);
    canvas.drawPath(path.shift(const Offset(1, 1)), innerShadowPaint1);

    final innerShadowPaint2 = Paint()
      ..color = Colors.black.withValues(alpha: 0.2)
      ..maskFilter = const MaskFilter.blur(BlurStyle.inner, 2);
    canvas.drawPath(path.shift(const Offset(-1, -1)), innerShadowPaint2);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BarChartPainter oldDelegate) {
    if (oldDelegate.segments.length != segments.length) return true;
    for (int i = 0; i < segments.length; i++) {
      if (oldDelegate.segments[i].fraction != segments[i].fraction ||
          oldDelegate.segments[i].color != segments[i].color) {
        return true;
      }
    }
    return false;
  }
}
