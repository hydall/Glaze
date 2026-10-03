import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import 'action_glyph.dart';

/// Height of a list row, and of a row of the desktop strip the list shrinks to
/// when a card is opened (see [MagicDrawerStripIcon.height]): equal, so every
/// icon stays where the list drew it.
const double kMagicDrawerRowHeight = 52;

/// Left inset of a list row's icon. The same as the gap the desktop strip
/// leaves around its 28px icon in a 64px rail, so a card's icon stays put when
/// opening it shrinks the list down to the strip.
const double _kRowIconInset = 18;

/// Width of the accent along a row's left edge in edit mode.
const double _kEditAccentWidth = 2;

/// One card of the chat drawer as a full-width list row — the desktop right
/// sidebar's layout, Vue's `.magic-drawer-sidebar .magic-item`.
///
/// A tinted 28px square with the card's mark, then its label over its status,
/// on a hairline bottom rule. [trailing] takes edit mode's badge, inline at the
/// row's end rather than hanging off a corner the way it does on a grid card.
class MagicDrawerListRow extends StatefulWidget {
  final IconData icon;

  /// See [ActionGlyph.glyph].
  final String? glyph;
  final String label;
  final String? status;

  /// Edit mode: the row takes the accent along its edge, as a grid card takes
  /// it on its border.
  final bool editing;

  /// Another card is being dragged over this one, and dropping it here would
  /// move it to this place.
  final bool hovered;
  final VoidCallback onTap;
  final Widget? trailing;

  /// Draws the mark fainter — for the add row, which is not a card.
  final bool muted;

  const MagicDrawerListRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.glyph,
    this.status,
    this.editing = false,
    this.hovered = false,
    this.trailing,
    this.muted = false,
  });

  @override
  State<MagicDrawerListRow> createState() => _MagicDrawerListRowState();
}

class _MagicDrawerListRowState extends State<MagicDrawerListRow> {
  bool _pointerOver = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final tint = widget.hovered
        ? context.cs.primary.withValues(alpha: 0.12)
        : Colors.white.withValues(
            alpha: _pressed
                ? 0.08
                : _pointerOver
                ? 0.04
                : 0,
          );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _pointerOver = true),
      onExit: (_) => setState(() => _pointerOver = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          // A fixed height with the content centred, as in a strip row, so the
          // icon's place does not depend on whether the card has a status line.
          height: kMagicDrawerRowHeight,
          alignment: Alignment.centerLeft,
          // The edit accent's width comes off the inset, and the accent is
          // always there (transparent at rest), so toggling edit mode never
          // shifts the row's content.
          padding: const EdgeInsets.fromLTRB(
            _kRowIconInset - _kEditAccentWidth,
            0,
            12,
            0,
          ),
          decoration: BoxDecoration(
            color: tint,
            border: Border(
              left: BorderSide(
                width: _kEditAccentWidth,
                color: widget.editing
                    ? context.cs.primary.withValues(alpha: 0.55)
                    : Colors.transparent,
              ),
              bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(
                    alpha: widget.muted ? 0.05 : 0.1,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ActionGlyph(
                  icon: widget.icon,
                  glyph: widget.glyph,
                  size: 18,
                  color: Colors.white.withValues(
                    alpha: widget.muted ? 0.6 : 0.8,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: context.cs.onSurface,
                        height: 1.2,
                      ),
                    ),
                    if (status != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.cs.onSurfaceVariant,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 8),
                widget.trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
