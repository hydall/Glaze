import 'package:flutter_riverpod/legacy.dart';

/// In-memory storage for per-message JS extension variables.
///
/// Message variables are not persisted in the current design (per the
/// plan: "decide between adding message vars to `ChatMessage` or storing
/// them in a separate per-message table to avoid rewriting large
/// `messagesJson` blobs" — we keep them in RAM only for the session
/// lifetime; this matches how the runtime prompt injection storage
/// works and avoids any DB migration).
///
/// Reads/writes go through the in-process notifier so the bridge stays
/// the single source of truth.
class MessageVariablesNotifier
    extends StateNotifier<Map<String, MessageVariablesEntry>> {
  MessageVariablesNotifier() : super(const {});

  /// Read the root variable map for a message. Returns an empty map when
  /// no entry exists yet.
  Map<String, dynamic> read(String sessionId, String messageId) {
    final key = _key(sessionId, messageId);
    final entry = state[key];
    return entry == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(entry.vars);
  }

  /// Atomically transform the message's variable map. Concurrent writes
  /// for the same `(sessionId, messageId)` are serialized through the
  /// state notifier's event loop — the [State] assignment is
  /// synchronous, so callers cannot lose updates within a single isolate.
  ///
  /// Validation lives on the bridge side; this notifier stores whatever
  /// it's given.
  Map<String, dynamic> update(
    String sessionId,
    String messageId,
    Map<String, dynamic> Function(Map<String, dynamic> root) update,
  ) {
    final key = _key(sessionId, messageId);
    final entry = state[key];
    final root = entry == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(entry.vars);
    final next = update(root);
    state = {
      ...state,
      key: MessageVariablesEntry(
        sessionId: sessionId,
        messageId: messageId,
        vars: Map<String, dynamic>.from(next),
      ),
    };
    return Map<String, dynamic>.from(next);
  }

  void delete(String sessionId, String messageId) {
    final key = _key(sessionId, messageId);
    if (!state.containsKey(key)) return;
    final next = Map<String, MessageVariablesEntry>.from(state)..remove(key);
    state = next;
  }

  /// Drop every variable attached to any message in the given session.
  /// Called from `ChatSessionController` / `ChatNotifier` when the user
  /// switches session, clears the chat, or deletes a message.
  void clearSession(String sessionId) {
    final next = <String, MessageVariablesEntry>{
      for (final entry in state.entries)
        if (entry.value.sessionId != sessionId) entry.key: entry.value,
    };
    state = next;
  }

  /// Drop a single message's variables. Called when a single message is
  /// removed (edit-cancel + delete, etc.).
  void clearMessage(String sessionId, String messageId) =>
      delete(sessionId, messageId);

  String _key(String sessionId, String messageId) => '$sessionId::$messageId';
}

class MessageVariablesEntry {
  const MessageVariablesEntry({
    required this.sessionId,
    required this.messageId,
    required this.vars,
  });

  final String sessionId;
  final String messageId;
  final Map<String, dynamic> vars;
}

final messageVariablesProvider =
    StateNotifierProvider<
      MessageVariablesNotifier,
      Map<String, MessageVariablesEntry>
    >((ref) => MessageVariablesNotifier());
