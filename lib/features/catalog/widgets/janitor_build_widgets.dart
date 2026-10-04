import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/llm/tokenizer.dart';
import '../../../core/platform/haptics.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_spinner.dart';

/// One context source in the "context sent for key inference" group.
///
/// Mirrors JAR's `.ctx-block`: a row that both toggles whether the source is
/// sent to the build LLM *and* opens to show the exact text that would be sent,
/// with its token count. A source with no content cannot be sent, so it is
/// shown disabled and does not open.
///
/// Styled to match [MenuSwitchItem] so a run of these reads as one menu group.
class ContextSourceTile extends StatefulWidget {
  final String label;

  /// The text this source contributes. Empty disables the row.
  final String content;

  /// Shown in place of the token count when [content] is empty for a reason
  /// worth naming (the card is only recovered during the capture).
  final String? emptyNote;

  /// The content does not exist yet but will by the time it is sent, so the row
  /// stays selectable while empty. The character card before a capture is the
  /// case this exists for — JAR keeps its checkbox live for the same reason.
  final bool pending;

  final bool value;
  final ValueChanged<bool> onChanged;

  const ContextSourceTile({
    super.key,
    required this.label,
    required this.content,
    required this.value,
    required this.onChanged,
    this.emptyNote,
    this.pending = false,
  });

  @override
  State<ContextSourceTile> createState() => _ContextSourceTileState();
}

class _ContextSourceTileState extends State<ContextSourceTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final text = widget.content.trim();
    final empty = text.isEmpty;
    // Nothing to reveal while empty; selectable anyway when the content is
    // still on its way.
    final locked = empty && !widget.pending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: empty
              ? null
              : () {
                  Haptics.selectionClick();
                  setState(() => _open = !_open);
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.label,
                        style: TextStyle(
                          color: locked
                              ? cs.onSurfaceVariant.withValues(alpha: 0.5)
                              : cs.onSurfaceVariant,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        empty
                            ? (widget.emptyNote ?? 'catalog_ctx_empty'.tr())
                            : 'catalog_ctx_tokens'.tr(
                                args: ['${estimateTokens(text)}'],
                              ),
                        style: const TextStyle(
                          color: Color(0xFF99A2AD),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!empty)
                  Icon(
                    _open
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                const SizedBox(width: 8),
                Switch(
                  value: widget.value && !locked,
                  onChanged: locked
                      ? null
                      : (v) {
                          Haptics.selectionClick();
                          widget.onChanged(v);
                        },
                  activeThumbColor: cs.primary,
                  activeTrackColor: cs.primary.withValues(alpha: 0.5),
                  trackOutlineColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.selected)
                        ? Colors.transparent
                        : cs.outlineVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open && !empty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: ContentPane(text: text),
          ),
      ],
    );
  }
}

/// A menu row that opens to show [content] — no toggle, just a look at what was
/// recovered. Mirrors JAR's "extracted content" `<details>` block.
class DisclosureRow extends StatefulWidget {
  final String label;
  final String? subtitle;
  final String content;
  final bool initiallyOpen;

  const DisclosureRow({
    super.key,
    required this.label,
    required this.content,
    this.subtitle,
    this.initiallyOpen = false,
  });

  @override
  State<DisclosureRow> createState() => _DisclosureRowState();
}

class _DisclosureRowState extends State<DisclosureRow> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final text = widget.content.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: text.isEmpty
              ? null
              : () {
                  Haptics.selectionClick();
                  setState(() => _open = !_open);
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.label,
                        style: TextStyle(
                          fontSize: 16,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      if (widget.subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle!,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (text.isNotEmpty)
                  Icon(
                    _open
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
        if (_open && text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: ContentPane(text: text, maxHeight: 220),
          ),
      ],
    );
  }
}

/// Scrollable read-only pane for text a row reveals (a context source's exact
/// content, a prompt preview, a JSON dump).
class ContentPane extends StatelessWidget {
  final String text;
  final double maxHeight;
  final bool mono;

  const ContentPane({
    super.key,
    required this.text,
    this.maxHeight = 180,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxHeight),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          text,
          style: TextStyle(
            fontSize: 11,
            height: 1.4,
            fontFamily: mono ? 'monospace' : null,
            color: cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// An action rendered the Glaze way — a [GlassSurface] tile rather than a
/// Material button ([docs/UI_KIT.md]: "a tile built on GlassSurface *is* the
/// button"). [primary] tints it with the accent colour; [busy] swaps the icon
/// for a spinner and blocks the tap.
class ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool busy;

  /// Fill the available width and centre the content — for a section's single
  /// main action, rather than one chip among several.
  final bool expand;

  /// Pill-sized, for a per-row action that has to sit inside a list row
  /// (a menu row's trailing slot) without out-weighing the row itself.
  final bool compact;

  const ActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.busy = false,
    this.expand = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final enabled = onTap != null && !busy;
    final accent = primary ? cs.primary : cs.onSurfaceVariant;
    final fg = enabled ? accent : accent.withValues(alpha: 0.4);
    return GlassSurface(
      borderRadius: BorderRadius.circular(compact ? 14 : 20),
      enableRipple: enabled,
      tint: primary ? cs.primary.withValues(alpha: 0.15) : null,
      border: Border.all(
        color: primary
            ? cs.primary.withValues(alpha: 0.3)
            : cs.outlineVariant,
      ),
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment:
              expand ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            if (busy)
              SizedBox(
                width: compact ? 13 : 16,
                height: compact ? 13 : 16,
                child: GlazeSpinner(color: fg),
              )
            else
              Icon(icon, size: compact ? 14 : 16, color: fg),
            SizedBox(width: compact ? 6 : 8),
            Text(
              label,
              style: TextStyle(
                fontSize: compact ? 12 : 13,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
