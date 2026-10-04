import '../models/api_config.dart';
import '../models/studio_config.dart';
import 'agent_runner.dart';
import 'studio_turn_config_snapshot.dart';
import 'concurrency_limiter.dart';
import 'controller_batch_protocol.dart';
import 'studio_controller_ontology.dart';

/// Concurrency limits for the tracker phase (Phase 5.7.2).
///
/// Conservative defaults for desktop (Marinara runs 8/4/4 on a server-backed
/// web app; on desktop a single user hitting one provider with 8 concurrent
/// SSE streams is a real rate-limit risk). Tunable constants so we can open
/// them up later without a code change.
const _maxConcurrentGroups = 4;

/// Heuristic name patterns for trackers that must run individually (Phase
/// 5.2). Port of Marinara `shouldRunAgentIndividually`. Matched against the
/// agent's `name` (case-insensitive substring). When matched, the tracker is
/// pulled out of its batch group and run as its own request — its large
/// private extras (e.g. an expression-picker's image gen preamble) must not
/// leak into other trackers' batch prompt.
const _individualNamePatterns = <String>[
  'expression',
  'illustrator',
  'lorebook',
];

/// Result of [ControllerBatcher.groupAgents]: the batchable trackers split into
/// [batchGroups] (each group → one LLM request) and the isolated trackers
/// [individualAgents] (each → its own request).
class ControllerGrouping {
  final List<ControllerBatchGroup> batchGroups;
  final List<StudioAgent> individualAgents;

  const ControllerGrouping({
    required this.batchGroups,
    required this.individualAgents,
  });
}

/// A batch group: trackers sharing `(provider, model)` and none matched by
/// [ControllerBatcher.shouldRunIndividually].
///
/// All agents in a group are sent to the LLM as ONE request —
/// [buildBatchMessages] packs their per-agent instructions into `<agent_task>`
/// XML inside a single system prompt; the model returns one `<result>` block
/// per agent, which [parseBatchResponse] splits back into individual tracker
/// outputs.
class ControllerBatchGroup {
  /// Batch grouping key: `"$provider|$model"`. Agents with different
  /// providers/models cannot be batched (different endpoints/auth/shape).
  final String key;
  final ResolvedAgentConfig resolved;
  final List<StudioAgent> agents;

  /// Sum of the agents' spec `maxTokens` across the group, capped by
  /// `resolved.maxTokens` (the provider's configured cap). See
  /// [ControllerBatcher._capBatchMaxTokens] — a long batch must not get
  /// truncated mid-stream and lose half of the `<result>` blocks.
  final int batchMaxTokens;

  /// MIN of the agents' spec temperature across the group. Lowest wins
  /// (trackers should be deterministic; a high-temp agent should not drag
  /// the whole batch into randomness).
  final double batchTemperature;

  /// Tracker context size = MAX across the group (Phase 5 design choice).
  /// Each tracker in the batch sees the same shared `chat_history`; using
  /// the max ensures the agent with `contextSize=20` still gets its 20
  /// messages (the agent with `contextSize=5` simply sees more, which is
  /// safe — extra context is not harmful for trackers).
  final int batchContextSize;

  const ControllerBatchGroup({
    required this.key,
    required this.resolved,
    required this.agents,
    required this.batchMaxTokens,
    required this.batchTemperature,
    required this.batchContextSize,
  });
}

/// One tracker's outcome after a batch run + fallback.
class ControllerBatchResult {
  final String agentId;
  final String agentName;
  final String text;
  final String status; // 'ok' | 'failed'
  final String? error;

  const ControllerBatchResult({
    required this.agentId,
    required this.agentName,
    required this.text,
    required this.status,
    this.error,
  });

  static ControllerBatchResult failed({
    required String agentId,
    required String agentName,
    required String reason,
  }) {
    return ControllerBatchResult(
      agentId: agentId,
      agentName: agentName,
      text: '',
      status: 'failed',
      error: reason,
    );
  }
}

/// Batching layer for pre-generation trackers (Phase 5.1).
///
/// Owns:
/// - Grouping trackers by `(provider, model)` and isolating "heavy" ones
///   (Phase 5.2).
/// - Building the `<agents><agent_task id="...">...</agent_task></agents>`
///   batch system prompt (shared `<role>` + `<lore>` + per-agent tasks +
///   required `<result agent="...">` output format).
/// - Parsing the model's batched reply into one [ControllerBatchResult] per
///   agent (with legacy `<result_TYPE>` fallback).
/// - Concurrency-limited settling (Phase 5.7.2) and the in-batch invalid-JSON
///   retry + individual-fallback chain (Phase 5.1 layers 1+2).
///
/// Does NOT own: prompt macro expansion (caller passes already-expanded
/// per-agent task text), caching (caller's `MemoryStudioService`), or the
/// final-generator run (separate path).
class ControllerBatcher {
  /// Optional — only required for [groupAgents] / [runPhase] which resolve
  /// per-agent API configs and fire live LLM calls. Pure prompt-building,
  /// parsing, [shouldRunIndividually], [normalizeMaxParallelJobs] and
  /// [splitGroupForParallelJobs] work without a runner (used by unit tests).
  final AgentRunner? _runner;
  final ControllerBatchProtocol _protocol = const ControllerBatchProtocol();

  ControllerBatcher([this._runner]);

  /// Heuristic: should this tracker run as its own individual request,
  /// never batched? (Phase 5.2). Returns true when the agent's name matches
  /// one of [_individualNamePatterns].
  bool shouldRunIndividually(StudioAgent agent) {
    final lower = agent.name.toLowerCase();
    for (final pattern in _individualNamePatterns) {
      if (lower.contains(pattern)) return true;
    }
    return false;
  }

  /// Group trackers into batches. Agents with [shouldRunIndividually] = true
  /// are returned in [individualAgents]; the rest are batched by
  /// `(provider, model)` in [batchGroups]. Order within a group is preserved
  /// (sorted by `agent.order`).
  ///
  /// [apiConfigId] — the StudioConfig slot id to use for resolution (e.g.
  /// `cheapApiConfigId` for trackers). When null/empty, falls back to
  /// the active chat config when the explicit controller slot is empty.
  Future<ControllerGrouping> groupAgents({
    required List<StudioAgent> agents,
    required ApiConfig apiConfig,
    required String sessionId,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
  }) async {
    final sorted = agents.toList()..sort((a, b) => a.order.compareTo(b.order));
    final individual = <StudioAgent>[];
    final batchable = <StudioAgent>[];
    for (final agent in sorted) {
      if (shouldRunIndividually(agent)) {
        individual.add(agent);
      } else {
        batchable.add(agent);
      }
    }

    // Resolve config for each batchable agent, then group by (provider, model).
    if (_runner == null) {
      throw StateError(
        'ControllerBatcher.groupAgents requires an AgentRunner — construct with '
        'a non-null runner.',
      );
    }
    final runner = _runner;
    final groups = <String, List<StudioAgent>>{};
    final resolvedByKey = <String, ResolvedAgentConfig>{};
    for (final agent in batchable) {
      final resolved = await runner.resolveAgentConfig(
        agent,
        apiConfig,
        sessionId,
        apiConfigId: apiConfigId,
        turnConfig: turnConfig,
      );
      // Feature 6 — postProcessingDataKey: the grouping key now includes
      // the agent's `phase`. A pre-generation tracker and a post-processing
      // tracker on the same `(provider, model)` must NOT be batched together:
      // the post-processing one receives the generator's `mainResponse` in
      // its context, while the pre-gen one does not — batching them would
      // produce a single shared prompt that is wrong for at least one of
      // them. All pre-gen agents share the `|pre_generation` suffix (uniform,
      // so they group exactly as before); all post-gen agents share
      // `|post_processing`. Port of Marinara `postProcessingDataKey`.
      final key = '${resolved.protocol}|${resolved.model}|${agent.phase}';
      groups.putIfAbsent(key, () => []).add(agent);
      resolvedByKey[key] = resolved;
    }

    final batchGroups = <ControllerBatchGroup>[];
    for (final entry in groups.entries) {
      final resolved = resolvedByKey[entry.key]!;
      final groupAgents = entry.value;
      batchGroups.add(
        ControllerBatchGroup(
          key: entry.key,
          resolved: resolved,
          agents: groupAgents,
          batchMaxTokens: _capBatchMaxTokens(groupAgents, resolved),
          batchTemperature: _minTemperature(groupAgents),
          batchContextSize: _maxContextSize(groupAgents),
        ),
      );
    }
    return ControllerGrouping(
      batchGroups: batchGroups,
      individualAgents: individual,
    );
  }

  /// Batch max-tokens budget: SUM of per-agent `maxTokens`, capped by the
  /// provider's resolved `maxTokens` (Phase 5.1). If the sum exceeds the cap,
  /// the cap wins — the model will produce a shorter batch and we rely on
  /// the individual-fallback layer to recover any truncated `<result>`
  /// blocks. The cap is `resolved.contextSize` * a safety factor would be
  /// wrong; `ApiConfig.maxTokens` is already the output cap the user picked.
  int _capBatchMaxTokens(
    List<StudioAgent> agents,
    ResolvedAgentConfig resolved,
  ) {
    final sum = agents.fold<int>(
      0,
      (acc, a) => acc + (StudioControllerOntology.specForAgent(a)?.maxTokens ?? 8000),
    );
    // Glaze has no separate `maxOutputTokens` field on the model;
    // `ApiConfig.maxTokens` is the single output cap. Use it as the ceiling.
    // 0 or negative = uncapped (very large); treat as no cap.
    final cap = resolved.contextSize > 0 ? resolved.contextSize : 1 << 30;
    // The output budget must never exceed what the provider will accept as
    // `max_tokens` in the body — so we also clamp by `ApiConfig.maxTokens`
    // (the spec's maxTokens, but the resolved ApiConfig
    // value is the source of truth for the batch request).
    // Per-agent cap from the spec; the SUM is what we actually send.
    final apiCap = StudioControllerOntology
        .specForAgent(agents.first)?.maxTokens ?? 8000;
    // Final ceiling: the smaller of (provider context cap / 2) and (sum).
    // Half the context window is a sane max for output — the rest is input.
    final outputCeiling = cap ~/ 2;
    return sum.clamp(1, outputCeiling > 0 ? outputCeiling : apiCap * 4);
  }

  double _minTemperature(List<StudioAgent> agents) {
    if (agents.isEmpty) return 0.3;
    return agents
        .map((a) => StudioControllerOntology.specForAgent(a)?.temperature ?? 0.3)
        .reduce((a, b) => a < b ? a : b);
  }

  int _maxContextSize(List<StudioAgent> agents) {
    if (agents.isEmpty) return 5;
    return agents
        .map(
          (a) => StudioControllerOntology.contextSizeOf(
            StudioControllerOntology.specForAgent(a),
          ),
        )
        .reduce((a, b) => a > b ? a : b)
        .clamp(1, 200);
  }

  /// Clamp `maxParallelJobs` to `[1, 16]` (Marinara `normalizeAgentMaxParallelJobs`).
  /// 0 or negative → 1, >16 → 16.
  int normalizeMaxParallelJobs(int value) {
    return value < 1 ? 1 : (value > 16 ? 16 : value);
  }

  /// Split a batch group into [maxParallelJobs] parallel sub-groups (Phase
  /// 5.7.3). For MVP this is effectively a no-op: when `maxParallelJobs=1`
  /// (the default and only sensible value without further work) the group
  /// is returned unchanged — it becomes one LLM request. When `>1`, the
  /// group's agents are split into N roughly-equal sub-groups, each run as
  /// its OWN LLM request in parallel (concurrency-limited by the phase
  /// cap). The per-sub-group budget is reduced proportionally.
  ///
  /// The caller (`MemoryStudioService`) handles the actual parallel dispatch
  /// — this method only computes the split. Returns one or more groups.
  List<ControllerBatchGroup> splitGroupForParallelJobs(ControllerBatchGroup group) {
    final maxJobs = normalizeMaxParallelJobs(
      group.agents.first.maxParallelJobs,
    );
    if (maxJobs == 1 || group.agents.length <= 1) {
      return [group];
    }
    // Split agents into maxJobs roughly-equal chunks. Each chunk becomes a
    // sub-group with its own (proportional) budget. The batch temperature
    // and context size stay the same (they're aggregate MIN/MAX of the
    // original group, safe to reuse for any sub-group).
    final chunkSize = (group.agents.length / maxJobs).ceil();
    final subGroups = <ControllerBatchGroup>[];
    for (var i = 0; i < group.agents.length; i += chunkSize) {
      final chunk = group.agents.sublist(
        i,
        (i + chunkSize).clamp(0, group.agents.length),
      );
      if (chunk.isEmpty) break;
      subGroups.add(
        ControllerBatchGroup(
          key: '${group.key}#$i',
          resolved: group.resolved,
          agents: chunk,
          batchMaxTokens: _capBatchMaxTokens(chunk, group.resolved),
          batchTemperature: group.batchTemperature,
          batchContextSize: group.batchContextSize,
        ),
      );
    }
    return subGroups;
  }

  /// Build the batched system prompt for a group. Layout (Phase 5.1 +
  /// Phase 6.1 — prompt-cache-friendly order):
  /// ```
  /// <role>{shared role text}</role>            ← stable, cached first
  /// <lore>{shared static + dynamic + history}</lore>  ← stable prefix
  /// <agents>                                    ← per-agent, volatile, last
  ///   <agent_task id="{agent.id}" name="{agent.name}">{task text}</agent_task>
  ///   ...
  /// </agents>
  /// ─── REQUIRED OUTPUT FORMAT ───
  /// <result agent="{agent.id}">...</result>
  /// ```
  ///
  /// Cache rationale (Phase 6.1): the shared `<role>` + `<lore>` (char card,
  /// persona, lorebooks, MemoryBook injection) are identical across turns for
  /// the same character, so they form a stable prefix that the provider's
  /// prompt cache (Anthropic ephemeral / OpenRouter `cache_control`) can hit
  /// on the second turn onwards. The per-agent `<agent_task>` content varies
  /// per turn (lane contract, current shard expansion), so it sits at the
  /// tail — never inside the cached prefix.
  ///
  /// [sharedMessages] = the shared `static_context` + `dynamic_context` +
  /// `chat_history` messages, already built and trimmed by the caller. They
  /// are flattened into `<lore>` text (role: "user"/"assistant" preserved as
  /// `Role: ...` prefix lines).
  ///
  /// [perAgentTaskText] = a map of `agent.id` → already-expanded task text
  /// (the concatenation of `agent.promptShard` + the preset's
  /// `agent_instruction` block content + the runtime envelope). XML-escaping
  /// is applied here.
  String buildBatchSystemPrompt({
    required ControllerBatchGroup group,
    required List<Map<String, dynamic>> sharedMessages,
    required Map<String, String> perAgentTaskText,
    required String roleText,
  }) => _protocol.buildBatchSystemPrompt(
    group: group,
    sharedMessages: sharedMessages,
    perAgentTaskText: perAgentTaskText,
    roleText: roleText,
  );

  /// Parse a batched model response into one [ControllerBatchResult] per agent
  /// in [group]. (Phase 5.1.)
  ///
  /// Strategy:
  /// 1. For each agent.id, find `<result agent="ID">...</result>` blocks.
  ///    The closing `</result>` may be missing on truncated outputs — in that
  ///    case, take everything up to the NEXT `<result` opening tag (or end of
  ///    text). This is the Marinara `extractResultBlocks` approach.
  /// 2. Fallback: if no `<result agent="ID">` block is found, try the legacy
  ///    `<result_ID>...</result_ID>` pattern (some models invent their own
  ///    tag format).
  /// 3. Any agent with no parseable block → empty text (will be marked
  ///    `failed` by the caller's invalid-JSON check or fall through to the
  ///    individual retry layer).
  List<ControllerBatchResult> parseBatchResponse(
    String raw,
    ControllerBatchGroup group,
  ) => _protocol.parseBatchResponse(raw, group);

  /// Run all batch groups + individual agents with a concurrency limit of
  /// [_maxConcurrentGroups] for batches. Individual agents run alongside,
  /// subject to the same overall phase limit (the limit applies to the SUM
  /// of in-flight requests, not per category).
  ///
  /// [runBatch] = caller-provided closure that runs ONE group and returns
  ///   its parsed [ControllerBatchResult]s. The closure is responsible for the
  ///   in-batch invalid-JSON retry (Phase 5.1 layer 1) and the individual
  ///   fallback for failed agents (layer 2). The batcher only enforces the
  ///   concurrency cap.
  /// [runIndividual] = caller-provided closure that runs ONE individual agent.
  Future<List<ControllerBatchResult>> runPhase({
    required List<ControllerBatchGroup> batchGroups,
    required List<StudioAgent> individualAgents,
    required Future<List<ControllerBatchResult>> Function(ControllerBatchGroup)
    runBatch,
    required Future<ControllerBatchResult> Function(StudioAgent) runIndividual,
  }) async {
    final jobs = <_PhaseJob>[];
    for (final group in batchGroups) {
      jobs.add(_PhaseJob(isBatch: true, batch: group));
    }
    for (final agent in individualAgents) {
      jobs.add(_PhaseJob(isBatch: false, agent: agent));
    }
    final settled = await _settleWithConcurrencyLimit(
      jobs: jobs,
      limit: _maxConcurrentGroups,
      runBatch: runBatch,
      runIndividual: runIndividual,
    );
    return settled;
  }

  /// Generic concurrency-limited gather (Phase 5.7.2). Runs at most [limit]
  /// jobs in flight at once. Port of Marinara `settleAgentJobsWithConcurrencyLimit`.
  ///
  /// Two type parameters: [I] = input item type, [R] = result type. This lets
  /// the caller map a `List<StudioAgent>` to `List<ControllerBatchResult>` etc.
  Future<List<R>> settleWithConcurrencyLimit<I, R>({
    required List<I> items,
    required int limit,
    required Future<R> Function(I item) run,
  }) => ConcurrencyLimiter.settle(items: items, limit: limit, run: run);

  Future<List<ControllerBatchResult>> _settleWithConcurrencyLimit({
    required List<_PhaseJob> jobs,
    required int limit,
    required Future<List<ControllerBatchResult>> Function(ControllerBatchGroup)
    runBatch,
    required Future<ControllerBatchResult> Function(StudioAgent) runIndividual,
  }) async {
    final chunkResults =
        await ConcurrencyLimiter.settle<_PhaseJob, List<ControllerBatchResult>>(
          items: jobs,
          limit: limit,
          run: (job) async {
            if (job.isBatch) {
              return runBatch(job.batch!);
            }
            return [await runIndividual(job.agent!)];
          },
        );
    return [for (final list in chunkResults) ...list];
  }
}

class _PhaseJob {
  final bool isBatch;
  final ControllerBatchGroup? batch;
  final StudioAgent? agent;

  const _PhaseJob({required this.isBatch, this.batch, this.agent})
    : assert(isBatch ? batch != null : agent != null);
}
