import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_colors.dart';
import '../../state/memory_activity_provider.dart';
import '../lorebook_coverage_sheet.dart';
import 'coverage_memory_block.dart';

/// Coverage of the request that has not been sent yet: which lorebook entries
/// would fire right now, and which memories the last run selected.
///
/// The two halves are honest about their tense. The lorebook side is a live
/// dry-run of the scan, so it really is a prediction. Memory selection only
/// happens inside a generation, so the newest thing that exists is the last
/// turn's — labelled as such rather than dressed up as a forecast.
class NextTurnCoverageView extends ConsumerWidget {
  const NextTurnCoverageView({
    super.key,
    required this.charId,
    required this.sessionId,
    required this.onBack,
  });

  final String charId;
  final String sessionId;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memory = ref.watch(lastMemoryActivityProvider(charId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
          child: Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_back_rounded, size: 20),
                tooltip: 'coverage_back_to_list'.tr(),
                onPressed: onBack,
              ),
              Expanded(
                child: Text(
                  'coverage_next_request'.tr(),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: context.cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: CoverageMemoryBlock(
            activity: memory,
            caption: 'coverage_memory_last_run'.tr(),
            sessionId: sessionId,
          ),
        ),
        // The lorebook half brings its own toolbar, stat bar and filters.
        Expanded(child: CoveragePanel(charId: charId, embedded: true)),
      ],
    );
  }
}
