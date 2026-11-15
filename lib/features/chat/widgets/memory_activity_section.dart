import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../state/memory_activity_provider.dart';
import 'context_coverage/memory_candidate_view.dart';
import 'memory_graph_panel.dart';

/// The memory half of a coverage surface: the requests screen's memory block.
/// (The card under the chat header is drawn by the chat page, from the same
/// [MemoryCandidateView]s — see `context_coverage_card.dart`.)
///
/// Body only: the host owns the surface and the title row, so this renders the
/// warning, the run's stat chips and the candidate list and nothing else.
class MemoryActivitySection extends StatefulWidget {
  final MemoryActivityState activity;
  final String? sessionId;

  const MemoryActivitySection({
    super.key,
    required this.activity,
    this.sessionId,
  });

  @override
  State<MemoryActivitySection> createState() => _MemoryActivitySectionState();
}

class _MemoryActivitySectionState extends State<MemoryActivitySection> {
  final Set<String> _expandedEntryIds = {};
  final ScrollController _listScrollController = ScrollController();

  @override
  void didUpdateWidget(covariant MemoryActivitySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activity.messageId != widget.activity.messageId) {
      _expandedEntryIds.clear();
    }
  }

  @override
  void dispose() {
    _listScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final diagnostics = widget.activity.diagnostics;
    final summary = MemoryActivitySummary.of(widget.activity);
    final sessionId = widget.sessionId;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (summary.macroMissing) ...[
          _MemoryActivityWarning(text: 'memory_macro_missing_warning'.tr()),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final chip in MemoryCandidateView.chipsOf(
                    summary,
                    diagnostics,
                  ))
                    _MemoryActivityChip(label: chip),
                ],
              ),
            ),
            if (sessionId != null && sessionId.isNotEmpty)
              IconButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => MemoryGraphPanel(sessionId: sessionId),
                ),
                icon: const Icon(Icons.account_tree_outlined, size: 18),
                tooltip: 'memory_graph_title'.tr(),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        const SizedBox(height: 8),
        _candidateList(context, diagnostics),
      ],
    );
  }

  Widget _candidateList(
    BuildContext context,
    Map<String, dynamic> diagnostics,
  ) {
    final rows = MemoryCandidateView.listOf(
      diagnostics,
    ).map((view) => _candidateTile(context, view)).toList(growable: false);
    if (rows.isEmpty) return const SizedBox.shrink();
    // Cap the list height so a large memory book (dozens of entries) scrolls
    // inside the card instead of expanding into one giant screen-tall panel.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: Scrollbar(
        controller: _listScrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _listScrollController,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: rows,
          ),
        ),
      ),
    );
  }

  Widget _candidateTile(BuildContext context, MemoryCandidateView view) {
    final entryId = view.entryId;
    final selected = view.selected;
    final verdictColor = selected ? Colors.greenAccent : Colors.orangeAccent;
    final expanded = _expandedEntryIds.contains(entryId);

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              mouseCursor: SystemMouseCursors.click,
              onTap: () {
                setState(() {
                  if (expanded) {
                    _expandedEntryIds.remove(entryId);
                  } else {
                    _expandedEntryIds.add(entryId);
                  }
                });
              },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Row(
                  children: [
                    Icon(
                      selected
                          ? Icons.check_circle_outline
                          : Icons.cancel_outlined,
                      color: verdictColor,
                      size: 16,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            view.label,
                            maxLines: expanded ? 4 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          // Why it was left out, in a couple of words, right on
                          // the row: a list of skipped candidates used to look
                          // identical until each one was opened.
                          if (view.shortReason != null)
                            Text(
                              view.shortReason!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Colors.orangeAccent,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 16,
                      color: context.cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(view.trailing, style: const TextStyle(fontSize: 11)),
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(left: 25, top: 2, bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in view.details)
                    Padding(
                      padding: EdgeInsets.only(top: line.spaced ? 2 : 0),
                      child: Text(
                        line.text,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.3,
                          fontWeight: line.tone == MemoryDetailTone.verdict
                              ? FontWeight.w600
                              : null,
                          color: switch (line.tone) {
                            MemoryDetailTone.verdict => verdictColor,
                            MemoryDetailTone.normal =>
                              context.cs.onSurfaceVariant,
                            MemoryDetailTone.dim =>
                              context.cs.onSurfaceVariant.withValues(
                                alpha: 0.85,
                              ),
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MemoryActivityWarning extends StatelessWidget {
  final String text;

  const _MemoryActivityWarning({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 16,
            color: Colors.orangeAccent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11,
                color: context.cs.onSurface,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemoryActivityChip extends StatelessWidget {
  final String label;

  const _MemoryActivityChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: context.cs.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 11),
      ),
    );
  }
}
