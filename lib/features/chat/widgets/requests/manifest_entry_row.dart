import 'package:flutter/material.dart';

import '../../../../core/llm/prompt/exact_lorebook_manifest.dart';
import '../../../../shared/theme/app_colors.dart';
import '../context_coverage/coverage_badges.dart';
import '../context_coverage/coverage_tone.dart';

/// One entry from a past turn's manifest — what was injected, where, and the
/// text as it was rendered into the prompt.
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
                            Flexible(
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
                            const SizedBox(width: 4),
                            CoverageBadge(
                              label: entry.source,
                              color: tone.vector,
                            ),
                            const Spacer(),
                            CoveragePositionBadge(position: entry.position),
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
                        Text(
                          '#${entry.injectionIndex + 1} · ${entry.classification}',
                          style: TextStyle(
                            fontSize: 10,
                            color: context.cs.onSurfaceVariant,
                          ),
                        ),
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
}
