import 'package:dio/dio.dart';

import '../models/api_config.dart';
import '../models/pipeline_settings.dart';
import '../models/studio_config.dart';
import '../utils/error_format.dart';
import 'agent_runner.dart';
import 'prompt_builder.dart';
import 'studio_brief_parser.dart';
import 'studio_message_builder.dart';
import 'studio_stage_brief.dart';
import 'tracker_batcher.dart';
import 'studio_turn_config_snapshot.dart';

/// Runs the per-agent LLM calls of the Studio chat-time pipeline: the
/// pre-gen tracker, the post-processing tracker, the individual (non-batch)
/// fallback tracker, and the final generator. Extracted from
/// `MemoryStudioService` (plan §2.8).
///
/// Each adapter assembles the agent's message list via the injected
/// [StudioMessageBuilder], invokes [AgentRunner.runAgent], and adapts the
/// result type to the pipeline-internal [StudioStageBrief] / [TrackerBatchResult]
/// / [AgentRunResult] shapes. Tracker failures are retried by the
/// relevant adapter and returned as failed results when retries are exhausted;
/// the final generator rethrows.
class StudioAgentExecutor {
  final AgentRunner _runner;
  final StudioMessageBuilder _messageBuilder;
  final StudioBriefParser _briefParser;
  final PipelineSettings Function() _readPipelineSettings;

  StudioAgentExecutor(
    this._runner,
    this._messageBuilder,
    this._briefParser,
    this._readPipelineSettings,
  );

  Future<ResolvedAgentConfig> resolveTrackerConfig({
    required StudioAgent agent,
    required ApiConfig apiConfig,
    required String sessionId,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
  }) {
    return _runner.resolveAgentConfig(
      agent,
      apiConfig,
      sessionId,
      apiConfigId: apiConfigId,
      turnConfig: turnConfig,
    );
  }

  int? effectiveMaxTokens(
    StudioAgent agent, [
    StudioTurnConfigSnapshot? turnConfig,
  ]) => _runner.effectiveMaxTokens(agent, false, turnConfig);

  double? effectiveTemperature(
    StudioAgent agent, [
    StudioTurnConfigSnapshot? turnConfig,
  ]) => _runner.effectiveTemperature(agent, false, turnConfig);

  /// Delegate the actual LLM call to [AgentRunner]. This method still
  /// builds the `messages` list (prompt assembly via [StudioMessageBuilder])
  /// and adapts the result type to the internal [StudioStageBrief] pipeline.
  ///
  /// When [isFinalResponse] is false, [AgentRunner.runAgent] wraps any failure
  /// into an [AgentRunFailedException]; here we unwrap it into a failed brief
  /// so callers can retry and then surface a hard Studio error. The final
  /// generator rethrows.
  Future<StudioStageBrief> runTracker({
    required StudioAgent agent,
    required PromptResult promptResult,
    required PromptPayload promptPayload,
    required ApiConfig apiConfig,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required String sessionId,
    required CancelToken cancelToken,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
    void Function(String text)? onIntermediateUpdate,
  }) async {
    if (_briefParser.isMetaPolicyAgent(agent)) {
      return StudioStageBrief(
        agentId: agent.id,
        agentName: agent.name,
        brief: _briefParser.metaPolicyBrief(agent),
      );
    }
    try {
      final messages = _messageBuilder.buildAgentMessages(
        agent: agent,
        promptResult: promptResult,
        promptPayload: promptPayload,
        config: config,
        studioPreset: studioPreset,
        priorBriefs: const [],
        isFinalResponse: false,
      );
      final runner = _runner;
      final result = await runner.runAgent(
        agent: agent,
        messages: messages,
        apiConfig: apiConfig,
        sessionId: sessionId,
        isFinalResponse: false,
        cancelToken: cancelToken,
        apiConfigId: apiConfigId,
        turnConfig: turnConfig,
        onIntermediateUpdate: onIntermediateUpdate,
      );
      final sanitized = _briefParser.sanitizeIntermediateAgentOutput(
        agent,
        result.text,
      );
      return StudioStageBrief(
        agentId: agent.id,
        agentName: agent.name,
        brief: sanitized,
      );
    } on AgentRunFailedException catch (e) {
      return StudioStageBrief(
        agentId: e.agentId,
        agentName: e.agentName,
        brief: 'Studio agent failed: ${e.reason}',
        status: 'error',
        error: e.reason,
      );
    }
  }

  /// Feature 6 — run ONE post-processing tracker. The tracker receives the
  /// generator's [mainResponse] in its context (as an extra
  /// `<assistant_response>` block appended to its `dynamic_context`) and
  /// can produce an edited/rewritten version. Its raw output is returned as
  /// a `StudioStageBrief` whose `brief` field is the rewritten text (NOT
  /// sanitized through the brief-shape contract — a post-gen tracker IS
  /// allowed to produce prose, since its job is to rewrite the response).
  /// The caller decides whether the rewrite replaces `mainResponse`.
  ///
  /// Failure policy: a post-gen tracker gets the same initial attempt + two
  /// retries as pre-gen trackers. Exhausting retries returns a failed brief;
  /// the caller surfaces it as a hard Studio error instead of silently keeping
  /// the previous `mainResponse`.
  Future<StudioStageBrief> runPostProcessingTracker({
    required StudioAgent agent,
    required String mainResponse,
    required PromptResult promptResult,
    required PromptPayload promptPayload,
    required ApiConfig apiConfig,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required String sessionId,
    required CancelToken cancelToken,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
  }) async {
    String? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      if (cancelToken.isCancelled) {
        return StudioStageBrief(
          agentId: agent.id,
          agentName: agent.name,
          brief: '',
          status: 'error',
          error: 'cancelled',
        );
      }
      try {
        final override =
            (turnConfig?.pipelineSettings ?? _readPipelineSettings())
                .studioAgent
                .studioPostTrackerContextSize;
        final effectiveAgent = override > 0
            ? agent.copyWith(contextSize: override)
            : agent;
        final messages = _messageBuilder.buildAgentMessages(
          agent: effectiveAgent,
          promptResult: promptResult,
          promptPayload: promptPayload,
          config: config,
          studioPreset: studioPreset,
          priorBriefs: const [],
          isFinalResponse: false,
          mainResponse: mainResponse,
        );
        final runner = _runner;
        final result = await runner.runAgent(
          agent: agent,
          messages: messages,
          apiConfig: apiConfig,
          sessionId: sessionId,
          isFinalResponse: false,
          cancelToken: cancelToken,
          apiConfigId: apiConfigId,
          turnConfig: turnConfig,
          onIntermediateUpdate: null,
        );
        // Post-gen trackers produce prose (a rewrite), NOT a brief — skip the
        // brief-shape sanitization that pre-gen trackers go through. Empty
        // output means "no edit needed" → caller keeps `mainResponse`. This is
        // the intentional happy-path no-op, so it is reported as 'skipped'
        // (NOT 'error') to avoid surfacing a false failure in the stage briefs.
        final text = result.text.trim();
        return StudioStageBrief(
          agentId: agent.id,
          agentName: agent.name,
          brief: text,
          status: text.isNotEmpty ? 'ok' : 'skipped',
        );
      } on AgentRunFailedException catch (e) {
        lastError = e.reason;
      }
    }
    return StudioStageBrief(
      agentId: agent.id,
      agentName: agent.name,
      brief: '',
      status: 'error',
      error: lastError ?? 'tracker failed after 2 retries',
    );
  }

  /// Run one individual tracker (not part of any batch group). Reuses the
  /// existing per-agent prompt assembly + AgentRunner.
  Future<TrackerBatchResult> runIndividualTracker({
    required StudioAgent agent,
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
    String? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      if (cancelToken.isCancelled) {
        return TrackerBatchResult.failed(
          agentId: agent.id,
          agentName: agent.name,
          reason: 'cancelled',
        );
      }
      try {
        final brief = await runTracker(
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
        if (brief.status == 'ok' && brief.brief.trim().isNotEmpty) {
          return TrackerBatchResult(
            agentId: agent.id,
            agentName: agent.name,
            text: brief.brief,
            status: brief.status,
            error: brief.error,
          );
        }
        lastError = brief.error ?? 'tracker returned an empty response';
      } catch (e) {
        lastError = formatError(e);
      }
    }
    return TrackerBatchResult.failed(
      agentId: agent.id,
      agentName: agent.name,
      reason: lastError ?? 'tracker failed after 2 retries',
    );
  }

  Future<AgentRunResult> runFinalGenerator({
    required StudioAgent agent,
    required PromptResult promptResult,
    required PromptPayload promptPayload,
    required ApiConfig apiConfig,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required List<StudioStageBrief> priorBriefs,
    required String sessionId,
    required CancelToken cancelToken,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
    void Function(String text, String? reasoning)? onFinalResponseUpdate,
    void Function(List<Map<String, dynamic>> messages)? onMessagesBuilt,
  }) async {
    final messages = _messageBuilder.buildAgentMessages(
      agent: agent,
      promptResult: promptResult,
      promptPayload: promptPayload,
      config: config,
      studioPreset: studioPreset,
      priorBriefs: priorBriefs,
      isFinalResponse: true,
      finalContextOverride:
          (turnConfig?.pipelineSettings ?? _readPipelineSettings())
              .studioAgent
              .studioFinalContextSize,
      reasoningHistoryCount:
          (turnConfig?.pipelineSettings ?? _readPipelineSettings())
              .studioAgent
              .studioFinalReasoningHistoryCount,
    );
    onMessagesBuilt?.call(messages);
    final runner = _runner;
    final result = await runner.runAgent(
      agent: agent,
      messages: messages,
      apiConfig: apiConfig,
      sessionId: sessionId,
      isFinalResponse: true,
      cancelToken: cancelToken,
      apiConfigId: apiConfigId,
      turnConfig: turnConfig,
      onFinalResponseUpdate: onFinalResponseUpdate,
    );
    return result;
  }
}
