import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:glaze_flutter/core/models/agent_operation_record.dart';
import 'package:glaze_flutter/features/chat/state/agent_operations_log_provider.dart';

void main() {
  group('AgentOperationsLogState', () {
    test('append adds a record', () {
      const state = AgentOperationsLogState();
      final rec = _mkRecord('r1', AgentOperationStatus.ok);
      final next = state.append(rec);
      expect(next.records.length, 1);
      expect(next.records.first.id, 'r1');
    });

    test('append evicts oldest when exceeding maxRecords', () {
      var state = const AgentOperationsLogState();
      for (var i = 0; i < AgentOperationsLogState.maxRecords + 5; i++) {
        state = state.append(_mkRecord('r$i', AgentOperationStatus.ok));
      }
      expect(state.records.length, AgentOperationsLogState.maxRecords);
      expect(state.records.first.id, 'r5');
      expect(
        state.records.last.id,
        'r${AgentOperationsLogState.maxRecords + 4}',
      );
    });

    test('forSession filters by session id', () {
      var state = const AgentOperationsLogState();
      state = state.append(_mkRecord('r1', AgentOperationStatus.ok, 's1'));
      state = state.append(_mkRecord('r2', AgentOperationStatus.ok, 's2'));
      state = state.append(_mkRecord('r3', AgentOperationStatus.ok, 's1'));
      expect(state.forSession('s1').length, 2);
      expect(state.forSession('s2').length, 1);
      expect(state.forSession(null).length, 3);
    });

    test('failures returns only failure-status records', () {
      var state = const AgentOperationsLogState();
      state = state.append(_mkRecord('r1', AgentOperationStatus.ok));
      state = state.append(_mkRecord('r2', AgentOperationStatus.httpError));
      state = state.append(_mkRecord('r3', AgentOperationStatus.timeout));
      state = state.append(_mkRecord('r4', AgentOperationStatus.aborted));
      expect(state.failures.length, 2);
      expect(state.failures[0].id, 'r2');
      expect(state.failures[1].id, 'r3');
    });

    test('clearForSession removes all records for a session', () {
      var state = const AgentOperationsLogState();
      state = state.append(_mkRecord('r1', AgentOperationStatus.ok, 's1'));
      state = state.append(_mkRecord('r2', AgentOperationStatus.ok, 's2'));
      state = state.append(_mkRecord('r3', AgentOperationStatus.ok, 's1'));
      final next = state.clearForSession('s1');
      expect(next.records.length, 1);
      expect(next.records.first.id, 'r2');
    });

    test('studioTracker kind survives append/filter/label', () {
      var state = const AgentOperationsLogState();
      final rec = AgentOperationRecord(
        id: 'st1',
        kind: AgentOperationKind.studioTracker,
        status: AgentOperationStatus.error,
        sessionId: 's1',
        attempts: const [
          AgentOperationAttempt(
            attempt: 1,
            statusCode: 0,
            status: 'error',
            startedAtMs: 100,
            elapsedMs: 50,
          ),
        ],
        totalElapsedMs: 50,
        summary: 'agent errors: 1/2 failed (tracker1)',
        startedAtMs: 100,
        finishedAtMs: 150,
        canRegenerate: true,
      );
      state = state.append(rec);
      expect(state.records.length, 1);
      expect(state.records.first.kind, AgentOperationKind.studioTracker);
      expect(state.records.first.kind.label, 'Studio tracker');
      expect(state.failures.length, 1);
      expect(state.failures.first.id, 'st1');
      expect(state.forSession('s1').length, 1);
    });
  });

  group('agentOperationsLogProvider', () {
    test('starts empty', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(agentOperationsLogProvider).records, isEmpty);
    });

    test('append via notifier', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(agentOperationsLogProvider.notifier).state = container
          .read(agentOperationsLogProvider)
          .append(_mkRecord('r1', AgentOperationStatus.ok));
      expect(container.read(agentOperationsLogProvider).records.length, 1);
    });
  });
}

AgentOperationRecord _mkRecord(
  String id,
  AgentOperationStatus status, [
  String? sessionId,
]) {
  return AgentOperationRecord(
    id: id,
    kind: AgentOperationKind.postCleaner,
    status: status,
    sessionId: sessionId,
    startedAtMs: 0,
    finishedAtMs: 0,
  );
}
