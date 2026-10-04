import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../state/lorebook_coverage_provider.dart';
import '../state/memory_activity_provider.dart';
import 'context_coverage/coverage_header_pill.dart';
import 'context_coverage/coverage_tone.dart';
import 'context_coverage/lorebook_coverage_section.dart';
import 'memory_activity_section.dart';
import 'prompt_inspector_sheet.dart';

/// Breathing room between the chat header and the card.
///
/// The card used to sit flush against the header's bottom edge, which read as
/// one two-storey header rather than a panel the header happens to sit above —
/// and left its rounded top corners with nothing to round against.
const double kContextCardHeaderGap = 8.0;

/// The panel under the chat header: what the next prompt is actually
/// carrying from the two retrieval layers.
///
/// It used to be the memory-only activity card, which answered half the
/// question — the other half (which lorebook entries fired, and which were cut)
/// was three taps away in the Prompt Inspector. Both layers answer "why is this
/// in my prompt?", so they share one surface, one collapsed line and one
/// expanded body with a tab per layer.
///
/// Collapsed it is a single row of counters. That is the state it is in almost
/// always, and it is what the header gap is sized for.
class ContextCoverageCard extends ConsumerStatefulWidget {
  const ContextCoverageCard({
    super.key,
    required this.charId,
    required this.expanded,
    required this.onToggle,
    this.memory,
    this.sessionId,
  });

  final String charId;
  final bool expanded;
  final VoidCallback onToggle;

  /// Null when memory books are off or the session has no memory run yet — the
  /// card then shows the lorebook layer alone, with no tab strip.
  final MemoryActivityState? memory;
  final String? sessionId;

  @override
  ConsumerState<ContextCoverageCard> createState() =>
      _ContextCoverageCardState();
}

enum _Layer { memory, lorebook }

class _ContextCoverageCardState extends ConsumerState<ContextCoverageCard> {
  _Layer _layer = _Layer.memory;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final tone = CoverageTone.of(context);
    final memory = widget.memory;
    final summary = memory == null ? null : MemoryActivitySummary.of(memory);
    final coverage = ref.watch(lorebookCoverageProvider(widget.charId)).value;

    final layers = <_Layer>[
      if (memory != null) _Layer.memory,
      _Layer.lorebook,
    ];
    final active = layers.contains(_layer) ? _layer : layers.first;

    return Container(
      decoration: BoxDecoration(
        // Matches the sibling status cards (see [ChatStatusCardShell]): these
        // float over the chat WebView, where a Flutter backdrop blur has
        // nothing to sample, so the surface is painted nearly opaque instead.
        color: cs.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.primary.withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.24),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      // Inside the decoration, not around it: an InkWell splashes on its
      // nearest Material ancestor, and a Material *outside* the opaque fill
      // paints every ripple behind it.
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: widget.onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                child: Row(
                  children: [
                    Icon(Icons.layers_outlined, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      'coverage_card_title'.tr(),
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    if (summary != null) ...[
                      CoverageHeaderPill(
                        icon: Icons.psychology_alt_outlined,
                        value: '${summary.selectedCount}',
                        total: '${summary.totalCandidates}',
                        color: summary.macroMissing
                            ? tone.cutOff
                            : cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (coverage != null)
                      CoverageHeaderPill(
                        icon: Icons.menu_book_outlined,
                        value: '${coverage.injectedCount}',
                        total: '${coverage.totalCandidates}',
                        color: coverage.cutOffCount > 0
                            ? tone.cutOff
                            : cs.onSurfaceVariant,
                      ),
                    const SizedBox(width: 2),
                    Icon(
                      widget.expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: cs.onSurfaceVariant,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
            if (widget.expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _toolbar(context, layers, active),
                    const SizedBox(height: 10),
                    if (active == _Layer.memory && memory != null)
                      MemoryActivitySection(
                        activity: memory,
                        sessionId: widget.sessionId,
                      )
                    else
                      LorebookCoverageSection(charId: widget.charId),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(
    BuildContext context,
    List<_Layer> layers,
    _Layer active,
  ) => Row(
    children: [
      if (layers.length > 1)
        Expanded(
          child: GlazeTabBar(
            style: GlazeTabBarStyle.underline,
            tabs: [
              for (final layer in layers)
                GlazeTabItem(label: _label(layer), icon: _icon(layer)),
            ],
            activeIndex: layers.indexOf(active),
            onChanged: (i) => setState(() => _layer = layers[i]),
          ),
        )
      else
        Expanded(
          child: Text(
            _label(active),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ),
      if (active == _Layer.lorebook)
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'action_refresh'.tr(),
          icon: const Icon(Icons.refresh_rounded, size: 18),
          onPressed: () =>
              ref.invalidate(lorebookCoverageProvider(widget.charId)),
        ),
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: 'coverage_open_inspector'.tr(),
        icon: const Icon(Icons.open_in_full_rounded, size: 16),
        onPressed: () => showPromptInspectorSheet(
          context,
          widget.charId,
          initialTabId: active == _Layer.lorebook
              ? PromptInspectorSheet.coverageTabId
              : PromptInspectorSheet.contextTabId,
        ),
      ),
    ],
  );

  String _label(_Layer layer) => switch (layer) {
    _Layer.memory => 'coverage_tab_memory'.tr(),
    _Layer.lorebook => 'coverage_tab_lorebook'.tr(),
  };

  IconData _icon(_Layer layer) => switch (layer) {
    _Layer.memory => Icons.psychology_alt_outlined,
    _Layer.lorebook => Icons.menu_book_outlined,
  };
}
