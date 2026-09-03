import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../core/llm/lorebook_coverage.dart';
import '../../../../shared/theme/app_colors.dart';
import 'coverage_tone.dart';

/// A small tinted pill — the coverage surfaces' only badge shape.
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

/// Where the entry is inserted in the prompt.
class CoveragePositionBadge extends StatelessWidget {
  const CoveragePositionBadge({super.key, required this.position});

  final String position;

  @override
  Widget build(BuildContext context) {
    final tone = CoverageTone.of(context);
    final (label, color) = switch (position) {
      'worldInfoBefore' => ('position_before'.tr(), tone.vector),
      'worldInfoAfter' => ('position_after'.tr(), tone.injected),
      'lorebooksMacro' => ('position_macro'.tr(), tone.constant),
      _ => (position, context.cs.onSurfaceVariant),
    };
    return CoverageBadge(label: label, color: color);
  }
}

/// Every badge an entry earns, in a stable order: what it is, then why it did
/// or did not make it into the prompt.
List<Widget> coverageEntryBadges(BuildContext context, CoverageEntry entry) {
  final tone = CoverageTone.of(context);
  final isVector = entry.matchedKeys.length == 1 &&
      entry.matchedKeys.first == '[vector]';
  return [
    if (entry.constant)
      CoverageBadge(label: 'label_const_badge'.tr(), color: tone.constant),
    if (isVector)
      CoverageBadge(
        label: 'label_vector_badge'.tr(),
        color: tone.vector,
        icon: Icons.scatter_plot_outlined,
      ),
    if (entry.viaRecursion)
      CoverageBadge(
        label: 'label_recursion_badge'.tr(
          args: ['${entry.recursionPass}'],
        ),
        color: tone.recursion,
        icon: Icons.repeat_rounded,
      ),
    if (entry.stickyHeld)
      CoverageBadge(label: 'label_sticky_badge'.tr(), color: tone.recursion),
    if (entry.onCooldown)
      CoverageBadge(label: 'label_cooldown_badge'.tr(), color: tone.idle),
    if (entry.cutOff == CoverageCutOff.budget)
      CoverageBadge(label: 'label_budget_badge'.tr(), color: tone.cutOff),
    if (entry.cutOff == CoverageCutOff.bookLimit)
      CoverageBadge(label: 'label_book_limit_badge'.tr(), color: tone.cutOff),
  ];
}
