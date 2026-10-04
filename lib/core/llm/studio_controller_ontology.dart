import '../models/studio_config.dart';

/// One hard-coded agent spec slot — the fixed identity an agent is born from.
class StudioControllerSpec {
  final String id;
  final String name;
  final String purpose;
  final String outputContract;
  final String laneOwns;
  final String laneSkip;
  final String refreshPolicy;
  final double temperature;
  final int maxTokens;
  final int timeoutMs;
  final bool isFinal;
  final String phase;
  final int contextSize;
  final bool lockedOn;
  final String? requiresSpecId;

  const StudioControllerSpec({
    required this.id,
    required this.name,
    required this.purpose,
    required this.outputContract,
    required this.laneOwns,
    required this.laneSkip,
    required this.refreshPolicy,
    required this.temperature,
    required this.maxTokens,
    required this.timeoutMs,
    this.isFinal = false,
    this.phase = 'pre_generation',
    this.contextSize = 0,
    this.lockedOn = false,
    this.requiresSpecId,
  });
}

/// The fixed set of Studio controller lanes + lookup helpers. Each lane is a
/// stable tracker target; agents are created by `buildDefaultAgents` and
/// blocks are routed by `targetAgentId`.
class StudioControllerOntology {
  StudioControllerOntology._();

  /// All controller lanes, in pipeline order (the last one is the final
  /// generator). `buildDefaultAgents` creates one agent per spec.
  static const List<StudioControllerSpec> specs = <StudioControllerSpec>[
    StudioControllerSpec(
      id: 'continuity',
      name: 'Continuity Controller',
      purpose:
          'Track source-of-truth facts, recent chat state, unresolved threads, who knows what, and contradictions to avoid.',
      outputContract:
          'At chat time, output a compact continuity brief only: facts, constraints, risks, and next-turn continuity notes. No scene prose.',
      laneOwns:
          'established facts, who-knows-what, unresolved threads, physical-object/state continuity, and contradictions to avoid.',
      laneSkip:
          'prose style, pacing, length, dialogue cadence, repetition/anti-loop bans, NPC/world activity, and user-agency rules.',
      refreshPolicy: 'turn',
      temperature: 0.3,
      maxTokens: 1600,
      timeoutMs: 60000,
      requiresSpecId: 'ledger',
    ),
    StudioControllerSpec(
      id: 'agency',
      name: 'Agency & Character Controller',
      purpose:
          'Enforce user sovereignty, character autonomy, character psychology, subjective knowledge, and believable behavior.',
      outputContract:
          'At chat time, output actionable constraints for user agency and character behavior. No scene prose, no drafted actions, no dialogue. You may add an optional "Options" list of 1-3 branchable character-behavior approaches the final writer can pick from (describe the approach only, e.g. "let the character deflect" vs "let a crack of honesty show"); never write ready-made lines or actions.',
      laneOwns:
          'user sovereignty (never write the user) and character autonomy/psychology: what a character can plausibly know, feel, and do this turn.',
      laneSkip:
          'plain factual continuity, prose style/length, dialogue formatting, repetition bans, and ambient world/NPC texture.',
      refreshPolicy: 'turn',
      temperature: 0.3,
      maxTokens: 1400,
      timeoutMs: 60000,
    ),
    StudioControllerSpec(
      id: 'dialogue',
      name: 'Dialogue Controller',
      purpose:
          'Control dialogue cadence, speech texture, monologue segmentation, interaction balance, and when silence is appropriate. Your job is dialogue RATIO and TEXTURE — you do NOT decide beat type or paragraph budget (that is the Narrative Controller\'s lane). Provide a dialogue ratio that is compatible with the scene\'s actual beat: action beats can still be dialogue-heavy (characters talk while moving/riding/fighting); a high dialogue ratio does NOT downgrade an action beat into a short conversational one.',
      outputContract:
          'At chat time, output dialogue guidance only: who may plausibly speak, desired dialogue ratio (low / medium / high — relative to the beat, not absolute), speech constraints, and silence constraints. State the ratio as a proportion of the response that should be spoken lines vs physical action/narration, compatible with whatever beat type the Narrative Controller chose. No drafted lines. You may add an optional "Options" list of 1-3 branchable dialogue approaches the final writer can pick from (describe the approach only, e.g. "answer with silence and a gesture" vs "give one clipped deflecting line"); never write the actual dialogue.',
      laneOwns:
          'dialogue cadence only: who may plausibly speak, speech ratio (low/medium/high relative to the beat), silence, and quoting/formatting of speech. A high dialogue ratio does NOT downgrade an action beat into a short conversational one — action beats can be dialogue-heavy.',
      laneSkip:
          'factual continuity, character knowledge/psychology, prose length/pacing, repetition bans, and world/NPC activity.',
      refreshPolicy: 'turn',
      temperature: 0.3,
      maxTokens: 1200,
      timeoutMs: 60000,
    ),
    StudioControllerSpec(
      id: 'guard_ru',
      name: 'Anti-Loop & Prose Guard (RU)',
      purpose:
          'Enforce anti-loop, anti-echo, banlists, anti-cliche, anti-slop, no-tells, and stable Russian prose quality rules.',
      outputContract:
          'At chat time, output a compact guard checklist and forbidden items for this turn. Focus on Russian-language prose quality. No rewritten scene prose.',
      laneOwns:
          'anti-repetition for Russian prose: forbidden openings/phrases vs the last replies, banned cliches/slop words, and safe structural variation this turn. Structural variation must never force {{user}} movement, decisions, reactions, silence, or other user-controlled progression.',
      laneSkip:
          'plot facts, character psychology, agency, pacing targets, dialogue content, and world/NPC texture.',
      refreshPolicy: 'turn',
      temperature: 0.2,
      maxTokens: 1400,
      timeoutMs: 60000,
    ),
    StudioControllerSpec(
      id: 'guard_en',
      name: 'Anti-Loop & Prose Guard (EN)',
      purpose:
          'Enforce anti-loop, anti-echo, banlists, anti-cliche, anti-slop, no-tells, and stable English prose quality rules.',
      outputContract:
          'At chat time, output a compact guard checklist and forbidden items for this turn. Focus on English-language prose quality. No rewritten scene prose.',
      laneOwns:
          'anti-repetition for English prose: forbidden openings/phrases vs the last replies, banned cliches/slop words, and safe structural variation this turn. Structural variation must never force {{user}} movement, decisions, reactions, silence, or other user-controlled progression.',
      laneSkip:
          'plot facts, character psychology, agency, pacing targets, dialogue content, and world/NPC texture.',
      refreshPolicy: 'turn',
      temperature: 0.2,
      maxTokens: 1400,
      timeoutMs: 60000,
    ),
    StudioControllerSpec(
      id: 'world',
      name: 'World / NPC Controller',
      purpose:
          'Control living-world texture, NPC ecology, offscreen pressure, public-space activity, and background consequences without stealing focus.',
      outputContract:
          'At chat time, output world/NPC guidance only: active NPCs, off-focus thread, environmental pressure, and what not to add. No prose. You may add an optional "Options" list of 1-3 branchable world-texture approaches the final writer can pick from (describe the approach only, e.g. "let an offscreen sound intrude" vs "keep the world still and pressureless"); never write ready-made prose.',
      laneOwns:
          'living-world texture only: active NPCs, off-screen pressure, environmental/ambient activity, and what world detail NOT to add.',
      laneSkip:
          'the two leads\' psychology, factual continuity, prose style/length, dialogue formatting, and repetition bans.',
      refreshPolicy: 'turn',
      temperature: 0.3,
      maxTokens: 1200,
      timeoutMs: 60000,
    ),
    StudioControllerSpec(
      id: 'meta',
      name: 'Meta-Weaver / OOC Policy',
      purpose:
          'Meta-weaver / OOC interface controller. Runs EVERY turn when the preset has a meta/OOC block assigned. Counts assistant messages in the history it sees, applies the period rule from the assigned meta block (e.g. "Every 4 assistant responses"), and decides whether the meta-persona should emit an OOC note this turn, respond to an explicit OOC address, or stay silent. The meta-persona\'s name, voice, length, and format are all defined by the user\'s preset block — the controller does NOT hardcode any persona.',
      outputContract:
          'At chat time, output a compact meta brief ONLY. Decide one of: '
          '`meta_ooc: due | topic: <X>` (user addressed the meta-persona OOC), '
          '`meta_periodic_note: due | last_note: <N turns ago> | voice: <from block> | length: <from block> | format: <from block>` (the Nth assistant turn fired the period rule — relay the voice/length/format/wrapper from the assigned meta block so the Main Writer writes in the user\'s chosen style), '
          'or `meta: silent` (neither condition met). Never write in-scene prose, never write the actual OOC reply — that is the Main Writer\'s job, guided by your brief.',
      laneOwns: 'only this controller\'s configured specialty.',
      laneSkip: 'concerns that belong to the other Studio controllers.',
      refreshPolicy: 'turn',
      temperature: 0.2,
      maxTokens: 1200,
      timeoutMs: 60000,
    ),
    StudioControllerSpec(
      id: 'final',
      name: 'Main Writer',
      purpose:
          'Write the final visible RP response using the full prompt and the prior controller briefs.',
      outputContract:
          'At chat time, output only the final visible RP response. Obey all controller briefs and final formatting/content constraints.',
      laneOwns: 'the final response prose — all scene writing, dialogue, narration, and action.',
      laneSkip: 'analysis, tracking, constraint checking — those belong to the pre-generation agents.',
      refreshPolicy: 'turn',
      temperature: 0.8,
      maxTokens: 8000,
      timeoutMs: 90000,
      isFinal: true,
      lockedOn: true,
    ),
    StudioControllerSpec(
      id: 'post_clean',
      name: 'Post Clean',
      purpose: 'Audit the final response for factual errors and cliches, then rewrite it cleanly. Applies styling state from the current beauty state.',
      outputContract: 'Output the cleaned/rewritten assistant message. Append a <glaze_beauty_state> JSON marker if styling state changed.',
      laneOwns: 'factual accuracy, cliche/echo removal, prose cleanup, and styling application.',
      laneSkip: 'scene content, character decisions, dialogue substance — the Main Writer already wrote those.',
      refreshPolicy: 'turn',
      temperature: 0.3,
      maxTokens: 8000,
      timeoutMs: 90000,
      phase: 'post_processing',
    ),
    StudioControllerSpec(
      id: 'ledger',
      name: 'Studio Ledger',
      purpose: 'Track session-level state: present characters, location, time, unresolved threads, and key facts — a canonical source of truth for continuity.',
      outputContract: 'Output a compact session-state delta (present now, location, time, facts, threads). Used by Continuity and available as {{studio_session_state}}.',
      laneOwns: 'session-level canonical state: who is present, where, when, what facts are established, and which threads are open.',
      laneSkip: 'scene prose, dialogue, character psychology, pacing — those belong to the other agents.',
      refreshPolicy: 'turn',
      temperature: 0.2,
      maxTokens: 1600,
      timeoutMs: 60000,
      phase: 'post_processing',
    ),
  ];

  /// Build the default fixed Studio controller agents for a session.
  ///
  /// Kept here so Studio creation, rebuild, and legacy empty-config recovery
  /// all use the same agent set.
  static List<StudioAgent> buildDefaultAgents({
    required String sessionId,
    required int now,
  }) {
    final agents = <StudioAgent>[];
    for (var i = 0; i < specs.length; i++) {
      final spec = specs[i];
      agents.add(
        StudioAgent(
          id: 'agent_${sessionId}_${spec.id}_$now',
          controllerId: spec.id,
          name: spec.name,
          role: 'system',
          order: i,
          enabled: spec.id != 'meta',
          refreshPolicy: spec.refreshPolicy,
          phase: spec.phase,
          specId: spec.id,
        ),
      );
    }
    return agents;
  }

  /// Trailing chat messages a controller is handed. Specs that leave it at 0
  /// fall back to the pipeline default of 5. Accepts a nullable spec for
  /// convenience with [specForAgent].
  static int contextSizeOf(StudioControllerSpec? spec) =>
      spec != null && spec.contextSize > 0 ? spec.contextSize : 5;

  /// Map an existing agent back to its controller spec. Prefers the agent's
  /// [StudioAgent.specId], then its [StudioAgent.controllerId]; returns null
  /// when neither maps to a known spec (e.g. legacy/unknown agents).
  static StudioControllerSpec? specForAgent(StudioAgent agent) {
    if (agent.specId.isNotEmpty) {
      final match = specs.where((s) => s.id == agent.specId).firstOrNull;
      if (match != null) return match;
    }
    for (final spec in specs) {
      if (spec.id == agent.controllerId) return spec;
    }
    return null;
  }

  /// Stable controller target for canonical Studio block routing.
  static String? targetIdForAgent(StudioAgent agent) {
    return specForAgent(agent)?.id;
  }
}
