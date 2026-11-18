import '../../models/agent_definition.dart';
import '../../models/chat_message.dart';

/// Which agents run on one reply, and in what order. Built once at the start
/// of a turn and never changed during it (`docs/INVARIANTS.md` INV-AG1).
class AgentTurnPlan {
  /// Pre-generation agents grouped into waves: an agent runs in a later wave
  /// than every agent whose result it reads (`seesOutputsOf`).
  final List<List<AgentDefinition>> preGenerationWaves;
  final List<AgentDefinition> parallel;
  final List<AgentDefinition> postProcessing;

  const AgentTurnPlan({
    this.preGenerationWaves = const [],
    this.parallel = const [],
    this.postProcessing = const [],
  });

  static const empty = AgentTurnPlan();

  List<AgentDefinition> get preGeneration => [
    for (final wave in preGenerationWaves) ...wave,
  ];

  List<AgentDefinition> get all => [
    ...preGeneration,
    ...parallel,
    ...postProcessing,
  ];

  bool get isEmpty =>
      preGenerationWaves.isEmpty && parallel.isEmpty && postProcessing.isEmpty;

  /// The post agent of [builtinKind], if it runs this turn.
  AgentDefinition? builtin(String builtinKind) => postProcessing
      .where((agent) => agent.builtinKind == builtinKind)
      .firstOrNull;

  /// The plan for the reply that follows [history] in a chat where [enabled]
  /// agents are switched on (bindings already applied, library order).
  static AgentTurnPlan build({
    required List<AgentDefinition> enabled,
    required List<ChatMessage> history,
  }) {
    final turnNumber = replyNumber(history);
    var due = [
      for (final agent in enabled)
        if (_validShape(agent) && agentDue(agent, history, turnNumber)) agent,
    ];
    due = _withDependencies(due);
    return AgentTurnPlan(
      preGenerationWaves: _waves([
        for (final agent in due)
          if (agent.phase == AgentPhase.preGeneration) agent,
      ]),
      parallel: [
        for (final agent in due)
          if (agent.phase == AgentPhase.parallel) agent,
      ],
      postProcessing: [
        for (final agent in due)
          if (agent.phase == AgentPhase.postProcessing) agent,
      ],
    );
  }

  /// 1-based number of the reply about to be written: replies already in the
  /// chat (error bubbles excluded) plus one.
  static int replyNumber(List<ChatMessage> history) =>
      history
          .where((m) => m.role == 'assistant' && !m.isError && !m.isTyping)
          .length +
      1;

  /// Whether [agent]'s cadence lets it run on reply [turnNumber].
  static bool agentDue(
    AgentDefinition agent,
    List<ChatMessage> history,
    int turnNumber,
  ) {
    final everyN = agent.cadence.everyN < 1 ? 1 : agent.cadence.everyN;
    if (everyN > 1 && turnNumber % everyN != 0) return false;
    final keywords = [
      for (final keyword in agent.cadence.keywords)
        if (keyword.trim().isNotEmpty) keyword.trim().toLowerCase(),
    ];
    if (keywords.isEmpty) return true;
    final depth = agent.cadence.scanDepth < 1 ? 1 : agent.cadence.scanDepth;
    final visible = history.where((m) => !m.isHidden && !m.isError).toList();
    final scanned = visible.length <= depth
        ? visible
        : visible.sublist(visible.length - depth);
    final text = scanned.map((m) => m.content.toLowerCase()).join('\n');
    return keywords.any(text.contains);
  }

  /// A result type the phase cannot carry, or a built-in engine on the wrong
  /// result type, never runs.
  static bool _validShape(AgentDefinition agent) {
    if (!AgentResultType.allowedFor(agent.phase).contains(agent.resultType)) {
      return false;
    }
    if (agent.phase != AgentPhase.postProcessing) return true;
    // Post agents run on a built-in engine; a user agent may borrow the Post
    // Clean engine (text_rewrite) with its own prompt.
    return switch (agent.resultType) {
      AgentResultType.textRewrite => true,
      AgentResultType.ledgerUpdate => agent.builtinKind == AgentBuiltin.tracker,
      AgentResultType.cardUpdateProposal =>
        agent.builtinKind == AgentBuiltin.cardRewriter,
      _ => false,
    };
  }

  /// Drops agents whose dependencies do not run this turn, until stable.
  static List<AgentDefinition> _withDependencies(List<AgentDefinition> due) {
    var current = due;
    while (true) {
      final ids = {for (final agent in current) agent.id};
      final next = [
        for (final agent in current)
          if (agent.dependsOn.every(ids.contains)) agent,
      ];
      if (next.length == current.length) return next;
      current = next;
    }
  }

  /// Orders [agents] into waves by `seesOutputsOf`. Edges to agents outside the
  /// set are ignored; a cycle puts its members into one last wave.
  static List<List<AgentDefinition>> _waves(List<AgentDefinition> agents) {
    if (agents.isEmpty) return const [];
    final ids = {for (final agent in agents) agent.id};
    final placed = <String>{};
    final waves = <List<AgentDefinition>>[];
    var remaining = [...agents];
    while (remaining.isNotEmpty) {
      final wave = [
        for (final agent in remaining)
          if (agent.seesOutputsOf
              .where(ids.contains)
              .where((id) => id != agent.id)
              .every(placed.contains))
            agent,
      ];
      if (wave.isEmpty) {
        waves.add(remaining);
        break;
      }
      waves.add(wave);
      placed.addAll(wave.map((agent) => agent.id));
      remaining = [
        for (final agent in remaining)
          if (!placed.contains(agent.id)) agent,
      ];
    }
    return waves;
  }
}
