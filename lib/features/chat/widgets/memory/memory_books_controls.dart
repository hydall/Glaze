import 'package:flutter/material.dart';

import '../../../../core/platform/haptics.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glass_surface.dart';
import '../../../../shared/widgets/glaze_bottom_sheet.dart';
import '../requests/inspector_surface.dart';

/// Shared Glaze-styled building blocks for the memory-books sheet.
///
/// They replace the Material `OutlinedButton` / `FilledButton` / `FilterChip` /
/// `TextButton` widgets the sheet used before, so it renders with the same
/// glass surfaces, pills and ripples as the rest of the app.

/// Small colour-coded pill used for status markers on cards.
class MemoryPill extends StatelessWidget {
  final String label;
  final Color color;

  /// Leading glyph. A state pill reads at a glance from its shape as much as
  /// from its word, and the glyph is what survives when the word is long.
  final IconData? icon;

  final double fontSize;
  final EdgeInsetsGeometry padding;

  const MemoryPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.fontSize = 11,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  });

  @override
  Widget build(BuildContext context) {
    final glyph = icon;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (glyph != null) ...[
            Icon(glyph, size: fontSize + 2, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Icon + label tile used for the sheet's toolbar actions. Takes the place of
/// the Material outlined/filled buttons the sheet used to lay out in rows.
class MemoryActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// Colour of the icon, the label and the ripple. Defaults to the theme's
  /// `onSurface` for the label and `onSurfaceVariant` for the icon.
  final Color? accent;

  /// Renders the tile as the emphasised (primary-tinted) action.
  final bool emphasised;

  const MemoryActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent,
    this.emphasised = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final base = accent ?? (emphasised ? context.cs.primary : null);
    final iconColor = base ?? context.cs.onSurfaceVariant;
    final labelColor = base ?? context.cs.onSurface;
    final radius = BorderRadius.circular(14);

    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: GlassSurface(
        borderRadius: radius,
        tint: emphasised ? context.cs.primary.withValues(alpha: 0.18) : null,
        border: Border.all(
          color: base != null
              ? base.withValues(alpha: 0.3)
              : context.cs.outlineVariant,
        ),
        onTap: onTap,
        glowColor: base ?? context.cs.primary,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 8),
              // Flexible + ellipsis so a long localized label degrades
              // instead of overflowing its tile.
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: labelColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The shared shell for one entry or draft in the list.
///
/// The Prompt Inspector's plaque, so a memory reads as the same kind of object
/// as a prompt message or a coverage row: a faint ink wash, a hairline of the
/// same ink, 12 px radius, no shadow. [accent] tints the hairline by state, the
/// way the inspector tints a message card by role.
///
/// It paints no `BackdropFilter`, so unlike a [GlassSurface] it is safe once
/// per row of a long list (`docs/UI_KIT.md` § Performance notes).
class MemoryRow extends StatelessWidget {
  final Widget child;
  final Color? accent;
  final VoidCallback? onTap;

  const MemoryRow({super.key, required this.child, this.accent, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InspectorPlaque(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
      accent: accent,
      onTap: onTap == null
          ? null
          : () {
              Haptics.selectionClick();
              onTap!();
            },
      child: child,
    );
  }
}

/// A status glyph on a row — what a one-word pill used to say.
///
/// `idx` was a three-letter token no screen reader and no non-English speaker
/// could resolve. The glyph carries a tooltip and a semantics label instead.
class MemoryStatusIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const MemoryStatusIcon({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: Icon(icon, size: 15, color: color),
      ),
    );
  }
}

/// The round glass button the chat input bar uses — every icon action in the
/// memory sheet, from the header's settings button to a draft row's Approve.
///
/// Was a tinted rounded square per action, which read as its own small widget
/// family sitting next to the app's actual buttons. Same 40 px circle, surface
/// tint and hairline as the composer's controls; only the glyph carries the
/// semantic colour.
class MemoryCircleButton extends StatelessWidget {
  final IconData icon;

  /// Tooltip and semantics label — what a text chip used to spell out.
  final String label;

  final VoidCallback onTap;

  /// Glyph colour. Defaults to the theme's primary, the way the composer's
  /// buttons are; a destructive or state-bearing action passes its own.
  final Color? color;

  const MemoryCircleButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        child: SizedBox(
          width: 40,
          height: 40,
          child: GlassSurface(
            borderRadius: BorderRadius.circular(20),
            tint: context.cs.surface,
            border: Border.all(color: context.cs.outlineVariant),
            onTap: () {
              Haptics.selectionClick();
              onTap();
            },
            glowColor: context.cs.primary,
            child: Center(
              child: Icon(icon, size: 20, color: color ?? context.cs.primary),
            ),
          ),
        ),
      ),
    );
  }
}

/// The trailing "⋯" of a row: the actions that are not the row's primary tap.
///
/// Keeping Edit/Delete here instead of as permanent chips takes two tinted
/// chips out of the tree per entry, which is what made the old list expensive
/// to build.
class MemoryRowMenuButton extends StatelessWidget {
  final List<BottomSheetItem> Function(BuildContext context) itemsBuilder;
  final String title;

  const MemoryRowMenuButton({
    super.key,
    required this.itemsBuilder,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      // No padding of its own: the plaque already insets its right edge, and
      // stacking both pushed the glyph a third of the way off the optical
      // margin the left edge sets.
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      iconSize: 18,
      color: context.cs.onSurfaceVariant,
      tooltip: title,
      icon: const Icon(Icons.more_horiz_rounded),
      onPressed: () {
        Haptics.selectionClick();
        GlazeBottomSheet.show<void>(
          context,
          title: title,
          items: itemsBuilder(context),
        );
      },
    );
  }
}
