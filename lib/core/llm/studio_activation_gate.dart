import 'package:flutter/foundation.dart';

import '../models/studio_config.dart';
import 'studio_controller_ontology.dart';

/// Pure agent-gating specialist: keyword-based tracker activation +
/// the 3-phase agent split. Execution modes (Direct/Assisted/Legacy)
/// have been removed — agent toggles are the sole topology control.
///
/// Stateless, no `Ref`.
class StudioActivationGate {
  StudioActivationGate._();


  /// Feature 6 — split a sorted (by `order`) list of enabled agents into the
  /// three pipeline phases.
  ///
  /// Rules:
  /// - Each agent's `phase` is first normalized via
  ///   [StudioAgent.normalizeAgentPhaseForType] (currently a no-op).
  /// - `postGenTrackers` = agents whose normalized phase is `'post_processing'`.
  /// - `preGenTrackers` = agents whose normalized phase is `'pre_generation'`,
  ///   EXCLUDING the final generator.
  /// - `finalAgent` = the agent whose spec has `isFinal: true`, if any.
  ///   Falls back to the last enabled pre-gen agent (migration compat).
  /// - Fallback: if NO pre-gen agent exists, the last enabled agent overall is
  ///   the generator (and is removed from `postGenTrackers`).
  static AgentPhaseSplit splitAgentsByPhase(List<StudioAgent> agents) {
    if (agents.isEmpty) {
      return const AgentPhaseSplit(
        preGenTrackers: [],
        postGenTrackers: [],
        finalAgent: null,
      );
    }
    final normalized = agents.map((a) {
      final phase = StudioAgent.normalizeAgentPhaseForType(a.id, a.phase);
      return (agent: a, phase: phase);
    }).toList();

    final preGen = normalized
        .where((e) => e.phase == 'pre_generation')
        .map((e) => e.agent)
        .toList();
    final postGen = normalized
        .where((e) => e.phase == 'post_processing')
        .map((e) => e.agent)
        .toList();

    if (preGen.isNotEmpty) {
      final finalIdx = preGen.indexWhere(
        (a) => StudioControllerOntology.specForAgent(a)?.isFinal ?? false,
      );
      if (finalIdx >= 0) {
        final finalAgent = preGen[finalIdx];
        final preGenTrackers = <StudioAgent>[
          for (var i = 0; i < preGen.length; i++)
            if (i != finalIdx) preGen[i],
        ];
        return AgentPhaseSplit(
          preGenTrackers: preGenTrackers,
          postGenTrackers: postGen,
          finalAgent: finalAgent,
        );
      }
      // Fallback: last pre-gen agent = generator (migration compat).
      final finalAgent = preGen.last;
      final preGenTrackers = preGen.sublist(0, preGen.length - 1);
      return AgentPhaseSplit(
        preGenTrackers: preGenTrackers,
        postGenTrackers: postGen,
        finalAgent: finalAgent,
      );
    }

    // Fallback: no pre-gen agent at all. Use the last enabled agent overall
    // as the generator, regardless of phase, and remove it from the post-gen
    // list so it isn't run twice.
    final finalAgent = agents.last;
    final filteredPostGen = postGen
        .where((a) => a.id != finalAgent.id)
        .toList();
    return AgentPhaseSplit(
      preGenTrackers: const [],
      postGenTrackers: filteredPostGen,
      finalAgent: finalAgent,
    );
  }
}

/// Feature 6 — the 3-phase split of a sorted list of enabled agents. Produced
/// by [StudioActivationGate.splitAgentsByPhase] (and the
/// `MemoryStudioService.splitAgentsByPhase` delegator).
@immutable
class AgentPhaseSplit {
  final List<StudioAgent> preGenTrackers;
  final List<StudioAgent> postGenTrackers;
  final StudioAgent? finalAgent;

  const AgentPhaseSplit({
    required this.preGenTrackers,
    required this.postGenTrackers,
    required this.finalAgent,
  });
}
