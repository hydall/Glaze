import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/memory_studio_service.dart';
import 'package:glaze_flutter/core/llm/studio_stage_brief.dart';
import 'package:glaze_flutter/features/chat/state/studio_cycle_state_mapper.dart';
import 'package:glaze_flutter/features/chat/state/studio_cycle_state_provider.dart';

void main() {
  const result = StudioPipelineResult(
    status: 'ok',
    response: 'response',
    stageBriefs: [
      StudioStageBrief(agentId: '1', agentName: 'first', brief: 'a'),
      StudioStageBrief(
        agentId: '2',
        agentName: 'second',
        brief: '',
        status: 'error',
        error: 'failed',
      ),
      StudioStageBrief(
        agentId: '3',
        agentName: 'third',
        brief: '',
        status: 'disabled',
      ),
    ],
  );

  group('StudioCycleStateMapper.studioFinalState', () {
    test('maps done with exact agent counts and failed-name order', () {
      final state = StudioCycleStateMapper.studioFinalState(
        'session',
        result,
        StudioCyclePhase.done,
      );

      expect(state.phase, StudioCyclePhase.done);
      expect(state.sessionId, 'session');
      expect(state.totalAgents, 3);
      expect(state.completedAgents, 1);
      expect(state.failedAgents, 2);
      expect(state.failedAgentNames, ['second', 'third']);
    });

    test('maps agent errors with the same counts', () {
      final state = StudioCycleStateMapper.studioFinalState(
        'session',
        result,
        StudioCyclePhase.agentErrors,
      );

      expect(state.phase, StudioCyclePhase.agentErrors);
      expect(state.sessionId, 'session');
      expect(state.totalAgents, 3);
      expect(state.completedAgents, 1);
      expect(state.failedAgents, 2);
      expect(state.failedAgentNames, ['second', 'third']);
    });

    test('maps every nonterminal-output phase to empty idle state', () {
      const phases = [
        StudioCyclePhase.idle,
        StudioCyclePhase.running,
        StudioCyclePhase.writingFinal,
        StudioCyclePhase.cleaning,
        StudioCyclePhase.error,
      ];

      for (final phase in phases) {
        final state = StudioCycleStateMapper.studioFinalState(
          'session',
          result,
          phase,
        );
        expect(state.phase, StudioCyclePhase.idle, reason: '$phase');
        expect(state.sessionId, isNull, reason: '$phase');
        expect(state.totalAgents, 0, reason: '$phase');
        expect(state.completedAgents, 0, reason: '$phase');
        expect(state.failedAgents, 0, reason: '$phase');
        expect(state.failedAgentNames, isEmpty, reason: '$phase');
      }
    });
  });
}
