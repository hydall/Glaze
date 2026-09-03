import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/llm/prompt/exact_lorebook_manifest.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glaze_spinner.dart';
import '../../chat_provider.dart';
import '../../state/memory_activity_provider.dart';
import '../../state/turn_coverage_provider.dart';
import 'coverage_memory_block.dart';
import 'manifest_entry_row.dart';

/// What one captured request carried besides its messages: the memory
/// selection the turn recorded, and the lorebook entries from its manifest.
///
/// Coverage is a property *of* a request, so it lives inside the opened
/// request rather than in a list of its own — collapsed to a summary line,
/// expanded to the two halves. Nothing here is recomputed: re-scanning today's
/// books would answer "what would fire now", which is the next request's
/// question and not this one's.
class RequestCoverageBlock extends ConsumerStatefulWidget {
  const RequestCoverageBlock({
    super.key,
    required this.charId,
    required this.messageId,
  });

  final String charId;

  /// The turn this request belongs to. Null (or gone from the session) for a
  /// request bound to no message — a background job — which recorded no
  /// coverage of its own.
  final String? messageId;

  @override
  ConsumerState<RequestCoverageBlock> createState() =>
      _RequestCoverageBlockState();
}

class _RequestCoverageBlockState extends ConsumerState<RequestCoverageBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatProvider(widget.charId)).value;
    final sessionId = state?.session?.id ?? '';
    final message = _message(state?.messages ?? const <ChatMessage>[]);
    final expandable = message != null && sessionId.isNotEmpty;

    return Material(
      color: context.cs.onSurface.withValues(alpha: 0.03),
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: expandable
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.menu_book_outlined,
                    size: 16,
                    color: context.cs.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'requests_coverage_title'.tr(),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: context.cs.onSurface,
                          ),
                        ),
                        Text(
                          message == null
                              ? 'requests_coverage_none'.tr()
                              : 'coverage_row_counts'.tr(
                                  args: [
                                    '${message.triggeredLorebooks.length}',
                                    '${message.triggeredMemories.length}',
                                  ],
                                ),
                          style: TextStyle(
                            fontSize: 11,
                            color: context.cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (expandable)
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: context.cs.onSurfaceVariant,
                    ),
                ],
              ),
            ),
          ),
          // Written out rather than leaning on `expandable`: the null check
          // is what promotes [message] for [_body].
          if (_expanded && message != null && sessionId.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: _body(context, sessionId, message),
            ),
        ],
      ),
    );
  }

  ChatMessage? _message(List<ChatMessage> messages) {
    final id = widget.messageId;
    if (id == null || id.isEmpty) return null;
    final index = messages.indexWhere((m) => m.id == id);
    return index < 0 ? null : messages[index];
  }

  Widget _body(BuildContext context, String sessionId, ChatMessage message) {
    final coverage = ref.watch(
      turnCoverageProvider((
        sessionId: sessionId,
        messageId: message.id,
        swipeId: message.swipeId,
        agentSwipeId: message.agentSwipeId,
      )),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CoverageMemoryBlock(
          activity: _memory(sessionId, message),
          caption: 'coverage_memory_this_turn'.tr(),
          sessionId: sessionId,
        ),
        const SizedBox(height: 10),
        coverage.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: GlazeSpinner()),
          ),
          error: (error, _) => Text(
            '${'title_error'.tr()}: $error',
            style: TextStyle(fontSize: 11, color: context.cs.error),
          ),
          data: (manifest) => _manifestSection(context, manifest),
        ),
      ],
    );
  }

  /// The memory selection saved on the message itself when the turn ran.
  MemoryActivityState? _memory(String sessionId, ChatMessage message) {
    final diagnostics = message.memoryCoverage['diagnostics'];
    if (diagnostics is! Map) return null;
    return MemoryActivityState(
      sessionId: sessionId,
      messageId: message.id,
      diagnostics: Map<String, dynamic>.from(diagnostics),
      updatedAtMillis: message.timestamp ?? 0,
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
