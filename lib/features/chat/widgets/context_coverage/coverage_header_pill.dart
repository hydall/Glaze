import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';

/// `12 / 40` with the layer's icon — the collapsed card's whole payload.
class CoverageHeaderPill extends StatelessWidget {
  const CoverageHeaderPill({
    super.key,
    required this.icon,
    required this.value,
    required this.total,
    required this.color,
  });

  final IconData icon;
  final String value;
  final String total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: context.cs.onSurface,
            ),
          ),
          Text(
            '/$total',
            style: TextStyle(fontSize: 11, color: context.cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
