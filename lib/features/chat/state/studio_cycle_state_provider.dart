import 'package:flutter_riverpod/legacy.dart';

/// Live state of the Studio tracker-cycle, surfaced to the chat UI so the
/// user can see when trackers are running and when the final generator is
/// streaming. A floating card (`StudioStatusCard`) appears at the top of
/// the chat while the cycle is active, then auto-dismisses shortly after it
/// finishes.
///
/// The cycle phases are:
///   idle → running → writingFinal → cleaning → done | agentErrors | error
///
/// `running` covers the tracker-agents (intermediate agents) phase.
/// `writingFinal` covers the final generator streaming its reply.
/// `cleaning` covers the POST-cleaner rewrite (only when Studio was active —
/// otherwise the cleaner shows its own [PostCleanerStatusCard]).
/// `agentErrors` is the soft-fail outcome: some trackers failed but the
/// final generator still produced a reply (or attempted to).
/// `error` is the hard-fail outcome (timeout / uncaught error / empty
/// response).
class StudioCycleState {
  final String? sessionId;
  final StudioCyclePhase phase;
  final int totalAgents;
  final int completedAgents;
  final int failedAgents;
  final List<String> failedAgentNames;

  const StudioCycleState({
    this.sessionId,
    this.phase = StudioCyclePhase.idle,
    this.totalAgents = 0,
    this.completedAgents = 0,
    this.failedAgents = 0,
    this.failedAgentNames = const [],
  });

  bool get isActive =>
      phase == StudioCyclePhase.running ||
      phase == StudioCyclePhase.writingFinal ||
      phase == StudioCyclePhase.cleaning;
  bool get isDone =>
      phase == StudioCyclePhase.done || phase == StudioCyclePhase.agentErrors;
  bool get isError => phase == StudioCyclePhase.error;

  const StudioCycleState.idle()
    : sessionId = null,
      phase = StudioCyclePhase.idle,
      totalAgents = 0,
      completedAgents = 0,
      failedAgents = 0,
      failedAgentNames = const [];

  const StudioCycleState.running({
    required this.sessionId,
    required this.totalAgents,
  }) : phase = StudioCyclePhase.running,
       completedAgents = 0,
       failedAgents = 0,
       failedAgentNames = const [];

  const StudioCycleState.writingFinal({
    required this.sessionId,
    required this.totalAgents,
    required this.completedAgents,
    required this.failedAgents,
    required this.failedAgentNames,
  }) : phase = StudioCyclePhase.writingFinal;

  const StudioCycleState.cleaning({
    required this.sessionId,
    required this.totalAgents,
    required this.completedAgents,
    required this.failedAgents,
    required this.failedAgentNames,
  }) : phase = StudioCyclePhase.cleaning;

  const StudioCycleState.done({
    required this.sessionId,
    required this.totalAgents,
    required this.completedAgents,
    required this.failedAgents,
    required this.failedAgentNames,
  }) : phase = StudioCyclePhase.done;

  const StudioCycleState.agentErrors({
    required this.sessionId,
    required this.totalAgents,
    required this.completedAgents,
    required this.failedAgents,
    required this.failedAgentNames,
  }) : phase = StudioCyclePhase.agentErrors;

  const StudioCycleState.error({required this.sessionId})
    : phase = StudioCyclePhase.error,
      totalAgents = 0,
      completedAgents = 0,
      failedAgents = 0,
      failedAgentNames = const [];
}

enum StudioCyclePhase {
  idle,
  running,
  writingFinal,
  cleaning,
  done,
  agentErrors,
  error
}

/// Global Studio tracker-cycle live state. Set by
/// `StreamGenerationService` before and after `runTrackerCycle`, and watched
/// by `StudioStatusCard` in the chat UI.
final studioCycleStateProvider = StateProvider<StudioCycleState>(
  (_) => const StudioCycleState.idle(),
);
