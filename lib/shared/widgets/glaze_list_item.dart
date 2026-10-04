import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The one row shape every preset/memory list uses.
///
/// Extracted from the prompt-preset list so the prompt manager, the API and
/// External Blocks preset switchers, the Memory Books rows and the Triggered
/// Items sheet all read as the same object: a rounded card, an optional
/// leading mark, a title with an optional inline badge, an optional subtitle,
/// and optional trailing actions — highlighted with the primary tint when the
/// row is active or picked.
class GlazeListItem extends StatelessWidget {
  /// Leading mark, usually a 32 px icon tile. Omitted when null.
  final Widget? leading;

  final String? title;

  /// Rich content used instead of [title]/[subtitle], for rows that need their
  /// own layout (the Memory Books rows). The card, padding and tap behaviour
  /// are still this widget's.
  final Widget? child;

  /// Inline mark shown at the end of the title line (a keyword/vector badge).
  final Widget? badge;

  final String? subtitle;

  /// Trailing actions or a chevron.
  final Widget? trailing;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// The row is the active/picked one: primary tint and border.
  final bool isActive;
  final bool selected;

  /// Overrides the idle border colour — the Memory Books rows tint their
  /// hairline by state, the way the Prompt Inspector does.
  final Color? accent;

  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry padding;
  final Key? titleKey;

  const GlazeListItem({
    super.key,
    this.leading,
    this.title,
    this.child,
    this.badge,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.isActive = false,
    this.selected = false,
    this.accent,
    this.margin = const EdgeInsets.only(bottom: 8),
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    this.titleKey,
  }) : assert(title != null || child != null, 'A row needs a title or a child');

  @override
  Widget build(BuildContext context) {
    final highlighted = selected || isActive;
    final idleBorder = accent ?? context.cs.outlineVariant;

    final content = child != null
        ? child!
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      title!,
                      key: titleKey,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: context.cs.onSurface,
                      ),
                    ),
                  ),
                  ?badge,
                ],
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          );

    return Padding(
      padding: margin,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: highlighted
                  ? context.cs.primary.withValues(alpha: 0.14)
                  : context.cs.onSurface.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: highlighted
                    ? context.cs.primary.withValues(alpha: 0.4)
                    : idleBorder,
              ),
            ),
            padding: padding,
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
                Expanded(child: content),
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The standard 32 px leading tile of a [GlazeListItem] — a tinted rounded
/// square holding one glyph.
class GlazeListIcon extends StatelessWidget {
  final IconData icon;
  final Color? color;

  const GlazeListIcon({super.key, required this.icon, this.color});

  @override
  Widget build(BuildContext context) {
    final tint = color ?? context.cs.primary;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 18, color: tint),
    );
  }
}

/// The standard trailing "⋯" of a [GlazeListItem]. Runs [onTap] in place.
class GlazeListMenuButton extends StatelessWidget {
  final VoidCallback onTap;
  final String tooltip;

  const GlazeListMenuButton({
    super.key,
    required this.onTap,
    this.tooltip = '',
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(
              Icons.more_vert_rounded,
              size: 18,
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
