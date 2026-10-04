import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';

/// Pill carrying a glyph and a short value, used by the Presets list rows
/// (token estimate, requests per turn, folder size).
class PresetSmallBadge extends StatelessWidget {
  final IconData icon;
  final String label;

  /// Overrides the icon/label colour (set when the badge sits on a cover).
  final Color? foreground;

  /// Over a cover the near-transparent black pill disappears, so a light
  /// scrim is used instead.
  final bool onCover;

  const PresetSmallBadge({
    super.key,
    required this.icon,
    required this.label,
    this.foreground,
    this.onCover = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = foreground ?? context.cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: onCover
            ? Colors.black.withValues(alpha: 0.35)
            : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
