import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Global, lightweight registry of chat sessions that are currently generating
/// (streaming or running post-generation stages). Lets the chat list surface a
/// live "typing" indicator for a session without instantiating that session's
/// full [chatProvider] (which would build state + load the DB per row).
///
/// The set is keyed by `sessionId`. [ChatNotifier] is the sole writer: it syncs
/// this registry from its own state transitions (see `chat_provider.dart`).
/// Generation is decoupled from the chat screen's lifecycle (`ref.keepAlive()`),
/// so an entry stays here while the reply keeps streaming after the user leaves
/// the chat.
final generatingSessionsProvider =
    NotifierProvider<GeneratingSessionsNotifier, Set<String>>(
      GeneratingSessionsNotifier.new,
    );

class GeneratingSessionsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// Marks [sessionId] as generating. No-op if already present so streaming
  /// chunks (which re-invoke the sync) don't churn the set.
  void mark(String sessionId) {
    if (state.contains(sessionId)) return;
    state = {...state, sessionId};
  }

  /// Clears the generating flag for [sessionId].
  void unmark(String sessionId) {
    if (!state.contains(sessionId)) return;
    state = {...state}..remove(sessionId);
  }

  /// Convenience: [mark] or [unmark] based on [generating].
  void set(String sessionId, bool generating) {
    if (generating) {
      mark(sessionId);
    } else {
      unmark(sessionId);
    }
  }
}
