import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'glass_surface.dart';
import 'glaze_spinner.dart';

/// How prominent a [GlazeActionButton] is, and what it is about to do.
enum GlazeActionTone {
  /// The one action a surface exists for — a filled accent tile.
  primary,

  /// Everything else: an outlined tile that reads as secondary next to a
  /// [GlazeActionTone.primary] one.
  neutral,

  /// Deletes or discards. Outlined like [neutral], in the error colour.
  destructive,
}

/// The kit's button, for the places that would otherwise reach for
/// `FilledButton` / `OutlinedButton`.
///
/// There is no generic Material button in Glaze — a tile built on
/// [GlassSurface] *is* the button — but a diagnostics surface with a run
/// action, a retry and a delete needs all three to be the same control rather
/// than three hand-rolled tiles. Hence this one widget, with [tone] choosing
/// the weight.
///
/// A null [onTap] renders the disabled state: the surface dims and the tap is
/// dropped. [busy] swaps the glyph for a spinner and disables the tap on its
/// own, so a caller does not have to null the handler while work is in flight.
class GlazeActionButton extends StatelessWidget {
  final IconData icon;
  final String label;

  /// Null disables the button.
  final VoidCallback? onTap;

  final GlazeActionTone tone;

  /// Shows a spinner in place of [icon] and ignores taps.
  final bool busy;

  /// Fills the available width instead of hugging the label — for the single
  /// primary action of a tab, which reads as a bar rather than a chip.
  final bool expand;

  const GlazeActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.tone = GlazeActionTone.neutral,
    this.busy = false,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    final accent = switch (tone) {
      GlazeActionTone.primary => context.cs.primary,
      GlazeActionTone.neutral => context.cs.onSurface,
      GlazeActionTone.destructive => context.cs.error,
    };
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox.square(
            dimension: 16,
            child: busy
                ? const GlazeSpinner()
                : Icon(icon, size: 16, color: accent),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
          ),
        ],
      ),
    );
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: GlassSurface(
        borderRadius: BorderRadius.circular(14),
        tint: tone == GlazeActionTone.primary
            ? context.cs.primary.withValues(alpha: 0.18)
            : context.cs.surface,
        border: Border.all(color: accent.withValues(alpha: 0.22)),
        onTap: enabled ? onTap : null,
        child: content,
      ),
    );
  }
}
