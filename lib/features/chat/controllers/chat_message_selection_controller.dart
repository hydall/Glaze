import '../../../core/models/chat_message.dart';
import '../chat_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Manages multi-select state and bulk message actions in chat.
class ChatMessageSelectionController {
  bool isSelectionMode = false;
  Set<String> selectedMessageIds = {};

  void updateSelection(Iterable<String> ids) {
    selectedMessageIds = ids.toSet();
    isSelectionMode = selectedMessageIds.isNotEmpty;
  }

  void clearSelection() {
    isSelectionMode = false;
    selectedMessageIds.clear();
  }

  bool allSelectedHidden(List<ChatMessage> messages) {
    if (selectedMessageIds.isEmpty) return false;
    return selectedMessageIds.every((id) {
      final idx = messages.indexWhere((m) => m.id == id);
      return idx >= 0 && messages[idx].isHidden;
    });
  }

  Future<void> hideSelected(
    WidgetRef ref,
    String charId,
    List<ChatMessage> messages,
  ) async {
    for (final id in selectedMessageIds) {
      final idx = messages.indexWhere((m) => m.id == id);
      if (idx >= 0) {
        await ref.read(chatProvider(charId).notifier).toggleMessageHidden(idx);
      }
    }
    clearSelection();
  }

  /// Deletes every selected message and leaves selection mode.
  ///
  /// Deliberately not `async`: the indices are resolved and the selection is
  /// dropped synchronously, so a caller that rebuilds before awaiting the
  /// returned future sees the toolbar gone on the frame of the tap. The delete
  /// itself is optimistic (see `ChatMessageOpsController.deleteMessages`) — a
  /// toolbar that outlived the bubbles would be the only thing still lagging.
  Future<void> deleteSelected(
    WidgetRef ref,
    String charId,
    List<ChatMessage> messages,
  ) {
    final indices = selectedMessageIds
        .map((id) => messages.indexWhere((m) => m.id == id))
        .where((idx) => idx >= 0)
        .toSet();
    clearSelection();
    if (indices.isEmpty) return Future<void>.value();
    return ref.read(chatProvider(charId).notifier).deleteMessages(indices);
  }
}
