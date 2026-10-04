import 'package:flutter/material.dart';

/// A small tinted pill — the coverage surfaces' only badge shape.
///
/// Only matched keys wear one now. The status pills that used to ride the
/// collapsed row (`CONST`, `BUDGET`, the position) said too little in too
/// little space; the same information is a wrapped sentence inside the expanded
/// record — see `coverage_reasons.dart`.
class CoverageBadge extends StatelessWidget {
  const CoverageBadge({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: icon == null ? 6 : 4,
        right: 6,
        top: 2,
        bottom: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
