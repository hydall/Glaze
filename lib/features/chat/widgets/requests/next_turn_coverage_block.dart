import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/lorebook_coverage_provider.dart';
import '../../state/memory_activity_provider.dart';
import '../context_coverage/lorebook_coverage_section.dart';
import 'coverage_block_shell.dart';
import 'coverage_memory_block.dart';

/// Coverage of the request that has not been sent yet: which lorebook entries
/// would fire right now, and which memories the last run selected.
///
/// It used to be a row of its own at the top of the timeline, which put the
/// next request on screen twice — once as a preview and once as its coverage.
/// Coverage is a property of a request, so this rides inside the next request's
/// preview, between its parameters and its messages, exactly where a captured
/// request carries its own.
///
/// The two halves are honest about their tense. The lorebook side is a live
/// dry-run of the scan, so it really is a prediction. Memory selection only
/// happens inside a generation, so the newest thing that exists is the last
/// turn's — labelled as such rather than dressed up as a forecast.
class NextTurnCoverageBlock extends ConsumerWidget {
  const NextTurnCoverageBlock({
    super.key,
    required this.charId,
    this.sessionId,
    this.initiallyExpanded = false,
  });

  final String charId;
  final String? sessionId;

  /// Set when the inspector was opened *on* coverage — the block is then the
  /// thing you came for, so it is already open.
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverage = ref.watch(lorebookCoverageProvider(charId)).value;
    final memory = ref.watch(lastMemoryActivityProvider(charId));
    final summary = memory == null ? null : MemoryActivitySummary.of(memory);

    return CoverageBlockShell(
      initiallyExpanded: initiallyExpanded,
      title: 'requests_coverage_title'.tr(),
      subtitle: coverage == null && summary == null
          ? 'coverage_next_request_desc'.tr()
          : 'coverage_row_counts'.tr(
              args: [
                '${coverage?.injectedCount ?? 0}',
                '${summary?.selectedCount ?? 0}',
              ],
            ),
      body: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CoverageMemoryBlock(
            activity: memory,
            caption: 'coverage_memory_last_run'.tr(),
            sessionId: sessionId,
          ),
          const SizedBox(height: 10),
          LorebookCoverageSection(charId: charId),
        ],
      ),
    );
  }
}
