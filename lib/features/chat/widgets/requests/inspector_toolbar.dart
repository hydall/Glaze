import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';

/// The line above every drill-down in the Prompt Inspector: back, what you are
/// looking at, and the actions for it.
///
/// The inspector hides its tab strip while a drill-down is open, so this is the
/// only thing telling you where you are — and the next request and a captured
/// one get the same one, because they are the same kind of thing.
class InspectorToolbar extends StatelessWidget {
  const InspectorToolbar({
    super.key,
    required this.title,
    this.subtitle,
    this.titleColor,
    this.onBack,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;

  /// A captured request titles itself in its stage family's colour, the way its
  /// row in the timeline does.
  final Color? titleColor;

  final VoidCallback? onBack;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;

    return Padding(
      padding: EdgeInsets.fromLTRB(onBack == null ? 16 : 4, 4, 8, 4),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
              tooltip: 'requests_back_to_list'.tr(),
              onPressed: onBack,
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: titleColor ?? cs.onSurface,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// Formatted / raw switch. Two icons in a pill with the active one lit — the
/// same control the Request Preview has always had, now shared with a captured
/// request so both are read the same way.
class InspectorViewToggle extends StatelessWidget {
  const InspectorViewToggle({
    super.key,
    required this.isRaw,
    required this.onChanged,
  });

  final bool isRaw;
  final ValueChanged<bool> onChanged;

  static const double _segment = 32;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;

    return GestureDetector(
      onTap: () => onChanged(!isRaw),
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: _segment,
        decoration: BoxDecoration(
          color: cs.onSurface.withValues(alpha: 0.06),
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              left: isRaw ? _segment : 0,
              top: 0,
              bottom: 0,
              width: _segment,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: cs.primary,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _icon(context, Icons.visibility, active: !isRaw),
                _icon(context, Icons.code, active: isRaw),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _icon(BuildContext context, IconData icon, {required bool active}) =>
      SizedBox(
        width: _segment,
        child: Center(
          child: Icon(
            icon,
            size: 16,
            color: active ? context.cs.onPrimary : context.cs.onSurfaceVariant,
          ),
        ),
      );
}
