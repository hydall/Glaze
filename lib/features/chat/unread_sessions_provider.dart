import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Set of chat sessions with an unread assistant reply — a reply that landed
/// while that session was NOT the one open on screen. Drives the unread dot +
/// row highlight in the chat list, and survives app restarts (persisted to
/// SharedPreferences).
///
/// Writers:
/// - [markUnread] on generation completion for a non-active session (see
///   `sync_notification_stage.dart` and `ChatNotifier.continueMessage`).
/// - [markRead] when the user opens / focuses the session — on entry, on chat
///   state changes, and on app resume (`SessionLifecycleTracker`).
///
/// A reply that lands while its session is the one on screen is never flagged:
/// both writers snapshot `isActiveSession` *before* awaiting the notification
/// pipeline and re-check it after, and [markRead] wins over a late hydration.
final unreadSessionsProvider =
    NotifierProvider<UnreadSessionsNotifier, Set<String>>(
      UnreadSessionsNotifier.new,
    );

class UnreadSessionsNotifier extends Notifier<Set<String>> {
  static const _prefsKey = 'unread_sessions';

  /// Sessions read before [_load] finished. Hydration must not resurrect their
  /// dot — see [_load].
  final Set<String> _readBeforeHydration = {};
  bool _hydrated = false;

  @override
  Set<String> build() {
    // Hydrate asynchronously; starts empty and fills in once prefs load.
    unawaited(_load());
    return const {};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_prefsKey);
      if (stored == null || stored.isEmpty) return;
      // Merge rather than overwrite: any marks that happened during the async
      // load must not be lost. Sessions the user already opened during the load
      // are dropped — otherwise a chat opened right after launch (deep link,
      // restored route, notification tap) would light up as unread again the
      // moment the persisted set lands.
      final restored = stored
          .where((id) => !_readBeforeHydration.contains(id))
          .toList();
      state = {...state, ...restored};
      // Persist the pruning so the dropped ids stay dropped across restarts.
      if (restored.length != stored.length) unawaited(_persist());
    } catch (e) {
      debugPrint('[UnreadSessions] load failed: $e');
    } finally {
      _hydrated = true;
      _readBeforeHydration.clear();
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, state.toList());
    } catch (e) {
      debugPrint('[UnreadSessions] persist failed: $e');
    }
  }

  void markUnread(String sessionId) {
    if (state.contains(sessionId)) return;
    state = {...state, sessionId};
    unawaited(_persist());
  }

  void markRead(String sessionId) {
    // Before hydration `state` is still empty, so the removal below is a no-op:
    // remember the id so `_load` does not merge it back in.
    if (!_hydrated) _readBeforeHydration.add(sessionId);
    if (!state.contains(sessionId)) return;
    state = {...state}..remove(sessionId);
    unawaited(_persist());
  }
}
