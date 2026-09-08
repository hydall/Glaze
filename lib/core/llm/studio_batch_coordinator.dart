import 'package:dio/dio.dart';

import '../models/api_config.dart';
import '../models/studio_config.dart';
import '../utils/error_format.dart';
import 'agent_runner.dart';
import 'prompt_builder.dart';
import 'studio_agent_executor.dart';
import 'studio_context_bucketizer.dart';
import 'studio_message_builder.dart';
import 'tracker_batcher.dart';
import 'studio_turn_config_snapshot.dart';

/// Runs a batch group of Studio chat-time trackers: builds the batched
/// system prompt + per-agent task text, fires a single LLM request, parses
/// the `<result>` blocks, and retries the whole batch twice before surfacing
/// tracker failures to the Studio pipeline. Extracted from `MemoryStudioService`
/// (plan §2.9).
///
/// Deps: the injected [TrackerBatcher], [AgentRunner],
/// [StudioContextBucketizer], [StudioMessageBuilder], and
/// [StudioAgentExecutor]. `_log` is injected as a callback so this specialist
/// does not own the host's debug-print sink.
class StudioBatchCoordinator {
  final TrackerBatcher _batcher;
  final AgentRunner _runner;
  final StudioContextBucketizer _bucketizer;
  final StudioMessageBuilder _messageBuilder;
  final StudioAgentExecutor _executor;
  final void Function(String message) _log;

  StudioBatchCoordinator(
    this._batcher,
    this._runner,
    this._bucketizer,
    this._messageBuilder,
    this._executor,
    this._log,
  );

  /// [batchContextSize] = max contextSize across the group), per-agent task
  /// text, the batched system prompt, fire a single LLM request, parse the
  /// `<result>` blocks, and retry the batch twice for any transport failure or
  /// missing/unparseable tracker result. Exhausted retries return failed
  /// tracker results; the caller turns that into a hard Studio error.
  Future<List<TrackerBatchResult>> runBatchGroup({
    required TrackerBatchGroup group,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required PromptResult promptResult,
    required PromptPayload promptPayload,
    required ApiConfig apiConfig,
    required String sessionId,
    required CancelToken cancelToken,
    required int batchContextSize,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
  }) async {
    final context = _bucketizer.bucketize(
      promptResult,
      promptPayload: promptPayload,
      studioConfig: config,
    );
    final sharedMessages = _messageBuilder.buildSharedBatchMessages(
      config: config,
      context: context,
      promptPayload: promptPayload,
      promptResult: promptResult,
      batchContextSize: batchContextSize,
    );
    final perAgentTask = <String, String>{};
    for (final agent in group.agents) {
      perAgentTask[agent.id] = _messageBuilder.buildPerAgentTaskText(
        agent: agent,
        config: config,
        studioPreset: studioPreset,
        promptResult: promptResult,
        promptPayload: promptPayload,
        context: context,
      );
    }
    final roleText = _messageBuilder.batchRoleText(
      config,
      studioPreset,
      context,
      promptPayload,
      promptResult,
    );
    final batcher = _batcher;
    final systemPrompt = batcher.buildBatchSystemPrompt(
      group: group,
      sharedMessages: sharedMessages,
      perAgentTaskText: perAgentTask,
      roleText: roleText,
    );
    // The batch instructions are the system prompt; we also send an explicit
    // user turn that triggers the batched response. A system-only message list
    // is rejected with HTTP 400 by several providers (e.g. z-ai/GLM), which
    // require at least one user message — so this user turn is mandatory, not
    // cosmetic. See docs/PLAN_AGENTIC_STUDIO.md Phase 5.
    final batchMessages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      {
        'role': 'user',
        'content':
            'Produce the required <result> blocks now, one per agent_task '
            'listed above, in order.',
      },
    ];
    // Use a synthetic StudioAgent for the batch request: carry the group's
    // budget/temperature. The AgentRunner will resolve the API config from
    // this agent's fields (modelSource='current' → use the group's resolved
    // (provider, model) via runApiConfigId). We override maxTokens/temperature
    // on a per-call basis by passing them through ChatTransportRequest — but
    // AgentRunner.runAgent reads them off the agent. So we synthesize a
    // per-batch agent that carries the batch budget.
    final batchAgent = group.agents.first.copyWith(
      maxTokens: group.batchMaxTokens,
      temperature: group.batchTemperature,
      contextSize: batchContextSize,
    );
    final runner = _runner;
    List<TrackerBatchResult>? lastParsed;
    String? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      if (cancelToken.isCancelled) {
        throw const AgentRunFailedException(
          agentId: 'batch',
          agentName: 'Studio tracker batch',
          reason: 'cancelled',
        );
      }
      try {
        final result = await runner.runAgent(
          agent: batchAgent,
          messages: batchMessages,
          apiConfig: apiConfig,
          sessionId: sessionId,
          isFinalResponse: false,
          cancelToken: cancelToken,
          preResolvedConfig: group.resolved,
          turnConfig: turnConfig,
        );
        final parsed = batcher.parseBatchResponse(result.text, group);
        if (_allOk(parsed)) {
          return parsed;
        }
        lastParsed = parsed;
        final failedCount = parsed.where((r) => r.status != 'ok').length;
        lastError =
            '$failedCount tracker result(s) were missing or unparseable';
        if (attempt < 3) {
          _log(
            'batch group ${group.key} had $failedCount failed agents on '
            'attempt $attempt — retrying batch',
          );
        }
      } on AgentRunFailedException catch (e) {
        if (cancelToken.isCancelled) rethrow;
        lastError = e.reason;
        if (attempt < 3) {
          _log(
            'batch group ${group.key} request failed on attempt $attempt '
            '(${e.reason}) — retrying batch',
          );
        }
      }
    }
    _log(
      'batch group ${group.key} failed after 2 retries: '
      '${lastError ?? 'unknown tracker error'}',
    );
    return lastParsed ??
        group.agents
            .map(
              (agent) => TrackerBatchResult.failed(
                agentId: agent.id,
                agentName: agent.name,
                reason: lastError ?? 'tracker batch failed after 2 retries',
              ),
            )
            .toList(growable: false);
  }

  /// Legacy test seam for per-agent reruns. The chat-time Studio pipeline no
  /// longer falls back from failed batches to individual tracker calls.
  Future<List<TrackerBatchResult>> retryFailedIndividually({
    required List<StudioAgent> agents,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required PromptResult promptResult,
    required PromptPayload promptPayload,
    required ApiConfig apiConfig,
    required String sessionId,
    required CancelToken cancelToken,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
  }) async {
    if (agents.isEmpty) return const [];
    final batcher = _batcher;
    return batcher.settleWithConcurrencyLimit(
      items: agents,
      limit: 2,
      run: (agent) async {
        try {
          final brief = await _executor.runTracker(
            agent: agent,
            promptResult: promptResult,
            promptPayload: promptPayload,
            apiConfig: apiConfig,
            config: config,
            studioPreset: studioPreset,
            sessionId: sessionId,
            cancelToken: cancelToken,
            apiConfigId: apiConfigId,
            turnConfig: turnConfig,
            onIntermediateUpdate: null,
          );
          return TrackerBatchResult(
            agentId: agent.id,
            agentName: agent.name,
            text: brief.brief,
            status: brief.status,
            error: brief.error,
          );
        } catch (e) {
          return TrackerBatchResult.failed(
            agentId: agent.id,
            agentName: agent.name,
            reason: formatError(e),
          );
        }
      },
    );
  }

  bool _allOk(List<TrackerBatchResult> results) {
    return results.every((r) => r.status == 'ok' && r.text.isNotEmpty);
  }
}
