// Tests for the regen → abort rapid-cycling race conditions.
//
// These tests are pure-Dart unit tests — no Flutter widgets, no Riverpod,
// no DB required. They verify the two invariants that prevent "response
// leaking after abort":
//
//  1. setCancelToken genId guard — a stale generation that arrives late at
//     setCancelToken must have its token cancelled immediately, so the SSE
//     stream never fires onComplete for that generation.
//
library;
///  2. isAborted closure — the lambda captures _activeGenId by reference;
///     incrementing the counter must make every in-flight isAborted() call
///     return true, regardless of how many generations have been started.
///
///  3. Completer lifecycle — after abort, the completer must be completed
///     so that the next _abortAndWait() does not hang indefinitely.

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Minimal stand-alone replica of the relevant ChatNotifier logic.
// We duplicate only the pieces under test so the test has zero dependency on
// the real provider infrastructure.
// ---------------------------------------------------------------------------

class _FakeNotifier {
  CancelToken? cancelToken;
  int activeGenId = 0;
  Completer<void>? activeCompleter;

  /// Mirror of the real setCancelToken with genId guard.
  void setCancelToken(CancelToken token, {required int genId}) {
    if (activeGenId != genId) {
      token.cancel();
      return;
    }
    cancelToken = token;
  }

  /// Mirror of the real abortGeneration (minimal).
  void abort() {
    activeGenId++;
    cancelToken?.cancel();
    cancelToken = null;
    final c = activeCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Mirror of _abortAndWait.
  Future<void> abortAndWait() async {
    final c = activeCompleter;
    if (c == null || c.isCompleted) return;
    abort();
    await c.future;
  }

  /// Simulates one generation cycle:
  ///  - increments activeGenId (as _runGeneration does)
  ///  - creates a completer
  ///  - after [delay], calls setCancelToken
  ///  - if not aborted, completes the completer
  ///
  /// Returns the genId allocated for this cycle.
  Future<int> startGeneration({
    Duration delay = Duration.zero,
    required void Function(bool wasAborted) onDone,
  }) async {
    final genId = ++activeGenId;
    final completer = Completer<void>();
    activeCompleter = completer;

    // Simulate async work before the CancelToken is ready (e.g. buildPromptInIsolate)
    await Future<void>.delayed(delay);

    final token = CancelToken();
    setCancelToken(token, genId: genId);

    // If token was immediately cancelled by the guard, we are stale — stop.
    if (token.isCancelled) {
      if (!completer.isCompleted) completer.complete();
      onDone(true);
      return genId;
    }

    // isAborted closure — same as the real one
    bool isAborted() => activeGenId != genId;

    // Simulate streaming: pump a few microtasks, check abort each time
    for (int i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
      if (isAborted()) {
        if (!completer.isCompleted) completer.complete();
        onDone(true);
        return genId;
      }
    }

    if (!completer.isCompleted) completer.complete();
    onDone(false);
    return genId;
  }
}

// ---------------------------------------------------------------------------

void main() {
  group('setCancelToken genId guard', () {
    test('stale generation token is cancelled immediately', () {
      final n = _FakeNotifier();
      n.activeGenId = 5; // current generation is 5

      final staleToken = CancelToken();
      n.setCancelToken(staleToken, genId: 3); // stale

      expect(staleToken.isCancelled, isTrue,
          reason: 'Token from a stale generation must be cancelled immediately');
      expect(n.cancelToken, isNull,
          reason: 'Stale token must not overwrite the active slot');
    });

    test('current generation token is stored', () {
      final n = _FakeNotifier();
      n.activeGenId = 5;

      final freshToken = CancelToken();
      n.setCancelToken(freshToken, genId: 5); // current

      expect(freshToken.isCancelled, isFalse);
      expect(n.cancelToken, same(freshToken));
    });

    test('abort cancels the stored token', () {
      final n = _FakeNotifier();
      n.activeGenId = 2;

      final token = CancelToken();
      n.setCancelToken(token, genId: 2);
      expect(token.isCancelled, isFalse);

      n.abort();

      expect(token.isCancelled, isTrue);
      expect(n.cancelToken, isNull);
      expect(n.activeGenId, equals(3));
    });

    test('abort after abort is idempotent', () {
      final n = _FakeNotifier();
      n.activeGenId = 1;
      final token = CancelToken();
      n.setCancelToken(token, genId: 1);

      n.abort(); // id → 2
      n.abort(); // id → 3, no crash
      n.abort(); // id → 4

      expect(n.activeGenId, equals(4));
      expect(n.cancelToken, isNull);
    });
  });

  group('isAborted closure after rapid regen/abort cycles', () {
    test('isAborted returns true for every previous genId after 3 aborts', () {
      final n = _FakeNotifier();

      // Start gen 1
      final genId1 = ++n.activeGenId;
      bool isAborted1() => n.activeGenId != genId1;

      // Abort → gen 2
      n.abort();
      final genId2 = ++n.activeGenId;
      bool isAborted2() => n.activeGenId != genId2;

      // Abort → gen 3
      n.abort();
      final genId3 = ++n.activeGenId;
      bool isAborted3() => n.activeGenId != genId3;

      // Abort → gen 4
      n.abort();

      expect(isAborted1(), isTrue, reason: 'gen1 must be aborted');
      expect(isAborted2(), isTrue, reason: 'gen2 must be aborted');
      expect(isAborted3(), isTrue, reason: 'gen3 must be aborted');
      // genId1=1, abort→2, genId2=3, abort→4, genId3=5, abort→6
      expect(n.activeGenId, equals(6));
    });
  });

  group('rapid regen → abort cycles (async simulation)', () {
    test('only the last generation completes; earlier ones report aborted=true',
        () async {
      final n = _FakeNotifier();
      final results = <(int genId, bool aborted)>[];

      // Launch gen1 with a small delay so it reaches setCancelToken after gen2 is aborted
      final gen1Future = n.startGeneration(
        delay: const Duration(milliseconds: 20),
        onDone: (aborted) => results.add((1, aborted)),
      );

      // Immediately abort gen1 and start gen2
      await n.abortAndWait();
      final gen2Future = n.startGeneration(
        delay: const Duration(milliseconds: 20),
        onDone: (aborted) => results.add((2, aborted)),
      );

      // Abort gen2 and start gen3 (no delay — wins the race)
      await n.abortAndWait();
      final gen3Future = n.startGeneration(
        delay: Duration.zero,
        onDone: (aborted) => results.add((3, aborted)),
      );

      await Future.wait([gen1Future, gen2Future, gen3Future]);

      final abortedResults = results.where((r) => r.$2).map((r) => r.$1).toList();
      final completedResults = results.where((r) => !r.$2).map((r) => r.$1).toList();

      expect(abortedResults, containsAll([1, 2]),
          reason: 'gen1 and gen2 must report aborted=true');
      expect(completedResults, equals([3]),
          reason: 'only gen3 (last) must complete successfully');
    });

    test('token from stale generation arriving late does not override active token',
        () async {
      final n = _FakeNotifier();

      // gen1 starts with a long delay before setCancelToken
      final gen1Future = n.startGeneration(
        delay: const Duration(milliseconds: 30),
        onDone: (_) {},
      );

      // Abort gen1, start gen2 with no delay (sets its token first)
      await n.abortAndWait();
      final gen2Token = CancelToken();
      n.activeGenId++; // simulate gen2 acquiring id
      n.setCancelToken(gen2Token, genId: n.activeGenId);

      // Now gen1 finally arrives at setCancelToken (simulated by calling it with genId=1)
      final staleToken = CancelToken();
      n.setCancelToken(staleToken, genId: 1); // stale genId

      expect(staleToken.isCancelled, isTrue,
          reason: 'Late-arriving stale token must be cancelled');
      expect(n.cancelToken, same(gen2Token),
          reason: 'Active token (gen2) must not be overwritten by stale gen');

      await gen1Future;
    });

    test('abortAndWait does not hang when completer is already completed',
        () async {
      final n = _FakeNotifier();
      final c = Completer<void>()..complete();
      n.activeCompleter = c;

      // Should return immediately, not hang
      await n.abortAndWait().timeout(
        const Duration(milliseconds: 100),
        onTimeout: () => throw StateError('abortAndWait hung on completed completer'),
      );
    });

    test('3× regen→abort in quick succession: no response leaks through', () async {
      final n = _FakeNotifier();
      int leakedCompletions = 0;

      Future<void> regenAbortCycle(int delayMs) async {
        await n.abortAndWait();
        unawaited(n.startGeneration(
          delay: Duration(milliseconds: delayMs),
          onDone: (aborted) {
            if (!aborted) leakedCompletions++;
          },
        ));
      }

      // Three rapid cycles
      await regenAbortCycle(30);
      await regenAbortCycle(30);
      await regenAbortCycle(30);

      // Start final gen that we do NOT abort — it should complete
      await n.abortAndWait();
      await n.startGeneration(
        delay: Duration.zero,
        onDone: (aborted) {
          if (!aborted) leakedCompletions++;
        },
      );

      // Wait for all stragglers
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // Only the final generation should have leaked (completed), all others aborted
      expect(leakedCompletions, equals(1),
          reason: 'Exactly one generation (the last) should complete; '
              'all others must be aborted');
    });
  });
}
