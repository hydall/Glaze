import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Pill naming the variation something belongs to.
///
/// A chip rather than a `"Name — Variation"` suffix on purpose: as a suffix it
/// was the last thing on a single-line, ellipsized row, so the part that told
/// two otherwise identical rows apart was the first part to be cut off.
///
/// Shared by the chat list rows and the library/variations cards so a variation
/// is marked the same way wherever it shows up.
class VariationChip extends StatelessWidget {
  final String name;

  /// Caps the pill so a long variation name cannot push the row's real content
  /// out of view; the name itself ellipsizes inside it.
  final double maxWidth;

  const VariationChip({super.key, required this.name, this.maxWidth = 110});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: context.cs.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: context.cs.primary,
        ),
      ),
    );
  }
}
