import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'glass_surface.dart';
import '../theme/ui_scale.dart';

/// Selection bar shown while a list is multi-selecting (presets, regex scripts). Mirrors the chat's
/// message-selection bar: a glass pill with a cancel button, the selected
/// count, and a "more" button that opens the bulk-actions sheet.
///
/// [compact] is the desktop form that stands in for the header's controls row:
/// the same buttons at the row's 32 px height, without the pill around them,
/// so swapping the two leaves the list where it was.
class GlazeSelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onCancel;
  final VoidCallback onMore;
  final bool compact;

  const GlazeSelectionBar({
    super.key,
    required this.count,
    required this.onCancel,
    required this.onMore,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return GlassBackdropGroup(
        child: Row(
          children: [
            _CircleIconBtn(
              icon: Icons.close_rounded,
              onTap: onCancel,
              size: 32,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '$count ${'selected_count'.tr()}',
                style: TextStyle(
                  color: context.cs.onSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _CircleIconBtn(
              icon: Icons.more_horiz_rounded,
              onTap: count > 0 ? onMore : null,
              size: 32,
            ),
          ],
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      elevation: 0,
      borderRadius: context.glazeBorderRadius(28),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(28),
        tint: context.cs.surface,
        border: Border.all(color: context.cs.primary.withValues(alpha: 0.18)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              const SizedBox(width: 8),
              _CircleIconBtn(icon: Icons.close_rounded, onTap: onCancel),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '$count ${'selected_count'.tr()}',
                  style: TextStyle(
                    color: context.cs.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _CircleIconBtn(
                icon: Icons.more_horiz_rounded,
                onTap: count > 0 ? onMore : null,
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;

  const _CircleIconBtn({required this.icon, this.onTap, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: GlassSurface(
            borderRadius: BorderRadius.circular(size / 2),
            tint: context.cs.surface,
            border: Border.all(
              color: context.cs.primary.withValues(alpha: 0.18),
            ),
            child: Center(
              child: Icon(
                icon,
                size: 20,
                color: onTap != null
                    ? context.cs.primary
                    : context.cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
