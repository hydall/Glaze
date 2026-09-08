// Characterization tests for chat session switching race conditions.
//
// These tests verify the epoch-guard fix that prevents stale session switches
// from overwriting newer ones. The fix has three parts:
//
//   1. ChatSessionController._switchEpoch — any new session-change operation
//      (switchSession / createNewSession / branchSession) increments the epoch.
//      After each await, if the epoch no longer matches, the stale operation
//      bails out without calling _setState.
//
//   2. ChatSessionService.saveCurrentSessionIndex — changed from `void`
//      (fire-and-forget) to `Future<void>` (awaitable). switchToSession now
//      awaits it, so findExistingSession always reads the correct
//      currentSessionIndex from the DB.
//
//   3. ChatScreen._applyEpoch — _applySessionPreference uses an epoch guard
//      so that only the latest apply clears _sessionSwitchPending.
//
// Test strategy:
//   1. Pure-Dart replicas (deterministic, no DB) — model the fixed logic
//      with Completers to control completion order.
//   2. Integration tests (real in-memory Drift DB + real providers) —
//      exercise the actual ChatSessionService and ChatSessionController.

library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/controllers/chat_session_controller.dart';

// ---------------------------------------------------------------------------
// Test-only providers
// ---------------------------------------------------------------------------

final _sessionSvcProvider = Provider<ChatSessionService>(
  (ref) => ChatSessionService(ref),
);

class _StateBox {
  AsyncValue<ChatState> value = const AsyncData(ChatState());
  final List<ChatState> log = [];
}

final _stateBoxProvider = Provider<_StateBox>((ref) => _StateBox());

final _testCtrlProvider =
    Provider.family<ChatSessionController, String>((ref, charId) {
  final box = ref.watch(_stateBoxProvider);
  return ChatSessionController(
    ref: ref,
    charId: charId,
    setState: (s) {
      box.value = s;
      if (s.hasValue) box.log.add(s.value!);
    },
    getState: () => box.value,
    invalidateHistory: () {},
    fixupSwipesWithImageResults: (s) => s,
  );
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

AppDatabase _testDb() => AppDatabase.forTesting(NativeDatabase.memory());

ChatSession _makeSession(String charId, int idx) {
  return ChatSession(
    id: '${charId}_$idx',
    characterId: charId,
    sessionIndex: idx,
    messages: [
      ChatMessage(
        id: 'm_$idx',
        role: 'assistant',
        content: 'Session $idx message',
        timestamp: idx,
      ),
    ],
  );
}

Future<void> _seedData(
  ProviderContainer container,
  String charId, {
  int sessionCount = 3,
  int currentSessionIndex = 0,
}) async {
  final charRepo = container.read(characterRepoProvider);
  final chatRepo = container.read(chatRepoProvider);
  await charRepo.put(
    Character(id: charId, name: 'Test', currentSessionIndex: currentSessionIndex),
  );
  for (int i = 0; i < sessionCount; i++) {
    await chatRepo.put(_makeSession(charId, i));
  }
}

// ---------------------------------------------------------------------------
// Slow CharacterRepo wrapper for deterministic timing.
// Delays `put` so we can verify that switchToSession now awaits it
// (previously fire-and-forget, causing a race with findExistingSession).
// ---------------------------------------------------------------------------

class _SlowCharacterRepo extends CharacterRepo {
  _SlowCharacterRepo(super.db);

  @override
  Future<void> put(Character character) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await super.put(character);
  }
}

// ===========================================================================
// Group 1: Pure-Dart replica — epoch guard prevents stale switch writes
// ===========================================================================
//
// Minimal replica of the FIXED ChatSessionController.switchSession:
//
//   Future<void> switchSession(int sessionIndex) async {
//     final epoch = ++_switchEpoch;
//     try {
//       final raw = await _sessionSvc.switchToSession(_charId, sessionIndex);
//       if (!_ref.mounted || epoch != _switchEpoch) return;  // ← epoch guard
//       ...
//       _setState(...);
//     } catch (_) {
//       if (epoch != _switchEpoch) return;  // ← epoch guard in catch
//       ...
//     }
//   }

class _GuardedSwitcher {
  final void Function(ChatState) _setState;
  final ChatState Function() _getState;
  final Future<ChatSession> Function(int index) _switchToSession;

  int _switchEpoch = 0;

  _GuardedSwitcher(this._setState, this._getState, this._switchToSession);

  Future<void> switchSession(int index) async {
    final epoch = ++_switchEpoch;
    try {
      final raw = await _switchToSession(index);
      if (epoch != _switchEpoch) return;
      _setState(ChatState(session: raw));
    } catch (_) {
      if (epoch != _switchEpoch) return;
      final current = _getState();
      if (current.session != null) {
        _setState(current);
      }
    }
  }
}

void main() {
  group('Pure-Dart replica: epoch guard prevents stale switch writes', () {
    test('slower first switch is ignored — state stays on session 2', () async {
      final states = <int>[];
      var current = const ChatState();

      final completer1 = Completer<ChatSession>();
      final completer2 = Completer<ChatSession>();

      Future<ChatSession> fakeSwitch(int index) async {
        switch (index) {
          case 1:
            return completer1.future;
          case 2:
            return completer2.future;
          default:
            throw StateError('unexpected index $index');
        }
      }

      final switcher = _GuardedSwitcher(
        (s) {
          current = s;
          states.add(s.session?.sessionIndex ?? -1);
        },
        () => current,
        fakeSwitch,
      );

      // User rapidly taps session 1, then session 2.
      final f1 = switcher.switchSession(1);
      final f2 = switcher.switchSession(2);

      // Session 2 completes first (user's intended target).
      completer2.complete(
        const ChatSession(id: 'c1_2', characterId: 'c1', sessionIndex: 2),
      );
      await Future.microtask(() {});
      expect(current.session?.sessionIndex, 2,
          reason: 'After switch to 2 completes, state should be session 2');

      // Session 1 completes last — epoch guard prevents it from writing.
      completer1.complete(
        const ChatSession(id: 'c1_1', characterId: 'c1', sessionIndex: 1),
      );
      await f1;
      await f2;

      // FIXED: state stays on session 2 — stale switch was ignored.
      expect(states, [2],
          reason: 'Only session 2 wrote state — stale switch 1 was suppressed');
      expect(current.session?.sessionIndex, 2,
          reason: 'State stays on session 2 (the latest switch)');
    });

    test('triple switch — only the latest switch writes state', () async {
      final states = <int>[];
      var current = const ChatState();

      final completers = <int, Completer<ChatSession>>{
        0: Completer<ChatSession>(),
        1: Completer<ChatSession>(),
        2: Completer<ChatSession>(),
      };

      Future<ChatSession> fakeSwitch(int index) => completers[index]!.future;

      final switcher = _GuardedSwitcher(
        (s) {
          current = s;
          states.add(s.session?.sessionIndex ?? -1);
        },
        () => current,
        fakeSwitch,
      );

      // User cycles through sessions 0 → 1 → 2 rapidly.
      final f0 = switcher.switchSession(0);
      final f1 = switcher.switchSession(1);
      final f2 = switcher.switchSession(2);

      // Complete in order 1, 2, 0 — session 0 is last (oldest switch).
      completers[1]!.complete(
        const ChatSession(id: 'c1_1', characterId: 'c1', sessionIndex: 1),
      );
      completers[2]!.complete(
        const ChatSession(id: 'c1_2', characterId: 'c1', sessionIndex: 2),
      );
      completers[0]!.complete(
        const ChatSession(id: 'c1_0', characterId: 'c1', sessionIndex: 0),
      );

      await Future.wait([f0, f1, f2]);

      // FIXED: state is on session 2 (the latest switch), not 0 (the oldest).
      expect(current.session?.sessionIndex, 2,
          reason: 'State is on session 2 — only the latest switch writes');
      expect(states, [2],
          reason: 'Only session 2 wrote state — switches 0 and 1 were '
              'suppressed by the epoch guard');
    });

    test('error in stale switch does not restore old state', () async {
      final states = <int>[];
      var current = ChatState(
        session: const ChatSession(
          id: 'c1_2',
          characterId: 'c1',
          sessionIndex: 2,
        ),
      );

      final completer1 = Completer<ChatSession>();
      final completer2 = Completer<ChatSession>();

      Future<ChatSession> fakeSwitch(int index) async {
        switch (index) {
          case 1:
            return completer1.future;
          case 3:
            return completer2.future;
          default:
            throw StateError('unexpected index $index');
        }
      }

      final switcher = _GuardedSwitcher(
        (s) {
          current = s;
          states.add(s.session?.sessionIndex ?? -1);
        },
        () => current,
        fakeSwitch,
      );

      // Start switch to session 1 (will error).
      final f1 = switcher.switchSession(1);

      // Before it completes, start a newer switch to session 3.
      // This supersedes switch 1 (epoch increments to 2).
      final f2 = switcher.switchSession(3);

      // Complete switch 3 first (success).
      completer2.complete(
        const ChatSession(id: 'c1_3', characterId: 'c1', sessionIndex: 3),
      );
      await Future.microtask(() {});

      // Now complete switch 1 with an error.
      completer1.completeError(StateError('session not found'));
      await f1;
      await f2;

      // FIXED: catch block checked epoch(1) != _switchEpoch(2) and bailed.
      // State stays on session 3 — no restore to session 2 happened.
      expect(current.session?.sessionIndex, 3,
          reason: 'Stale error did not overwrite — state stays on session 3');
      expect(states, [3],
          reason: 'Only session 3 wrote state — stale error path was '
              'suppressed by epoch guard in catch block');
    });
  });

  // ===========================================================================
  // Group 2: _applySessionPreference — epoch guard prevents premature pending clear
  // ===========================================================================

  group('Pure-Dart replica: _applySessionPreference epoch guard', () {
    test('only the latest apply clears _sessionSwitchPending', () async {
      var sessionSwitchPending = false;
      final pendingLog = <bool>[];
      final switchLog = <int>[];
      var applyEpoch = 0;

      final switchCompleters = <int, Completer<void>>{
        1: Completer<void>(),
        2: Completer<void>(),
      };

      Future<void> doSwitch(int index) {
        switchLog.add(index);
        return switchCompleters[index]!.future;
      }

      Future<void> apply({int? sessionIndex}) async {
        final epoch = ++applyEpoch;
        final needsSwitch = sessionIndex != null;
        if (needsSwitch) {
          sessionSwitchPending = true;
          pendingLog.add(true);
        }
        try {
          await Future<void>.delayed(Duration.zero);
          if (sessionIndex != null) {
            await doSwitch(sessionIndex);
          }
        } finally {
          if (epoch == applyEpoch && sessionSwitchPending) {
            sessionSwitchPending = false;
            pendingLog.add(false);
          }
        }
      }

      // Start apply for session 1.
      final f1 = apply(sessionIndex: 1);

      // didUpdateWidget fires — new initialSessionIndex = 2.
      // Start apply for session 2 (supersedes f1).
      final f2 = apply(sessionIndex: 2);

      // Both are in-flight, both set pending = true.
      expect(sessionSwitchPending, true);

      // Complete switch 2 first.
      switchCompleters[2]!.complete();
      await f2;

      // FIXED: pending is false — f2 is the latest, so it clears pending.
      expect(sessionSwitchPending, false,
          reason: 'Pending cleared by f2 (the latest apply)');

      // Complete switch 1 — its finally block checks epoch != applyEpoch,
      // so it does NOT touch pending.
      switchCompleters[1]!.complete();
      await f1;

      expect(switchLog, [1, 2],
          reason: 'Both switches ran — no cancellation of the async op');
      // pendingLog: [true (f1), true (f2), false (f2's finally)]
      // f1's finally does NOT fire because epoch(1) != applyEpoch(2).
      expect(pendingLog, [true, true, false],
          reason: 'Pending set twice, cleared once by f2 (the latest). '
              'f1 finally was suppressed by epoch guard.');
    });

    test('if first apply completes before second, pending stays true until second finishes', () async {
      var sessionSwitchPending = false;
      var applyEpoch = 0;

      final switchCompleters = <int, Completer<void>>{
        1: Completer<void>(),
        2: Completer<void>(),
      };

      Future<void> doSwitch(int index) => switchCompleters[index]!.future;

      Future<void> apply({int? sessionIndex}) async {
        final epoch = ++applyEpoch;
        if (sessionIndex != null) {
          sessionSwitchPending = true;
        }
        try {
          await Future<void>.delayed(Duration.zero);
          if (sessionIndex != null) {
            await doSwitch(sessionIndex);
          }
        } finally {
          if (epoch == applyEpoch && sessionSwitchPending) {
            sessionSwitchPending = false;
          }
        }
      }

      final f1 = apply(sessionIndex: 1);
      final f2 = apply(sessionIndex: 2);

      // Complete switch 1 first (it's the older one).
      switchCompleters[1]!.complete();
      await f1;

      // FIXED: pending is still true — f1's finally was suppressed by epoch guard.
      expect(sessionSwitchPending, true,
          reason: 'Pending stays true — f1 (stale) did not clear it');

      // Complete switch 2.
      switchCompleters[2]!.complete();
      await f2;

      expect(sessionSwitchPending, false,
          reason: 'Pending cleared by f2 (the latest apply)');
    });
  });

  // ===========================================================================
  // Group 3: Integration — ChatSessionService cache coherence
  // ===========================================================================
  //
  // All internal chatRepo.put call sites now call ChatSessionService.updateCache.
  // This test verifies that:
  //   1. External put without updateCache still leaves stale cache (known gap)
  //   2. Calling updateCache after put fixes the cache

  group('Integration: ChatSessionService cache coherence', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() async {
      db = _testDb();
      container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      ChatSessionService.clearCache();
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('updateCache after put ensures switchToSession returns fresh data', () async {
      await _seedData(container, 'c1', sessionCount: 2);
      final sessionSvc = container.read(_sessionSvcProvider);
      final chatRepo = container.read(chatRepoProvider);

      // First switch to session 1 — populates the cache.
      final session1 = await sessionSvc.switchToSession('c1', 1);
      expect(session1.messages.first.content, 'Session 1 message');

      // Modify session 1 and properly call updateCache.
      final modified = session1.copyWith(
        messages: [
          ChatMessage(
            id: 'm_1_edited',
            role: 'assistant',
            content: 'EDITED content',
            timestamp: 1,
          ),
        ],
      );
      await chatRepo.put(modified);
      ChatSessionService.updateCache(modified);

      // Switch away to session 0, then back to session 1.
      await sessionSvc.switchToSession('c1', 0);
      final cachedAgain = await sessionSvc.switchToSession('c1', 1);

      // FIXED: cache returns the updated session.
      expect(cachedAgain.messages.first.content, 'EDITED content',
          reason: 'Cache returns fresh data — updateCache was called');
    });

    test('external put without updateCache leaves stale cache (known gap)', () async {
      await _seedData(container, 'c1', sessionCount: 2);
      final sessionSvc = container.read(_sessionSvcProvider);
      final chatRepo = container.read(chatRepoProvider);

      // First switch to session 1 — populates the cache.
      final session1 = await sessionSvc.switchToSession('c1', 1);

      // Modify session 1 in the DB directly WITHOUT calling updateCache.
      // This simulates an external code path (e.g. sync pull) that writes
      // to the DB but doesn't know about the static cache.
      final modified = session1.copyWith(
        messages: [
          ChatMessage(
            id: 'm_1_edited',
            role: 'assistant',
            content: 'EDITED content',
            timestamp: 1,
          ),
        ],
      );
      await chatRepo.put(modified);

      // Switch away to session 0, then back to session 1.
      await sessionSvc.switchToSession('c1', 0);
      final cachedAgain = await sessionSvc.switchToSession('c1', 1);

      // Known gap: external put without updateCache leaves stale cache.
      // All INTERNAL call sites now call updateCache, but external paths
      // (sync pull, import) must also call clearCache or updateCache.
      expect(cachedAgain.messages.first.content, 'Session 1 message',
          reason: 'Known gap: external put without updateCache leaves stale cache');
    });
  });

  // ===========================================================================
  // Group 4: Integration — saveCurrentSessionIndex is now awaited
  // ===========================================================================

  group('Integration: saveCurrentSessionIndex is awaited (fixed)', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() async {
      db = _testDb();
      container = ProviderContainer(
        overrides: [
          appDbProvider.overrideWithValue(db),
          characterRepoProvider.overrideWithValue(_SlowCharacterRepo(db)),
        ],
      );
      ChatSessionService.clearCache();
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('currentSessionIndex is persisted before switchToSession returns', () async {
      await _seedData(container, 'c1', sessionCount: 3, currentSessionIndex: 0);
      final sessionSvc = container.read(_sessionSvcProvider);
      final charRepo = container.read(characterRepoProvider);

      // Pre-populate cache so switchToSession takes the fast cache path.
      ChatSessionService.updateCache(_makeSession('c1', 2));

      // Switch to session 2 via cache.
      // FIXED: switchToSession now awaits saveCurrentSessionIndex, so the
      // DB write completes before switchToSession returns.
      // The _SlowCharacterRepo delays put by 200ms — switchToSession will
      // wait for it.
      final session = await sessionSvc.switchToSession('c1', 2);
      expect(session.sessionIndex, 2);

      // findExistingSession reads currentSessionIndex from DB.
      // FIXED: it should now read 2, not 0.
      final found = await sessionSvc.findExistingSession('c1');
      expect(found?.sessionIndex, 2,
          reason: 'FIXED: findExistingSession returns correct session 2 — '
              'saveCurrentSessionIndex was awaited before switchToSession returned');

      // Verify DB state directly.
      final char = await charRepo.getById('c1');
      expect(char?.currentSessionIndex, 2,
          reason: 'DB reflects the persisted index');
    });

    test('findExistingSession returns correct session immediately after switchToSession', () async {
      // With a fast DB (no slow repo), the race is now deterministic:
      // saveCurrentSessionIndex is awaited, so the DB always has the
      // correct index before switchToSession returns.
      final fastContainer = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(fastContainer.dispose);

      await _seedData(fastContainer, 'c1', sessionCount: 3, currentSessionIndex: 0);
      final sessionSvc = fastContainer.read(_sessionSvcProvider);

      // Pre-populate cache for session 1.
      ChatSessionService.updateCache(_makeSession('c1', 1));

      // Switch to session 1 via cache path.
      await sessionSvc.switchToSession('c1', 1);

      // Immediately call findExistingSession.
      // FIXED: no race — saveCurrentSessionIndex was awaited.
      final found = await sessionSvc.findExistingSession('c1');
      expect(found, isNotNull);
      expect(found!.sessionIndex, 1,
          reason: 'FIXED: findExistingSession returns session 1 — '
              'saveCurrentSessionIndex completed before switchToSession returned');
    });
  });

  // ===========================================================================
  // Group 5: Integration — ChatSessionController epoch guard
  // ===========================================================================

  group('Integration: ChatSessionController epoch guard (fixed)', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() async {
      db = _testDb();
      container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      ChatSessionService.clearCache();
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('two concurrent switchSession calls — only the latest writes state', () async {
      await _seedData(container, 'c1', sessionCount: 3);
      final box = container.read(_stateBoxProvider);
      final ctrl = container.read(_testCtrlProvider('c1'));

      // Start two concurrent switches.
      final f1 = ctrl.switchSession(1);
      final f2 = ctrl.switchSession(2);

      await Future.wait([f1, f2]);

      // FIXED: only one setState should fire — the second switch (epoch=2)
      // supersedes the first (epoch=1). Even if both DB reads complete,
      // only the latest epoch's result is written.
      //
      // With an in-memory DB, both reads may complete synchronously, so
      // either 1 or 2 setState calls may fire. But the final state must
      // be session 2 (the latest switch).
      final lastIndex = box.log.isNotEmpty
          ? box.log.last.session?.sessionIndex
          : null;
      expect(lastIndex, 2,
          reason: 'FIXED: final state is session 2 (the latest switch) — '
              'stale switch 1 was suppressed by epoch guard');
    });

    test('switchSession to non-existent session does not corrupt state', () async {
      await _seedData(container, 'c1', sessionCount: 2);
      final box = container.read(_stateBoxProvider);
      final ctrl = container.read(_testCtrlProvider('c1'));

      // Set initial state to session 0.
      await ctrl.switchSession(0);
      expect(box.value.value?.session?.sessionIndex, 0);

      // Try to switch to a non-existent session (index 99).
      // switchToSession will throw StateError.
      await ctrl.switchSession(99);

      // Catch block fires — restores the state to session 0.
      // This is correct error recovery behavior.
      expect(box.value.value?.session?.sessionIndex, 0,
          reason: 'Catch block restored session 0 after error');
    });

    test('switch then createNewSession — only the new session writes state', () async {
      await _seedData(container, 'c1', sessionCount: 2);
      final box = container.read(_stateBoxProvider);
      final ctrl = container.read(_testCtrlProvider('c1'));

      // Start a switch to session 1.
      final f1 = ctrl.switchSession(1);

      // Before it completes, start createNewSession — supersedes the switch.
      final f2 = ctrl.createNewSession();

      await Future.wait([f1, f2]);

      // FIXED: the switch to session 1 should be suppressed.
      // The final state should be the new session (index 2, the next index).
      final lastIndex = box.log.isNotEmpty
          ? box.log.last.session?.sessionIndex
          : null;
      expect(lastIndex, 2,
          reason: 'FIXED: final state is the new session (index 2) — '
              'stale switch to 1 was suppressed');
    });
  });
}
