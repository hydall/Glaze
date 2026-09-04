import 'package:dio/dio.dart';

import '../models/api_config.dart';
import '../models/pipeline_settings.dart';
import '../models/studio_config.dart';
import '../utils/error_format.dart';
import 'agent_runner.dart';
import 'studio_brief_parser.dart';
import 'studio_message_builder.dart';
import 'studio_stage_brief.dart';
import 'controller_batcher.dart';
import 'studio_turn_config_snapshot.dart';
import 'studio/studio_context.dart';

/// Runs the per-agent LLM calls of the Studio chat-time pipeline: the
/// pre-gen tracker, the post-processing tracker, the individual (non-batch)
/// fallback tracker, and the final generator. Extracted from
/// `MemoryStudioService` (plan §2.8).
///
/// Each adapter assembles the agent's message list via the injected
/// [StudioMessageBuilder], invokes [AgentRunner.runAgent], and adapts the
/// result type to the pipeline-internal [StudioStageBrief] / [ControllerBatchResult]
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
    required StudioContext context,
    required ApiConfig apiConfig,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required String sessionId,
    required CancelToken cancelToken,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
    // 0 = the agent spec's own context size.
    int trackerContextOverride = 0,
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
        context: context,
        config: config,
        studioPreset: studioPreset,
        priorBriefs: const [],
        isFinalResponse: false,
        trackerContextOverride: trackerContextOverride,
      );
      final result = await _runner.runAgent(
        agent: agent,
        messages: messages,
        apiConfig: apiConfig,
        sessionId: sessionId,
        isFinalResponse: false,
        cancelToken: cancelToken,
        apiConfigId: apiConfigId,
        turnConfig: turnConfig,
        charName: context.macroContext.charName,
        userName: context.macroContext.userName,
        onIntermediateUpdate: onIntermediateUpdate,
      );
      return StudioStageBrief(
        agentId: agent.id,
        agentName: agent.name,
        brief: _briefParser.sanitizeIntermediateAgentOutput(agent, result.text),
      );
    } on AgentRunFailedException catch (error) {
      return StudioStageBrief(
        agentId: error.agentId,
        agentName: error.agentName,
        brief: 'Studio agent failed: ${error.reason}',
        status: 'error',
        error: error.reason,
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
    required StudioContext context,
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
                .studioPostControllerContextSize;
        final messages = _messageBuilder.buildAgentMessages(
          agent: agent,
          trackerContextOverride: override,
          context: context,
          config: config,
          studioPreset: studioPreset,
          priorBriefs: const [],
          isFinalResponse: false,
          mainResponse: mainResponse,
        );
        final result = await _runner.runAgent(
          agent: agent,
          messages: messages,
          apiConfig: apiConfig,
          sessionId: sessionId,
          isFinalResponse: false,
          cancelToken: cancelToken,
          apiConfigId: apiConfigId,
          turnConfig: turnConfig,
          charName: context.macroContext.charName,
          userName: context.macroContext.userName,
        );
        final text = result.text.trim();
        return StudioStageBrief(
          agentId: agent.id,
          agentName: agent.name,
          brief: text,
          status: text.isNotEmpty ? 'ok' : 'skipped',
        );
      } on AgentRunFailedException catch (error) {
        lastError = error.reason;
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
  Future<ControllerBatchResult> runIndividualTracker({
    required StudioAgent agent,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required StudioContext context,
    required ApiConfig apiConfig,
    required String sessionId,
    required CancelToken cancelToken,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
    int trackerContextOverride = 0,
  }) async {
    String? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      if (cancelToken.isCancelled) {
        return ControllerBatchResult.failed(
          agentId: agent.id,
          agentName: agent.name,
          reason: 'cancelled',
        );
      }
      try {
        final brief = await runTracker(
          agent: agent,
          context: context,
          apiConfig: apiConfig,
          config: config,
          studioPreset: studioPreset,
          sessionId: sessionId,
          cancelToken: cancelToken,
          apiConfigId: apiConfigId,
          turnConfig: turnConfig,
          trackerContextOverride: trackerContextOverride,
          onIntermediateUpdate: null,
        );
        if (brief.status == 'ok' && brief.brief.trim().isNotEmpty) {
          return ControllerBatchResult(
            agentId: agent.id,
            agentName: agent.name,
            text: brief.brief,
            status: brief.status,
            error: brief.error,
          );
        }
        lastError = brief.error ?? 'tracker returned an empty response';
      } catch (error) {
        lastError = formatError(error);
      }
    }
    return ControllerBatchResult.failed(
      agentId: agent.id,
      agentName: agent.name,
      reason: lastError ?? 'tracker failed after 2 retries',
    );
  }

  Future<AgentRunResult> runFinalGenerator({
    required StudioAgent agent,
    required StudioContext context,
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
    void Function(Set<String> classifications)? onLorebookClassificationsBuilt,
  }) async {
    final settings = turnConfig?.pipelineSettings ?? _readPipelineSettings();
    final emittedLorebookClassifications = <String>{};
    final responseJsonSchema = <String, dynamic>{};
    final twoPassPrefills = <String>[];
    final messages = _messageBuilder.buildAgentMessages(
      agent: agent,
      context: context,
      config: config,
      studioPreset: studioPreset,
      priorBriefs: priorBriefs,
      isFinalResponse: true,
      finalContextOverride: settings.studioAgent.studioFinalContextSize,
      reasoningHistoryCount:
          settings.studioAgent.studioFinalReasoningHistoryCount,
      excludeReasoningFromContextBudget:
          settings.studioAgent.studioFinalExcludeReasoningFromContextBudget,
      emittedLorebookClassifications: emittedLorebookClassifications,
      responseJsonSchema: responseJsonSchema,
      twoPassPrefills: twoPassPrefills,
    );
    onLorebookClassificationsBuilt?.call(emittedLorebookClassifications);
    onMessagesBuilt?.call(messages);
    if (twoPassPrefills.isNotEmpty) {
      return _runTwoPassGenerator(
        agent: agent,
        context: context,
        apiConfig: apiConfig,
        config: config,
        studioPreset: studioPreset,
        priorBriefs: priorBriefs,
        sessionId: sessionId,
        cancelToken: cancelToken,
        apiConfigId: apiConfigId,
        turnConfig: turnConfig,
        baseMessages: messages,
        prefill: twoPassPrefills.single,
        onFinalResponseUpdate: onFinalResponseUpdate,
      );
    }
    return _runner.runAgent(
      agent: agent,
      messages: messages,
      apiConfig: apiConfig,
      sessionId: sessionId,
      isFinalResponse: true,
      cancelToken: cancelToken,
      apiConfigId: apiConfigId,
      turnConfig: turnConfig,
      charName: context.macroContext.charName,
      userName: context.macroContext.userName,
      responseJsonSchema: responseJsonSchema.isEmpty ? null : responseJsonSchema,
      onFinalResponseUpdate: onFinalResponseUpdate,
    );
  }

  /// Two-pass prefill: the final generator runs twice. Pass 1 is a quiet
  /// ask that produces the internal `<thinking>` block (plain text — no
  /// synthetic tool call, no JSON schema, so it survives Gemini 3.8's
  /// `thought_signature` requirement). Both passes run through the final
  /// generator config (`isFinalResponse: true`) so they hit the final model
  /// and its reasoning settings — a controller-lane pass would resolve the
  /// pre-gen model instead. Pass 2 seeds the block back into the conversation
  /// as a prior assistant turn and asks for the visible reply only. The
  /// produced reasoning is returned as `AgentRunResult.reasoning` so it still
  /// surfaces in the UI.
  Future<AgentRunResult> _runTwoPassGenerator({
    required StudioAgent agent,
    required StudioContext context,
    required ApiConfig apiConfig,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required List<StudioStageBrief> priorBriefs,
    required String sessionId,
    required CancelToken cancelToken,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
    required List<Map<String, dynamic>> baseMessages,
    required String prefill,
    void Function(String text, String? reasoning)? onFinalResponseUpdate,
  }) async {
    final thinkingInstruction =
        'Produce your internal reasoning for the upcoming reply. Use the '
        'section structure of the template below, but fill every section with '
        'content grounded in the current scene — do not copy it verbatim. '
        'Output ONLY the block between <thinking> and </thinking>, nothing '
        'else.\n\n<template>\n$prefill\n</template>';
    final thinkingMessages = <Map<String, dynamic>>[
      ...baseMessages,
      {'role': 'user', 'content': thinkingInstruction},
    ];
    final thinking = await _runner.runAgent(
      agent: agent,
      messages: thinkingMessages,
      apiConfig: apiConfig,
      sessionId: sessionId,
      isFinalResponse: true,
      cancelToken: cancelToken,
      apiConfigId: apiConfigId,
      turnConfig: turnConfig,
      charName: context.macroContext.charName,
      userName: context.macroContext.userName,
    );
    final thinkingText = (thinking.reasoning.trim().isNotEmpty
            ? thinking.reasoning
            : thinking.text)
        .trim();
    if (thinkingText.isEmpty) {
      return const AgentRunResult(text: '', reasoning: '');
    }

    final nudge =
        'The reasoning above is your internal analysis for this turn. Now '
        'write your final response. Do not open a new <thinking> block — '
        'output the reply only.';
    final answerMessages = <Map<String, dynamic>>[
      ...baseMessages,
      {'role': 'assistant', 'content': thinkingText},
      {'role': 'user', 'content': nudge},
    ];
    final answer = await _runner.runAgent(
      agent: agent,
      messages: answerMessages,
      apiConfig: apiConfig,
      sessionId: sessionId,
      isFinalResponse: true,
      cancelToken: cancelToken,
      apiConfigId: apiConfigId,
      turnConfig: turnConfig,
      charName: context.macroContext.charName,
      userName: context.macroContext.userName,
      onFinalResponseUpdate: onFinalResponseUpdate,
    );
    final secondReasoning = answer.reasoning.trim();
    final combinedReasoning = [
      thinkingText,
      if (secondReasoning.isNotEmpty && secondReasoning != thinkingText)
        secondReasoning,
    ].join('\n\n---\n\n');
    return AgentRunResult(
      text: answer.text,
      reasoning: combinedReasoning,
      rawResponseJson: answer.rawResponseJson,
    );
  }
}
