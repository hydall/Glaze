import '../models/chat_message.dart';
import '../models/memory_book.dart';
import '../state/memory_settings_provider.dart';
import 'memory_provenance.dart';

/// Builds [MemoryProvenanceKey] instances from the current generation context.
///
/// Centralizes the mapping from session/branch/swipe/settings/history state
/// to a provenance key that the prewarm cache and derived state index use
/// for invalidation.
///
/// Key mapping (no separate branchId in the data model — branch ≡ session):
/// - sessionId / branchId → session.id
/// - anchorMessageId → regenTargetId (regen) or session.messages.last.id (new gen)
/// - anchorSwipeId → previousSwipeId (regen) or 0 (new gen)
/// - settingsRevision → hash of MemoryGlobalSettings.toJson()
/// - memoryRevision → book.updatedAt.toString()
/// - historyRevision → '${history.length}:${history.last.id}:${history.last.swipeId}'
class MemoryProvenanceKeyBuilder {
  const MemoryProvenanceKeyBuilder._();

  static MemoryProvenanceKey build({
    required String sessionId,
    String? regenTargetId,
    int? previousSwipeId,
    required MemoryGlobalSettings settings,
    required MemoryBook? book,
    required List<ChatMessage> history,
  }) {
    final anchorMessageId = regenTargetId ??
        (history.isNotEmpty ? history.last.id : sessionId);

    final anchorSwipeId = previousSwipeId ??
        (history.isNotEmpty ? history.last.swipeId : 0);

    final settingsRevision = _hashSettings(settings);

    final memoryRevision = book?.updatedAt.toString() ?? '0';

    final historyRevision = history.isNotEmpty
        ? '${history.length}:${history.last.id}:${history.last.swipeId}'
        : '0';

    return MemoryProvenanceKey(
      sessionId: sessionId,
      branchId: sessionId,
      anchorMessageId: anchorMessageId,
      anchorSwipeId: anchorSwipeId,
      settingsRevision: settingsRevision,
      memoryRevision: memoryRevision,
      historyRevision: historyRevision,
    );
  }

  static String _hashSettings(MemoryGlobalSettings settings) {
    final json = settings.toJson();
    final keys = json.keys.toList()..sort();
    final buffer = StringBuffer();
    for (final key in keys) {
      buffer.write('$key=${json[key]};');
    }
    return buffer.toString().hashCode.toRadixString(16);
  }
}
