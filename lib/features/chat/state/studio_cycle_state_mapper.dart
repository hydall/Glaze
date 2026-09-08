import '../../../core/llm/memory_studio_service.dart' show StudioPipelineResult;
import 'studio_cycle_state_provider.dart';

class StudioCycleStateMapper {
  StudioCycleStateMapper._();

  /// Builds the terminal state from a Studio pipeline result, aggregating the
  /// per-agent briefs into completed/failed counts.
  static StudioCycleState studioFinalState(
    String sessionId,
    StudioPipelineResult result,
    StudioCyclePhase phase,
  ) {
    final briefs = result.stageBriefs;
    final ok = briefs.where((b) => b.status == 'ok').length;
    final failed = briefs.length - ok;
    final failedNames = briefs
        .where((b) => b.status != 'ok')
        .map((b) => b.agentName)
        .toList(growable: false);
    switch (phase) {
      case StudioCyclePhase.done:
        return StudioCycleState.done(
          sessionId: sessionId,
          totalAgents: briefs.length,
          completedAgents: ok,
          failedAgents: failed,
          failedAgentNames: failedNames,
        );
      case StudioCyclePhase.agentErrors:
        return StudioCycleState.agentErrors(
          sessionId: sessionId,
          totalAgents: briefs.length,
          completedAgents: ok,
          failedAgents: failed,
          failedAgentNames: failedNames,
        );
      default:
        return const StudioCycleState.idle();
    }
  }
}
