import 'package:flutter_riverpod/legacy.dart';

class MemoryActiveDraftsNotifier extends StateNotifier<Set<String>> {
  MemoryActiveDraftsNotifier() : super(const <String>{});

  final Map<String, Set<Object>> _owners = {};

  bool isActive(String sessionId) => state.contains(sessionId);

  MemoryDraftLease acquire(String sessionId) {
    final owner = Object();
    (_owners[sessionId] ??= <Object>{}).add(owner);
    state = {...state, sessionId};
    return MemoryDraftLease._(this, sessionId, owner);
  }

  MemoryDraftLease? tryAcquireExclusive(String sessionId) {
    if (isActive(sessionId)) return null;
    return acquire(sessionId);
  }

  void _release(String sessionId, Object owner) {
    final owners = _owners[sessionId];
    if (owners == null || !owners.remove(owner)) return;
    if (owners.isNotEmpty) return;
    _owners.remove(sessionId);
    state = {...state}..remove(sessionId);
  }
}

class MemoryDraftLease {
  MemoryDraftLease._(this._notifier, this.sessionId, this._owner);

  final MemoryActiveDraftsNotifier _notifier;
  final String sessionId;
  final Object _owner;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _notifier._release(sessionId, _owner);
  }
}

final memoryActiveDraftsProvider =
    StateNotifierProvider<MemoryActiveDraftsNotifier, Set<String>>(
      (ref) => MemoryActiveDraftsNotifier(),
    );
