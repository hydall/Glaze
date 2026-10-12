import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'glaze_spinner.dart';

/// Glaze's floating action button: a 56pt accent circle that lifts off the
/// list on a soft shadow, with a hairline highlight so it reads on both dark
/// and light themes. Given a [label] it stretches into a pill of the same
/// height — the extended FAB for when the icon alone wouldn't say enough.
///
/// The glyph picks black or white against the accent, so a pale accent keeps
/// a dark plus and a deep one keeps a light plus.
class GlazeFab extends StatelessWidget {
  final IconData icon;
  final String? label;
  final String tooltip;

  /// Null, or [busy], disables the button and fades it.
  final VoidCallback? onTap;

  /// Swaps the icon for a spinner while the action runs.
  final bool busy;

  const GlazeFab({
    super.key,
    required this.tooltip,
    required this.onTap,
    this.icon = Icons.add_rounded,
    this.label,
    this.busy = false,
  });

  static const double _height = 56;

  @override
  Widget build(BuildContext context) {
    final accent = context.cs.primary;
    final glyph =
        ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
        ? Colors.white
        : Colors.black;
    final enabled = onTap != null && !busy;
    final shape = label == null
        ? CircleBorder(
            side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
          )
        : StadiumBorder(
            side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
          );

    final leading = busy
        ? SizedBox.square(
            dimension: 22,
            child: GlazeSpinner(color: glyph, glow: false),
          )
        : Icon(icon, size: label == null ? 28 : 22, color: glyph);

    final content = label == null
        ? SizedBox.square(dimension: _height, child: Center(child: leading))
        : SizedBox(
            height: _height,
            child: Padding(
              padding: const EdgeInsets.only(left: 18, right: 22),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  leading,
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      label!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: glyph,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );

    return Tooltip(
      message: tooltip,
      child: AnimatedOpacity(
        opacity: enabled || busy ? 1 : 0.5,
        duration: const Duration(milliseconds: 150),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: shape,
            shadows: [
              // A wide, soft drop that pools under the whole button, then an
              // accent bloom around it so it glows rather than outlines.
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.55),
                blurRadius: 28,
                spreadRadius: 2,
                offset: const Offset(0, 10),
              ),
              BoxShadow(
                color: accent.withValues(alpha: 0.4),
                blurRadius: 24,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Material(
            color: busy ? accent.withValues(alpha: 0.7) : accent,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
              onTap: enabled ? onTap : null,
              splashColor: glyph.withValues(alpha: 0.15),
              highlightColor: glyph.withValues(alpha: 0.08),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
