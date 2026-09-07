import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../core/llm/lorebook_coverage.dart';
import '../../../../core/llm/tokenizer.dart';
import '../../../../shared/theme/app_colors.dart';
import 'coverage_badges.dart';
import 'coverage_reasons.dart';
import 'coverage_tone.dart';

/// One lorebook entry in a coverage list.
///
/// Collapsed it is a single line — status rail, title, token cost — so twenty
/// entries read as a scannable list instead of twenty stacked cards of key
/// chips. Everything else opens on tap: why the entry did or did not reach the
/// prompt, which keys fired, where they fired, the body text.
///
/// The verdict is deliberately *not* on the collapsed line. It used to be a row
/// of abbreviated pills there, which both squeezed the entry's name into an
/// ellipsis and had no room to say what the abbreviation meant; expanded, the
/// same verdict is a full sentence that wraps.
class CoverageEntryTile extends StatefulWidget {
  const CoverageEntryTile({super.key, required this.entry, this.dense = false});

  final CoverageEntry entry;

  /// Tighter paddings and no body preview — for the card under the chat header,
  /// which has far less room than the Prompt Inspector.
  final bool dense;

  @override
  State<CoverageEntryTile> createState() => _CoverageEntryTileState();
}

class _CoverageEntryTileState extends State<CoverageEntryTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final tone = CoverageTone.of(context);
    final statusColor = tone.forEntry(e);
    final subtitle = <String>[
      if (e.lorebookName.isNotEmpty) e.lorebookName,
      if (e.matchMessageIndex != null)
        'lorebook_matched_in_message'.tr(args: ['${e.matchMessageIndex! + 1}']),
    ].join(' · ');

    return Padding(
      padding: EdgeInsets.symmetric(vertical: widget.dense ? 1 : 2),
      child: Material(
        color: e.activated
            ? statusColor.withValues(alpha: 0.06)
            : context.cs.onSurface.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: statusColor),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      8,
                      widget.dense ? 5 : 7,
                      8,
                      widget.dense ? 5 : 7,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _titleRow(context, e),
                        if (subtitle.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: context.cs.onSurfaceVariant.withValues(
                                  alpha: 0.85,
                                ),
                              ),
                            ),
                          ),
                        if (_expanded) ..._details(context, e, tone),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleRow(BuildContext context, CoverageEntry e) {
    return Row(
      children: [
        Expanded(
          child: Text(
            e.comment.isNotEmpty ? e.comment : e.id,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: e.activated
                  ? context.cs.onSurface
                  : context.cs.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          'coverage_tokens_short'.tr(args: ['${estimateTokens(e.content)}']),
          style: TextStyle(fontSize: 10, color: context.cs.onSurfaceVariant),
        ),
        Icon(
          _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
          size: 16,
          color: context.cs.onSurfaceVariant,
        ),
      ],
    );
  }

  List<Widget> _details(
    BuildContext context,
    CoverageEntry e,
    CoverageTone tone,
  ) => [
    _reasons(context, e, tone.forEntry(e)),
    if (e.matchedKeys.isNotEmpty)
      _keyWrap(context, e.matchedKeys, tone.injected),
    if (e.matchedSecondaryKeys.isNotEmpty)
      _keyWrap(context, e.matchedSecondaryKeys, tone.vector),
    if (!widget.dense && e.content.isNotEmpty)
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          constraints: const BoxConstraints(maxHeight: 160),
          decoration: BoxDecoration(
            color: context.cs.onSurface.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(6),
          ),
          child: SingleChildScrollView(
            child: Text(
              e.content,
              style: TextStyle(
                fontSize: 11,
                height: 1.35,
                fontFamily: 'monospace',
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
  ];

  /// The verdict, spelled out: whether the entry reached the prompt, what cut
  /// it if it did not, and what qualifies it. Wraps freely — these are the
  /// sentences the collapsed line has no room for.
  Widget _reasons(BuildContext context, CoverageEntry e, Color statusColor) {
    final lines = lorebookCoverageReasons(e);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, line) in lines.indexed)
            Text(
              line,
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                fontWeight: index == 0 ? FontWeight.w600 : FontWeight.w400,
                color: index == 0 ? statusColor : context.cs.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _keyWrap(BuildContext context, List<String> keys, Color color) =>
      Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final key in keys) CoverageBadge(label: key, color: color),
          ],
        ),
      );
}
