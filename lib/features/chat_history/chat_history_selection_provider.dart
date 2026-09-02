import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Multi-select state for the dialogs list. A long press (right-click on
/// desktop) enters selection mode; while [active], tapping a row toggles its
/// membership instead of opening the chat, and the shell header turns into a
/// selection bar exposing the bulk actions.
class ChatHistorySelectionState {
  final bool active;
  final Set<String> sessionIds;

  const ChatHistorySelectionState({
    this.active = false,
    this.sessionIds = const {},
  });

  int get count => sessionIds.length;
  bool contains(String sessionId) => sessionIds.contains(sessionId);
}

class ChatHistorySelectionNotifier extends Notifier<ChatHistorySelectionState> {
  bool _disposed = false;

  @override
  ChatHistorySelectionState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const ChatHistorySelectionState();
  }

  /// Enters selection mode with [sessionId] selected.
  void start(String sessionId) {
    if (_disposed) return;
    state = ChatHistorySelectionState(active: true, sessionIds: {sessionId});
  }

  /// Toggles [sessionId]; leaves selection mode when the last row is removed,
  /// so the header falls back to the normal Chats title on its own.
  void toggle(String sessionId) {
    if (_disposed) return;
    final next = {...state.sessionIds};
    if (!next.remove(sessionId)) next.add(sessionId);
    state = next.isEmpty
        ? const ChatHistorySelectionState()
        : ChatHistorySelectionState(active: true, sessionIds: next);
  }

  /// Drops every selected row. Guarded twice over: the screen clears on its
  /// way out — after the container may already be gone — and an empty
  /// selection must not publish a no-op state change.
  void clear() {
    if (_disposed) return;
    if (!state.active && state.sessionIds.isEmpty) return;
    state = const ChatHistorySelectionState();
  }
}

final chatHistorySelectionProvider =
    NotifierProvider<ChatHistorySelectionNotifier, ChatHistorySelectionState>(
      ChatHistorySelectionNotifier.new,
    );
