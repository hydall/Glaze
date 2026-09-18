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

  /// Whether the current selection is allowed to be deleted.
  ///
  /// With [allowMiddle] off, only a trailing run can go: every message from the
  /// earliest selected one to the last message must be selected, with no gaps
  /// and nothing left unselected after it. [allowMiddle] lifts the restriction
  /// and allows any selection, including one in the middle of the chat.
  bool canDeleteSelection(
    List<ChatMessage> messages, {
    required bool allowMiddle,
  }) {
    if (selectedMessageIds.isEmpty || messages.isEmpty) return false;
    if (allowMiddle) return true;
    final selectedIndices = selectedMessageIds
        .map((id) => messages.indexWhere((m) => m.id == id))
        .where((idx) => idx >= 0)
        .toList();
    if (selectedIndices.isEmpty) return false;
    final earliest = selectedIndices.reduce((a, b) => a < b ? a : b);
    final lastIndex = messages.length - 1;
    if (earliest > lastIndex) return false;
    return selectedIndices.length == lastIndex - earliest + 1;
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
  /// Refuses a selection that [canDeleteSelection] rejects — a middle message
  /// with middle deletion disabled — so the restriction holds even if a caller
  /// bypasses the hidden toolbar button.
  ///
  /// Deliberately not `async`: the indices are resolved and the selection is
  /// dropped synchronously, so a caller that rebuilds before awaiting the
  /// returned future sees the toolbar gone on the frame of the tap. The delete
  /// itself is optimistic (see `ChatMessageOpsController.deleteMessages`) — a
  /// toolbar that outlived the bubbles would be the only thing still lagging.
  Future<void> deleteSelected(
    WidgetRef ref,
    String charId,
    List<ChatMessage> messages, {
    bool allowMiddle = false,
  }) {
    if (!canDeleteSelection(messages, allowMiddle: allowMiddle)) {
      return Future<void>.value();
    }
    final indices = selectedMessageIds
        .map((id) => messages.indexWhere((m) => m.id == id))
        .where((idx) => idx >= 0)
        .toSet();
    clearSelection();
    if (indices.isEmpty) return Future<void>.value();
    return ref.read(chatProvider(charId).notifier).deleteMessages(indices);
  }
}
