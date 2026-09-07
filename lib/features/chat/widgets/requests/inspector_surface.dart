import 'package:flutter/material.dart';

import '../../../../shared/theme/app_colors.dart';

/// The plaque every Prompt Inspector surface is built on.
///
/// It speaks the app's Triggered Items card language (`triggered_items_sheet.
/// dart`, `style_library_sheet.dart`): a faint ink wash, a hairline of the same
/// ink, a 12 px radius and no shadow. It used to be the context card's shell —
/// a nearly opaque `surface` fill under a drop shadow — which read as a stack
/// of Material cards rather than as this app's own surface. An [accent] takes
/// the place of the card language's "active" state: it tints the hairline, the
/// way a selected style card is outlined in the theme's primary.
///
/// The wash is `onSurface`, not the literal `Colors.white` those two sheets
/// use, so the same card reads correctly on a light theme preset.
///
/// Unlike `GlassSurface` this paints no `BackdropFilter`, so it is safe per row
/// of a long list (`docs/UI_KIT.md` § Performance notes) — which is exactly
/// what the message list of a 200-message prompt is.
class InspectorPlaque extends StatelessWidget {
  const InspectorPlaque({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.margin,
    this.onTap,
    this.accent,
    this.radius = 12,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;

  /// Tints the hairline. The timeline colours a row by its stage family, a
  /// message card by its role, the budget bar by how full the window is; every
  /// other plaque leaves the hairline at the neutral ink.
  final Color? accent;

  final double radius;

  @override
  Widget build(BuildContext context) {
    final ink = context.cs.onSurface;
    final body = Padding(padding: padding, child: child);

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: ink.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: accent == null
              ? ink.withValues(alpha: 0.10)
              : accent!.withValues(alpha: 0.40),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      // Inside the decoration, not around it: an InkWell splashes on its
      // nearest Material ancestor, and a Material *outside* the opaque fill
      // paints every ripple behind it.
      child: Material(
        type: MaterialType.transparency,
        child: onTap == null ? body : InkWell(onTap: onTap, child: body),
      ),
    );
  }
}

/// The recessed box a plaque puts long, selectable text into — expanded message
/// content, a rendered lorebook entry, a JSON dump.
class InspectorTextBox extends StatelessWidget {
  const InspectorTextBox({
    super.key,
    required this.child,
    this.maxHeight = 300,
    this.padding = const EdgeInsets.all(8),
  });

  final Widget child;
  final double maxHeight;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: context.cs.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: SingleChildScrollView(child: child),
    );
  }
}

/// The label between blocks of a request — parameters, coverage, messages.
class InspectorSectionTitle extends StatelessWidget {
  const InspectorSectionTitle(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 0, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
