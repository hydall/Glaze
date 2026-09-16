import 'package:flutter/material.dart';

import '../../core/platform/haptics.dart';
import '../theme/app_colors.dart';
import 'glass_surface.dart';

/// The kit's disclosure row, for the places that would otherwise reach for
/// Material's `ExpansionTile`.
///
/// `ExpansionTile` brings its own `ListTile` geometry, its own divider colours
/// and a stock chevron that ignore the active theme preset, which is how the
/// diagnostics surfaces ended up looking like a different app. This is the same
/// interaction — a header that opens a body — drawn with the kit's surface,
/// colours and haptics.
///
/// [surface] draws the tile as a card of its own. Leave it false for a tile
/// that already sits inside a [GlassSurface] or a `MenuGroup`, so the two do
/// not stack into a card-in-a-card.
class GlazeExpansionTile extends StatefulWidget {
  final Widget title;
  final Widget? subtitle;

  /// Leading glyph. Kept as a widget so a row can tint its own icon by status.
  final Widget? leading;

  /// Extra control pinned before the chevron.
  final Widget? trailing;

  final List<Widget> children;
  final bool initiallyExpanded;

  /// Wraps the tile in its own glass card.
  final bool surface;

  final EdgeInsets childrenPadding;

  /// Drawn under the header when collapsed, and under the whole tile when
  /// open — for a tile that is one row of a list rather than a card.
  final bool showDivider;

  const GlazeExpansionTile({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.leading,
    this.trailing,
    this.initiallyExpanded = false,
    this.surface = false,
    this.childrenPadding = const EdgeInsets.fromLTRB(14, 0, 14, 12),
    this.showDivider = false,
  });

  @override
  State<GlazeExpansionTile> createState() => _GlazeExpansionTileState();
}

class _GlazeExpansionTileState extends State<GlazeExpansionTile> {
  late bool _expanded = widget.initiallyExpanded;

  void _toggle() {
    Haptics.selectionClick();
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: _toggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(
              children: [
                if (widget.leading case final leading?) ...[
                  leading,
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DefaultTextStyle.merge(
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: context.cs.onSurface,
                        ),
                        child: widget.title,
                      ),
                      if (widget.subtitle case final subtitle?) ...[
                        const SizedBox(height: 2),
                        DefaultTextStyle.merge(
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.3,
                            color: context.cs.onSurfaceVariant,
                          ),
                          child: subtitle,
                        ),
                      ],
                    ],
                  ),
                ),
                if (widget.trailing case final trailing?) ...[
                  const SizedBox(width: 8),
                  trailing,
                ],
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 22,
                    color: context.cs.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 180),
          firstCurve: Curves.easeOut,
          secondCurve: Curves.easeOut,
          sizeCurve: Curves.easeOut,
          crossFadeState: _expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: widget.childrenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: widget.children,
            ),
          ),
        ),
      ],
    );

    if (widget.surface) {
      return GlassSurface(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.cs.outlineVariant),
        child: body,
      );
    }
    if (!widget.showDivider) return body;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.cs.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: body,
    );
  }
}
