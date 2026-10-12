import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_switch.dart';

// Building blocks for the hint card of a guide tour: tip rows, and the
// switches a step lets the reader flip in place.

/// One explained control: what it looks like and what it does.
class GuideTip {
  final IconData icon;
  final String title;
  final String body;
  const GuideTip({required this.icon, required this.title, required this.body});

  /// A tip whose copy lives under `<key>_title` and `<key>_body`.
  GuideTip.tr(this.icon, String key)
    : title = '${key}_title'.tr(),
      body = '${key}_body'.tr();
}

/// A column of [GuideTip] rows.
class GuideTipList extends StatelessWidget {
  final List<GuideTip> tips;
  const GuideTipList({super.key, required this.tips});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < tips.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _GuideRow(
            icon: tips[i].icon,
            title: tips[i].title,
            body: tips[i].body,
          ),
        ],
      ],
    );
  }
}

/// A setting the guide lets the reader flip in place, styled like a tip row.
class GuideSwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final bool value;
  final ValueChanged<bool> onChanged;

  const GuideSwitchRow({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _GuideRow(
      icon: icon,
      title: title,
      body: body,
      trailing: GlazeSwitch(value: value, onChanged: onChanged),
    );
  }
}

class _GuideRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Widget? trailing;

  const _GuideRow({
    required this.icon,
    required this.title,
    required this.body,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: context.cs.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.cs.onSurface.withValues(alpha: 0.08)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: context.cs.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: context.cs.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: context.cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.cs.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Padding(padding: const EdgeInsets.only(top: 2), child: trailing),
          ],
        ],
      ),
    );
  }
}
