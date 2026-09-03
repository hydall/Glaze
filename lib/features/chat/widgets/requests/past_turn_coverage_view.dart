import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/llm/prompt/exact_lorebook_manifest.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_spinner.dart';
import '../../state/memory_activity_provider.dart';
import '../../state/turn_coverage_provider.dart';
import 'coverage_memory_block.dart';
import 'manifest_entry_row.dart';

/// What one past turn actually carried: the lorebook entries from its stored
/// manifest, and the memory selection saved on the message itself.
///
/// Nothing here is recomputed. A re-scan today would answer "what would fire
/// now", which is a different question and the reason this view exists at all.
class PastTurnCoverageView extends ConsumerWidget {
  const PastTurnCoverageView({
    super.key,
    required this.sessionId,
    required this.message,
    required this.turnNumber,
    required this.onBack,
  });

  final String sessionId;
  final ChatMessage message;
  final int turnNumber;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverage = ref.watch(
      turnCoverageProvider((
        sessionId: sessionId,
        messageId: message.id,
        swipeId: message.swipeId,
        agentSwipeId: message.agentSwipeId,
      )),
    );

    final diagnostics = message.memoryCoverage['diagnostics'];
    final memory = diagnostics is Map
        ? MemoryActivityState(
            sessionId: sessionId,
            messageId: message.id,
            diagnostics: Map<String, dynamic>.from(diagnostics),
            updatedAtMillis: message.timestamp ?? 0,
          )
        : null;

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
                  'requests_turn_numbered'.tr(args: ['$turnNumber']),
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
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              CoverageMemoryBlock(
                activity: memory,
                caption: 'coverage_memory_this_turn'.tr(),
                sessionId: sessionId,
              ),
              const SizedBox(height: 12),
              coverage.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: GlazeSpinner()),
                ),
                error: (error, _) => Text(
                  '${'title_error'.tr()}: $error',
                  style: TextStyle(fontSize: 11, color: context.cs.error),
                ),
                data: (manifest) => _manifestSection(context, manifest),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _manifestSection(
    BuildContext context,
    ExactLorebookManifest? manifest,
  ) {
    if (manifest == null || manifest.entries.isEmpty) {
      return Text(
        manifest == null
            ? 'coverage_no_manifest'.tr()
            : 'coverage_manifest_empty'.tr(),
        style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(
            'coverage_injected_count'.tr(args: ['${manifest.entries.length}']),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ),
        for (final entry in manifest.entries) ManifestEntryRow(entry: entry),
      ],
    );
  }
}
