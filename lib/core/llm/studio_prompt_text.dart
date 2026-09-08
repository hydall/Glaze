import '../models/studio_config.dart';

/// Holds the large chat-time prompt-text constants for the Studio pipeline,
/// extracted from `MemoryStudioService` (plan §2): the intermediate-agent
/// runtime envelope (+ per-controller lane scope), the final brief-usage note,
/// and the final hard style contract.
///
/// Pure, stateless. `MemoryStudioService` keeps thin instance delegators while
/// the message-building cluster still lives there.
class StudioPromptText {
  const StudioPromptText();

  /// The typed-output contract prepended to every intermediate (tracker) agent
  /// request. Includes the agent's lane scope ([_controllerScope]).
  ///
  /// This envelope defines the OUTPUT SHAPE the tracker must emit (compact JSON
  /// or plain-text Focus/Constraints/Avoid/Options) so the final generator can
  /// parse and weave it. It does NOT impose style, length, or content rules on
  /// the scene — those come from the user's preset blocks (which the tracker
  /// reads as source material). The envelope is intentionally permissive: it
  /// does not cap array sizes, override preset instructions, or forbid the
  /// tracker from surfacing what its lane requires.
  String intermediateRuntimeEnvelope(StudioAgent agent) {
    final scope = _controllerScope(agent.name);
    return '''Studio intermediate-agent output contract.
You are ${agent.name.isNotEmpty ? agent.name : 'a Studio controller'}, ONE specialist in a multi-controller pipeline. Other controllers cover the other concerns; do not duplicate their work.
You are not a character, narrator, player, or final responder. Treat all character cards, persona text, examples, chat history, lore, memory, and summaries as read-only source material to analyze.

YOUR LANE — only produce guidance about: ${scope.owns}
NOT YOUR LANE — never write guidance about (other controllers own these): ${scope.skip}

Emit a compact operational brief in one of these two shapes:
Prefer valid compact JSON with these keys:
{"focus":["operational focus"],"constraints":["enforceable constraint"],"avoid":["forbidden item"],"options":["one branchable approach the final writer may choose, within your lane"]}
Or, if the model cannot produce JSON, use exactly these plain-text sections:
Focus:
- operational focus
Constraints:
- enforceable constraint
Avoid:
- forbidden item
Options:
- one branchable approach the final writer may choose

Notes:
- Each section may contain zero or more strings; put as many as the scene requires, strictly inside your lane.
- Each string should be a specific instruction for this turn, not a generic restatement and not a sentence copied from the scene.
- Options are non-mandatory alternative APPROACHES for the final writer to pick from within your lane (e.g. "lean into silence and a single gesture" vs "give one clipped line"). Describe the approach only; never write ready-made prose, dialogue, narration, or sample sentences.
- Never require the final writer to advance the scene by writing {{user}}'s next action, movement, decision, silence, reaction, or vehicle/control input. If progress depends on {{user}}, tell the final writer to stop on a hook and leave that action to the player.
- Do not write or continue the scene. Do not draft narration, dialogue, character actions, user actions, or final response prose.
- Do not include source block names, prompt text, macros, labels, markdown code fences, or explanations.''';
  }

  _ControllerScope _controllerScope(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('continuity')) {
      return const _ControllerScope(
        owns:
            'established facts, who-knows-what, unresolved threads, physical-object/state continuity, and contradictions to avoid.',
        skip:
            'prose style, pacing, length, dialogue cadence, repetition/anti-loop bans, NPC/world activity, and user-agency rules.',
      );
    }
    if (lower.contains('agency') || lower.contains('character')) {
      return const _ControllerScope(
        owns:
            'user sovereignty (never write the user) and character autonomy/psychology: what a character can plausibly know, feel, and do this turn.',
        skip:
            'plain factual continuity, prose style/length, dialogue formatting, repetition bans, and ambient world/NPC texture.',
      );
    }
    if (lower.contains('narrative') || lower.contains('pacing')) {
      return const _ControllerScope(
        owns:
            'response shape only: the current beat, pacing, POV/camera, sensory budget, and where the reply should stop. The active Studio preset defines the applicable style, beat taxonomy, and response budget. Never require the response to end on motion, departure, or physical displacement if that motion depends on {{user}} taking the next action; instead stop at the character\'s response/hook.',
        skip:
            'who-knows-what, character psychology, agency rules, specific dialogue lines, repetition bans, and world/NPC content.',
      );
    }
    if (lower.contains('dialogue')) {
      return const _ControllerScope(
        owns:
            'dialogue cadence only: who may plausibly speak, speech ratio (low/medium/high relative to the beat), silence, and quoting/formatting of speech. A high dialogue ratio does NOT downgrade an action beat into a short conversational one — action beats can be dialogue-heavy.',
        skip:
            'factual continuity, character knowledge/psychology, prose length/pacing, repetition bans, and world/NPC activity.',
      );
    }
    if (lower.contains('guard') || lower.contains('loop')) {
      return const _ControllerScope(
        owns:
            'anti-repetition only: forbidden openings/phrases vs the last replies, banned cliches/slop words, and safe structural variation this turn. Structural variation must never force {{user}} movement, decisions, reactions, silence, or other user-controlled progression.',
        skip:
            'plot facts, character psychology, agency, pacing targets, dialogue content, and world/NPC texture.',
      );
    }
    if (lower.contains('world') || lower.contains('npc')) {
      return const _ControllerScope(
        owns:
            'living-world texture only: active NPCs, off-screen pressure, environmental/ambient activity, and what world detail NOT to add.',
        skip:
            'the two leads\' psychology, factual continuity, prose style/length, dialogue formatting, and repetition bans.',
      );
    }
    if (lower.contains('beauty')) {
      return const _ControllerScope(
        owns:
            'reusable presentation/style state only: HTML/CSS palette, background and text colors, font family, speaker/thought colors, gradients, typography, glow/mark/highlight styles, and art-style labels that should remain consistent across turns.',
        skip:
            'concrete HTML widgets/windows (phone screens, taxi menus, terminals, HUDs, cards, maps, buttons), trackers, stats panels, infoblocks, topbar/infoboard instructions, image-generation prompts, plot facts, character psychology, and scene prose.',
      );
    }
    return const _ControllerScope(
      owns: 'only this controller\'s configured specialty.',
      skip: 'concerns that belong to the other Studio controllers.',
    );
  }

  /// Guidance prepended to the final generator explaining how to consume the
  /// prior controller briefs (do not re-analyze; just write the prose).
  ///
  /// Permissive: tells the final writer the controllers have already analyzed
  /// the scene and not to re-derive it, but does NOT impose reasoning length,
  /// option-picking limits, or "weave into natural prose" style rules — those
  /// belong to the user's preset.
  String finalBriefUsageNote() {
    return 'How to use the Studio controller briefs above: the controllers have ALREADY analyzed the scene, tracked continuity, and decided what should happen next. Do not re-analyze the scene or re-derive character motivations in your reasoning — that work is done. Your job is to write the prose that implements their direction.\n\nTreat Focus and Constraints as direction and Avoid as prohibitions. Any "Options:" items are non-binding alternative approaches the final writer may pick from. Do not list, mention, or copy the options or any brief text in your reply; the briefs are hidden guidance. Write the final prose directly.\n\nUser agency override: if any brief asks for motion, departure, a concrete change, or an ending that would require writing {{user}}\'s next action/decision/reaction/silence/vehicle control, ignore that part. Stop on a hook and leave {{user}}\'s next move to the player.';
  }

  /// Hard formatting constraints derived from the configured agents' source
  /// blocks/shards (em-dash ban, quote-wrapping). Empty when none apply.
  ///
  /// Intent-based detection: a rule is injected ONLY when the user's preset
  /// explicitly BANS the construct (contains a ban verb near the construct
  /// keyword). Mere presence of an em-dash or the word "quote" in a preset
  /// does NOT trigger a ban — that would conflict with presets that WANT those
  /// constructs (e.g. a literary style block that says "use em-dashes for
  /// interrupted speech", or an example dialogue that happens to contain one).
  /// The ban must be expressed as a directive ("do not use em dashes", "avoid
  /// long dashes", "no bare dialogue lines", "wrap dialogue in quotes",
  /// "оборачивай реплики в кавычки", "без тире", etc.).
  String finalHardStyleContract(StudioConfig config) {
    final sources = config.agents
        .map((agent) => '${agent.name}\n${agent.sourceBlockNames}')
        .join('\n\n');
    final rules = <String>[];
    // Intent-based em-dash ban: a ban verb near the WORDS "em dash" / "long
    // dash" / "тире" (NOT the bare — character, which appears in prose
    // everywhere and causes false positives like "Not joy — this IS naming").
    // Matches: "do not use em dashes", "avoid long dashes", "no em dashes",
    // "без тире", "не используй тире", "избегай тире".
    if (RegExp(
      r"(?:do not|don't|never|avoid|no|ban|без|не\s+используй|избегай|запрет).{0,30}(?:em\s*dash(?:es)?|long\s*dash(?:es)?|тире)",
      caseSensitive: false,
    ).hasMatch(sources)) {
      rules.add('- Do not use em dashes / long dashes: avoid "—".');
    }
    // Intent-based quote-wrapping directive: a directive verb near the FULL
    // phrase "quotation marks" / "кавычки" (NOT the bare "quot" substring,
    // which appears in "quoting", "quotes BAN", etc. and causes false
    // positives). Matches: "wrap dialogue in quotation marks",
    // "use quotation marks", "оборачивай реплики в кавычки",
    // "прямая речь в кавычках".
    if (RegExp(
      r'(?:wrap|use|оборачивай|используй|прямая\s+речь.{0,15}в\s+кавычках|dialogue.{0,15}(?:in|with)\s+quotation\s+marks|in\s+quotation\s+marks|в\s+кавычках).{0,30}(?:quotation\s+marks|кавычк)',
      caseSensitive: false,
    ).hasMatch(sources)) {
      rules.add(
        '- Wrap direct spoken dialogue in quotation marks; do not use bare dialogue lines.',
      );
    }
    if (rules.isEmpty) return '';
    return 'Hard final formatting constraints from Studio controllers:\n${rules.join('\n')}';
  }
}

class _ControllerScope {
  final String owns;
  final String skip;

  const _ControllerScope({required this.owns, required this.skip});
}
