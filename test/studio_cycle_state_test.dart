import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:glaze_flutter/features/chat/state/studio_cycle_state_provider.dart';

void main() {
  group('StudioCycleState', () {
    test('idle is inactive and not done/error', () {
      const s = StudioCycleState.idle();
      expect(s.isActive, isFalse);
      expect(s.isDone, isFalse);
      expect(s.isError, isFalse);
      expect(s.phase, StudioCyclePhase.idle);
    });

    test('running is active', () {
      const s = StudioCycleState.running(sessionId: 's1', totalAgents: 3);
      expect(s.isActive, isTrue);
      expect(s.isDone, isFalse);
      expect(s.totalAgents, 3);
      expect(s.completedAgents, 0);
    });

    test('writingFinal is active', () {
      const s = StudioCycleState.writingFinal(
        sessionId: 's1',
        totalAgents: 3,
        completedAgents: 2,
        failedAgents: 1,
        failedAgentNames: ['lorebook'],
      );
      expect(s.isActive, isTrue);
      expect(s.completedAgents, 2);
      expect(s.failedAgents, 1);
      expect(s.failedAgentNames, ['lorebook']);
    });

    test('cleaning is active', () {
      const s = StudioCycleState.cleaning(
        sessionId: 's1',
        totalAgents: 3,
        completedAgents: 3,
        failedAgents: 0,
        failedAgentNames: [],
      );
      expect(s.isActive, isTrue);
      expect(s.isDone, isFalse);
      expect(s.phase, StudioCyclePhase.cleaning);
    });

    test('done is done, not active', () {
      const s = StudioCycleState.done(
        sessionId: 's1',
        totalAgents: 3,
        completedAgents: 3,
        failedAgents: 0,
        failedAgentNames: [],
      );
      expect(s.isDone, isTrue);
      expect(s.isActive, isFalse);
    });

    test('agentErrors is done (soft failure)', () {
      const s = StudioCycleState.agentErrors(
        sessionId: 's1',
        totalAgents: 3,
        completedAgents: 1,
        failedAgents: 2,
        failedAgentNames: ['expression', 'lorebook'],
      );
      expect(s.isDone, isTrue);
      expect(s.isError, isFalse);
      expect(s.failedAgentNames, ['expression', 'lorebook']);
    });

    test('error is error, not done', () {
      const s = StudioCycleState.error(sessionId: 's1');
      expect(s.isError, isTrue);
      expect(s.isDone, isFalse);
      expect(s.isActive, isFalse);
    });
  });

  group('studioCycleStateProvider', () {
    test('starts idle', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(studioCycleStateProvider).phase,
        StudioCyclePhase.idle,
      );
    });

    test('notifier can transition to running then done', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(studioCycleStateProvider.notifier).state =
          const StudioCycleState.running(sessionId: 's1', totalAgents: 2);
      expect(
        container.read(studioCycleStateProvider).phase,
        StudioCyclePhase.running,
      );
      container
          .read(studioCycleStateProvider.notifier)
          .state = const StudioCycleState.done(
        sessionId: 's1',
        totalAgents: 2,
        completedAgents: 2,
        failedAgents: 0,
        failedAgentNames: [],
      );
      expect(
        container.read(studioCycleStateProvider).phase,
        StudioCyclePhase.done,
      );
    });
  });
}
