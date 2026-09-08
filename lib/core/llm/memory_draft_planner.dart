import 'dart:math' as math;

import '../models/chat_message.dart';
import '../models/memory_book.dart';

class MemoryDraftPlan {
  final List<MemoryDraft> drafts;
  final int stableMessageCount;
  final int eligibleMessageCount;
  final int uncoveredMessageCount;

  const MemoryDraftPlan({
    required this.drafts,
    required this.stableMessageCount,
    required this.eligibleMessageCount,
    required this.uncoveredMessageCount,
  });
}

class MemoryDraftPlanner {
  const MemoryDraftPlanner._();

  static MemoryDraftPlan plan({
    required MemoryBook book,
    required List<ChatMessage> messages,
    required int interval,
    required int lagMessages,
    required String source,
    required int nowMillis,
  }) {
    final stableMessages = messages
        .where(
          (m) => !m.isTyping && (m.role == 'user' || m.role == 'assistant'),
        )
        .toList();
    final normalizedLag = lagMessages < 0 ? 0 : lagMessages;
    final eligibleMessages = stableMessages.length > normalizedLag
        ? stableMessages.take(stableMessages.length - normalizedLag).toList()
        : <ChatMessage>[];

    // Studio Ledger facts are a separate layer and do not block MemoryBook
    // range-summary coverage. Every other approved entry does.
    // Studio Ledger entries (`source:'studio_ledger'`) are legacy durable
    // facts that were removed from the injection pipeline — they must NOT
    // block the manual scan. The manual scan is a complementary summarization
    // layer. Without this skip, legacy durable facts across messages would
    // mask most of the chat from the scanner.
    final coveredIds = <String>{};
    for (final entry in book.entries) {
      if (entry.source == 'studio_ledger') {
        continue;
      }
      coveredIds.addAll(entry.messageIds);
    }
    for (final draft in book.pendingDrafts) {
      coveredIds.addAll(draft.messageIds);
    }

    final uncovered = eligibleMessages
        .where((m) => m.id.isNotEmpty && !coveredIds.contains(m.id))
        .toList();

    // Build fixed contiguous blocks of [segmentSize] messages.
    // The range/title reflects the real chat positions (1-15, 16-30, …)
    // even when some messages inside the block are already covered —
    // covered messages are excluded from the draft's [messageIds] but
    // do NOT stretch the block boundary.
    final segmentSize = interval < 1 ? 1 : interval;
    final newDrafts = <MemoryDraft>[];
    {
      final uncoveredSet = uncovered.map((m) => m.id).toSet();
      for (
        var start = 0;
        start < eligibleMessages.length;
        start += segmentSize
      ) {
        final end = math.min(start + segmentSize, eligibleMessages.length);
        final block = eligibleMessages.sublist(start, end);
        if (block.length < segmentSize) continue; // skip partial trailing block
        final blockUncovered = block
            .where((m) => uncoveredSet.contains(m.id))
            .toList();
        if (blockUncovered.isEmpty) continue;

        final segmentIds = blockUncovered
            .map((m) => m.id)
            .toList(growable: false);
        final segmentIdSet = segmentIds.toSet();
        final alreadyExists = book.pendingDrafts.any(
          (d) => d.messageIds.toSet().containsAll(segmentIdSet),
        );
        if (!alreadyExists) {
          final firstIdx = stableMessages.indexOf(block.first);
          final lastIdx = stableMessages.indexOf(block.last);
          final uniqueSuffix = segmentIds.join('|').hashCode.abs();
          newDrafts.add(
            MemoryDraft(
              id: 'draft_${nowMillis}_${newDrafts.length}_$uniqueSuffix',
              title: '${firstIdx + 1}-${lastIdx + 1}',
              messageIds: segmentIds,
              messageRange: MessageRange(start: firstIdx + 1, end: lastIdx + 1),
              status: 'pending_generation',
              source: source,
              createdAt: nowMillis,
              updatedAt: nowMillis,
            ),
          );
        }
      }
    }

    return MemoryDraftPlan(
      drafts: newDrafts,
      stableMessageCount: stableMessages.length,
      eligibleMessageCount: eligibleMessages.length,
      uncoveredMessageCount: uncovered.length,
    );
  }
}
