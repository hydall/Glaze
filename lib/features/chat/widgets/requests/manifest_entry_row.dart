import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../core/llm/prompt/exact_lorebook_manifest.dart';
import '../../../../shared/theme/app_colors.dart';
import '../context_coverage/coverage_reasons.dart';
import '../context_coverage/coverage_tone.dart';

/// One entry from a past turn's manifest — what was injected, where, and the
/// text as it was rendered into the prompt.
///
/// The line carries the entry's name and nothing else; how it got into the
/// prompt (what activated it, where it landed, in what order) is spelled out in
/// full sentences when the row is opened. The raw manifest codes — `keyword`,
/// `worldInfoAfter` — used to be printed on the line verbatim, untranslated and
/// clipped.
class ManifestEntryRow extends StatefulWidget {
  const ManifestEntryRow({super.key, required this.entry});

  final ExactLorebookManifestEntry entry;

  @override
  State<ManifestEntryRow> createState() => _ManifestEntryRowState();
}

class _ManifestEntryRowState extends State<ManifestEntryRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final tone = CoverageTone.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: tone.injected.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: tone.injected),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                entry.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: context.cs.onSurface,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              _expanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 16,
                              color: context.cs.onSurfaceVariant,
                            ),
                          ],
                        ),
                        if (_expanded) _provenance(context, entry, tone),
                        if (_expanded)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(8),
                              constraints: const BoxConstraints(maxHeight: 200),
                              decoration: BoxDecoration(
                                color: context.cs.onSurface.withValues(
                                  alpha: 0.04,
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: SingleChildScrollView(
                                child: SelectableText(
                                  entry.renderedContent.isEmpty
                                      ? entry.rawContent
                                      : entry.renderedContent,
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

  /// How the entry reached the prompt, in full sentences: what activated it,
  /// where it was placed, and its order among the injected entries.
  Widget _provenance(
    BuildContext context,
    ExactLorebookManifestEntry entry,
    CoverageTone tone,
  ) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'coverage_manifest_source'.tr(
            args: [manifestSourceLabel(entry.source)],
          ),
          style: TextStyle(
            fontSize: 11,
            height: 1.3,
            fontWeight: FontWeight.w600,
            color: tone.injected,
          ),
        ),
        Text(
          'coverage_lore_position'.tr(
            args: [coveragePositionLabel(entry.classification)],
          ),
          style: TextStyle(
            fontSize: 11,
            height: 1.3,
            color: context.cs.onSurfaceVariant,
          ),
        ),
        Text(
          'coverage_manifest_order'.tr(args: ['${entry.injectionIndex + 1}']),
          style: TextStyle(
            fontSize: 11,
            height: 1.3,
            color: context.cs.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}
