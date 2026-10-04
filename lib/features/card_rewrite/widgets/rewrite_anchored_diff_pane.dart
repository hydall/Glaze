import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/services/card_rewriter/card_rewriter_contracts.dart';
import '../../../shared/theme/app_colors.dart';
import '../../chat/widgets/post_cleaner_line_diff.dart';

/// Renders one anchored patch as a compact Current/Proposed diff.
///
/// The anchor is located in the CURRENT field value (exactly-once, per the
/// anchored-patch contract); only a small context window around it is shown.
/// When the anchor no longer matches exactly once (the card moved since
/// generation), the pane degrades honestly: it shows the stored target
/// fragment instead of a fabricated diff.
class RewriteAnchoredDiffPane extends StatelessWidget {
  const RewriteAnchoredDiffPane({
    super.key,
    required this.patch,
    required this.fieldValue,
    this.onDelete,
  });

  final AnchoredScalarPatch patch;

  /// Current value of the operation's target field; null while loading.
  final String? fieldValue;
  final VoidCallback? onDelete;

  RewriteAnchoredDiffPane.lorebook({
    super.key,
    required LorebookAnchoredPatch patch,
    required this.fieldValue,
  }) : onDelete = null,
       patch = AnchoredScalarPatch(
         scopeKey: 'world:lorebook',
         field: CardRewriteField.description,
         anchor: patch.anchor,
         anchorSha256: patch.anchorSha256,
         value: patch.value,
       );

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final current = fieldValue;
    if (current == null) return const _SkeletonPane();

    final occurrences = _occurrences(current, patch.anchor);
    if (occurrences != 1) {
      return _AnchorMissingPane(
        anchor: patch.anchor,
        ambiguous: occurrences > 1,
      );
    }
    final start = current.indexOf(patch.anchor);
    final end = start + patch.anchor.length;
    final window = _contextWindow(current, start, end);
    final left =
        '${window.prefixEllipsis ? '…\n' : ''}${window.before}${patch.anchor}${window.after}${window.suffixEllipsis ? '\n…' : ''}';
    final right =
        '${window.prefixEllipsis ? '…\n' : ''}${window.before}${patch.value}${window.after}${window.suffixEllipsis ? '\n…' : ''}';
    final diff = computeLineDiff(left, right);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Half(
            label: 'rewrite_diff_current'.tr(),
            accent: cs.onSurfaceVariant,
            lines: diff.leftLines,
          ),
          Divider(height: 1, color: cs.outlineVariant),
          _Half(
            label: 'rewrite_diff_proposed'.tr(),
            accent: cs.primary,
            lines: diff.rightLines,
            onDelete: onDelete,
          ),
        ],
      ),
    );
  }

  static int _occurrences(String value, String anchor) {
    if (anchor.isEmpty) return 0;
    var count = 0;
    var from = 0;
    while (true) {
      final index = value.indexOf(anchor, from);
      if (index == -1) return count;
      count++;
      from = index + anchor.length;
    }
  }

  /// Expands [start]..[end] by up to two whole lines of surrounding context.
  static _Window _contextWindow(
    String text,
    int start,
    int end, {
    int contextLines = 2,
  }) {
    var winStart = start;
    var lines = 0;
    while (winStart > 0 && lines < contextLines) {
      final nl = text.lastIndexOf('\n', winStart - 1);
      if (nl == -1) {
        winStart = 0;
        break;
      }
      winStart = nl + 1;
      lines++;
    }
    var winEnd = end;
    lines = 0;
    while (winEnd < text.length && lines < contextLines) {
      final nl = text.indexOf('\n', winEnd);
      if (nl == -1) {
        winEnd = text.length;
        break;
      }
      winEnd = nl + 1;
      lines++;
    }
    return _Window(
      before: text.substring(winStart, start),
      after: text.substring(end, winEnd),
      prefixEllipsis: winStart > 0,
      suffixEllipsis: winEnd < text.length,
    );
  }
}

class _Window {
  const _Window({
    required this.before,
    required this.after,
    required this.prefixEllipsis,
    required this.suffixEllipsis,
  });

  final String before;
  final String after;
  final bool prefixEllipsis;
  final bool suffixEllipsis;
}

class _Half extends StatelessWidget {
  const _Half({
    required this.label,
    required this.accent,
    required this.lines,
    this.onDelete,
  });

  final String label;
  final Color accent;
  final List<DiffLine> lines;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.label_outline, size: 13, color: accent),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: accent,
                  letterSpacing: 0.4,
                ),
              ),
              if (onDelete != null) ...[
                const Spacer(),
                IconButton(
                  key: const Key('rewrite-delete-patch-button'),
                  tooltip: 'rewrite_delete_patch'.tr(),
                  visualDensity: VisualDensity.compact,
                  onPressed: onDelete,
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 17,
                    color: context.cs.error,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          for (final line in lines) _DiffLineView(line: line),
        ],
      ),
    );
  }
}

class _DiffLineView extends StatelessWidget {
  const _DiffLineView({required this.line});

  final DiffLine line;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final Color bg;
    final Color fg;
    final String prefix;
    switch (line.type) {
      case DiffLineType.removed:
        bg = Colors.red.withValues(alpha: 0.12);
        fg = cs.error;
        prefix = '− ';
      case DiffLineType.added:
        bg = Colors.green.withValues(alpha: 0.12);
        fg = Colors.green.shade700;
        prefix = '+ ';
      case DiffLineType.same:
        bg = Colors.transparent;
        fg = cs.onSurfaceVariant;
        prefix = '  ';
    }
    final changedWordBg = line.type == DiffLineType.removed
        ? Colors.red.withValues(alpha: 0.32)
        : Colors.green.withValues(alpha: 0.32);

    final spans = <TextSpan>[
      TextSpan(
        text: prefix,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: fg.withValues(alpha: 0.55),
        ),
      ),
    ];
    final words = line.words;
    if (words != null && words.isNotEmpty) {
      for (var i = 0; i < words.length; i++) {
        final word = words[i];
        if (i > 0 && word.text.isNotEmpty) {
          spans.add(
            TextSpan(
              text: ' ',
              style: TextStyle(color: fg),
            ),
          );
        }
        spans.add(
          TextSpan(
            text: word.text,
            style: TextStyle(
              color: fg,
              backgroundColor: word.isChanged ? changedWordBg : null,
            ),
          ),
        );
      }
    } else {
      spans.add(
        TextSpan(
          text: line.text,
          style: TextStyle(color: fg),
        ),
      );
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 1),
      color: bg,
      child: Text.rich(
        TextSpan(
          children: spans,
          style: const TextStyle(fontSize: 12, height: 1.5),
        ),
      ),
    );
  }
}

class _SkeletonPane extends StatelessWidget {
  const _SkeletonPane();

  @override
  Widget build(BuildContext context) {
    final barColor = context.cs.onSurface.withValues(alpha: 0.08);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              height: 10,
              width: i == 2 ? 120 : double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: barColor,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
        ],
      ),
    );
  }
}

class _AnchorMissingPane extends StatelessWidget {
  const _AnchorMissingPane({required this.anchor, required this.ambiguous});

  final String anchor;
  final bool ambiguous;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.error.withValues(alpha: 0.4)),
        color: cs.error.withValues(alpha: 0.06),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.search_off_rounded, size: 15, color: cs.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  ambiguous
                      ? 'rewrite_anchor_ambiguous'.tr()
                      : 'rewrite_anchor_missing'.tr(),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.error,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 160),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: cs.onSurface.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              child: Text(
                anchor,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.45,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
