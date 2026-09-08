import 'package:flutter_riverpod/legacy.dart';

class MemoryActiveDraftsNotifier extends StateNotifier<Set<String>> {
  MemoryActiveDraftsNotifier() : super(const <String>{});

  bool isActive(String sessionId) => state.contains(sessionId);

  void markActive(String sessionId) {
    if (state.contains(sessionId)) return;
    state = {...state, sessionId};
  }

  void markInactive(String sessionId) {
    if (!state.contains(sessionId)) return;
    state = {...state}..remove(sessionId);
  }
}

final memoryActiveDraftsProvider =
    StateNotifierProvider<MemoryActiveDraftsNotifier, Set<String>>(
      (ref) => MemoryActiveDraftsNotifier(),
    );
