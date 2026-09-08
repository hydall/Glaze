import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Compact, colour-coded tag chips shown on character / catalog cards.
///
/// NSFW / SFW / `#custom` tags get dedicated accent colours; everything else
/// falls back to the primary tint. Pass [max] to cap how many chips render.
class CardTagChips extends StatelessWidget {
  final List<String> tags;
  final int? max;

  const CardTagChips({super.key, required this.tags, this.max});

  @override
  Widget build(BuildContext context) {
    final shown = max != null && tags.length > max! ? tags.take(max!) : tags;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: shown.map((tag) {
        final upper = tag.toUpperCase();
        final isNsfw = upper == 'NSFW';
        final isSfw = upper == 'SFW';
        final isCustom = tag.startsWith('#');
        final Color bg, fg, border;
        if (isNsfw) {
          bg = const Color(0x33FF4444);
          fg = const Color(0xFFFF4444);
          border = const Color(0x4DFF4444);
        } else if (isSfw) {
          bg = const Color(0x334CAF50);
          fg = const Color(0xFF4CAF50);
          border = const Color(0x4D4CAF50);
        } else if (isCustom) {
          bg = const Color(0x1A00FFFF);
          fg = const Color(0xFF00CCCC);
          border = const Color(0x3300FFFF);
        } else {
          bg = context.cs.primary.withValues(alpha: 0.15);
          fg = context.cs.primary;
          border = context.cs.primary.withValues(alpha: 0.2);
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: border),
          ),
          child: Text(
            tag,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        );
      }).toList(),
    );
  }
}
