import '../../../core/models/chat_message.dart';
import '../../../core/models/memory_book.dart';

/// Extracts the set of memory entry IDs and source keys that correspond to
/// the currently selected swipes of assistant messages. Used by the Memory
/// Books sheet to filter the entry list so only entries bound to visible
/// swipes are shown.
class MemorySwipeFilter {
  MemorySwipeFilter._();

  static String sourceKey(String messageId, int swipeId, int agentSwipeId) =>
      '$messageId:$swipeId:$agentSwipeId';

  /// Memory entry IDs from `triggeredMemories` on the selected swipe of each
  /// assistant message.
  static Set<String> selectedSwipeMemoryIds(List<ChatMessage> messages) {
    final ids = <String>{};
    for (final msg in messages) {
      if (msg.role != 'assistant') continue;
      for (final tm in msg.triggeredMemories) {
        if (tm.id.isNotEmpty) ids.add(tm.id);
      }
      final meta = msg.swipeId >= 0 && msg.swipeId < msg.swipesMeta.length
          ? msg.swipesMeta[msg.swipeId]
          : const <String, dynamic>{};
      final rawTriggered = meta['triggeredMemories'];
      if (rawTriggered is List) {
        for (final raw in rawTriggered) {
          if (raw is! Map) continue;
          final id = raw['id'] as String? ?? '';
          if (id.isNotEmpty) ids.add(id);
        }
      }
    }
    return ids;
  }

  /// Source message IDs of visible (non-hidden, non-typing, non-error)
  /// assistant messages.
  static Set<String> selectedSwipeSourceMessageIds(List<ChatMessage> messages) {
    final ids = <String>{};
    for (final msg in messages) {
      if (msg.role != 'assistant') continue;
      if (msg.isHidden || msg.isTyping || msg.isError) continue;
      ids.add(msg.id);
    }
    return ids;
  }

  /// Source keys (`messageId:swipeId:agentSwipeId`) of visible assistant
  /// messages.
  static Set<String> selectedSwipeSourceKeys(List<ChatMessage> messages) {
    final keys = <String>{};
    for (final msg in messages) {
      if (msg.role != 'assistant') continue;
      if (msg.isHidden || msg.isTyping || msg.isError) continue;
      keys.add(sourceKey(msg.id, msg.swipeId, msg.agentSwipeId));
    }
    return keys;
  }

  /// Returns `true` if [entry] should be visible given the current filter
  /// state.
  ///
  /// When [hideUnselected] is `false`, all entries match. Otherwise the entry
  /// matches if it was injected via `triggeredMemories`
  /// ([selectedMemoryIds]), or its source swipe is currently visible
  /// ([selectedSourceKeys]), or it has legacy provenance (swipeId == 0 &&
  /// agentSwipeId == 0) and its source message is visible.
  static bool entryMatches(
    MemoryEntry entry, {
    required bool hideUnselected,
    required Set<String> selectedMemoryIds,
    required Set<String> selectedSourceMessageIds,
    required Set<String> selectedSourceKeys,
  }) {
    if (!hideUnselected) return true;
    if (selectedMemoryIds.contains(entry.id)) return true;
    if (entry.messageIds.isEmpty) return false;
    final sourceKey = MemorySwipeFilter.sourceKey(
      entry.messageIds.first,
      entry.sourceSwipeId,
      entry.sourceAgentSwipeId,
    );
    if (selectedSourceKeys.contains(sourceKey)) return true;
    final hasLegacyProvenance =
        entry.sourceSwipeId == 0 && entry.sourceAgentSwipeId == 0;
    return hasLegacyProvenance &&
        entry.messageIds.any(selectedSourceMessageIds.contains);
  }
}
