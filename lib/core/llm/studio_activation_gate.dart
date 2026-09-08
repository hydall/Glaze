import 'package:flutter/foundation.dart';

import '../models/studio_config.dart';
import 'studio_controller_ontology.dart';

/// Pure agent-gating specialist extracted from `MemoryStudioService`
/// (plan §2): keyword-based tracker activation + the 3-phase agent split.
///
/// Stateless, no `Ref`. `MemoryStudioService` keeps static
/// `@visibleForTesting` delegators (`matchesActivationKeywords`,
/// `splitAgentsByPhase`) and re-exports [AgentPhaseSplit] because tests
/// reference them via `MemoryStudioService.<name>`.
class StudioActivationGate {
  StudioActivationGate._();

  /// Whether a controller belongs to [mode]'s pre-generation topology.
  ///
  /// This deliberately says nothing about post-generation processing: the
  /// Post Cleaner / fact-checker switch remains an independent pipeline
  /// setting in every Studio mode.
  static bool isControllerAllowed(String specId, StudioExecutionMode mode) {
    return switch (mode) {
      StudioExecutionMode.legacy => true,
      StudioExecutionMode.direct => specId == 'final',
      StudioExecutionMode.assisted =>
        specId == 'final' ||
            specId == 'continuity' ||
            specId == 'narrative' ||
            specId == 'beauty',
    };
  }

  /// Applies an explicit preset topology to persisted runtime agents.
  /// Runtime `agents_json` can outlive a preset switch, so Direct must not
  /// rely on callers having already disabled individual pregen agents.
  static List<StudioAgent> applyExecutionMode(
    List<StudioAgent> agents,
    StudioExecutionMode mode,
  ) {
    return agents
        .map((agent) {
          final specId = StudioControllerOntology.specForAgent(agent).id;
          final isPreGen = agent.phase == 'pre_generation';
          final disabled = isPreGen && !isControllerAllowed(specId, mode);
          return disabled ? agent.copyWith(enabled: false) : agent;
        })
        .toList(growable: false);
  }

  /// True if at least one of [keywords] appears (case-insensitive substring
  /// match) in the last [scanDepth] entries of [historyContents]. When
  /// [scanDepth] is 0 or negative, scans the entire list. When [keywords]
  /// is empty, returns true (always activate).
  static bool matchesActivationKeywords(
    List<String> keywords,
    List<String> historyContents,
    int scanDepth,
  ) {
    if (keywords.isEmpty) return true;
    if (historyContents.isEmpty) return false;
    final effectiveDepth = scanDepth <= 0 ? historyContents.length : scanDepth;
    final start = historyContents.length - effectiveDepth;
    final window = historyContents.sublist(start < 0 ? 0 : start);
    final loweredKeywords = keywords
        .map((k) => k.trim().toLowerCase())
        .where((k) => k.isNotEmpty)
        .toList();
    if (loweredKeywords.isEmpty) return true;
    for (final content in window) {
      final lowered = content.toLowerCase();
      for (final keyword in loweredKeywords) {
        if (lowered.contains(keyword)) return true;
      }
    }
    return false;
  }

  /// Feature 6 — split a sorted (by `order`) list of enabled agents into the
  /// three pipeline phases.
  ///
  /// Rules:
  /// - Each agent's `phase` is first normalized via
  ///   [StudioAgent.normalizeAgentPhaseForType] (currently a no-op).
  /// - `postGenTrackers` = agents whose normalized phase is `'post_processing'`.
  /// - `preGenTrackers` = agents whose normalized phase is `'pre_generation'`,
  ///   EXCLUDING the final generator.
  /// - `finalAgent` = the LAST enabled pre-gen agent (the generator).
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
      // Last pre-gen agent = generator; the rest are pre-gen trackers.
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
