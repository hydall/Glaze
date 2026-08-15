import 'dart:async';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';

import '../models/api_config.dart';
import '../models/extra_request_parameter.dart';
import '../models/pipeline_settings.dart';
import '../models/studio_config.dart';
import '../utils/error_format.dart';
import 'agent_stream_runner.dart';
import 'studio/agent_config_resolver.dart';
import 'studio_turn_config_snapshot.dart';
import 'transport/transport_factory.dart';
import 'studio_controller_ontology.dart';

/// Thin LLM orchestrator extracted from `MemoryStudioService` (Phase 5.1,
/// port of Marinara `agent-executor.ts` single-agent execution path).
///
/// Responsibility: given a [StudioAgent] and already-built `messages`, resolve
/// the API config, build a [ChatTransportRequest], stream the LLM, accumulate
/// the output, and return it. **No prompt-building, no batching, no caching** —
/// those stay in `MemoryStudioService`.
///
/// Used by:
/// - `MemoryStudioService.runTrackerCycle` for the final generator and
///   individual trackers.
/// - `StudioBatchCoordinator` for batch tracker requests.
class AgentRunner {
  final AgentConfigResolver _configResolver;
  final PipelineSettings Function() _readPipelineSettings;
  late final AgentStreamRunner _streamRunner = AgentStreamRunner(
    pickChatTransport,
  );

  AgentRunner({
    required this._configResolver,
    required this._readPipelineSettings,
  });

  /// Run a single agent against the LLM. Streaming is driven by
  /// [onFinalResponseUpdate] / [onIntermediateUpdate]; the returned
  /// [AgentRunResult] carries the final accumulated text + reasoning.
  ///
  /// [isFinalResponse] = true → the generator (final agent). Reasoning is
  /// forwarded to the UI. [isFinalResponse] = false → a tracker; reasoning
  /// is discarded (trackers are JSON/plain-text producers).
  ///
  /// Tracker failure handling: when [isFinalResponse] is false, any exception
  /// (timeout, transport, idle) is **caught and rethrown as
  /// [AgentRunFailedException]** so callers can retry consistently. Exhausted
  /// tracker retries abort the Studio turn before the final generator runs.
  /// The final generator rethrows normally (its failure aborts the turn).
  /// When [preResolvedConfig] is provided, [resolveAgentConfig] is skipped
  /// and the caller-supplied config is used directly. This avoids double
  /// resolution when the caller (e.g. `StudioBatchCoordinator`) has already
  /// resolved the config at grouping time. When provided, global tracker
  /// maxTokens/temperature overrides are also skipped — a batched call passes
  /// its budget explicitly via [batchMaxTokens] / [batchTemperature].
  Future<AgentRunResult> runAgent({
    required StudioAgent agent,
    required List<Map<String, dynamic>> messages,
    required ApiConfig apiConfig,
    required String sessionId,
    required bool isFinalResponse,
    CancelToken? cancelToken,
    ResolvedAgentConfig? preResolvedConfig,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
    String? charName,
    String? userName,
    // Explicit budget for a batched run: the group's summed token budget and
    // minimum temperature. Non-null wins over both the global override and the
    // agent spec's own values — an agent carries none of its own (§4).
    int? batchMaxTokens,
    double? batchTemperature,
    void Function(String text, String? reasoning)? onFinalResponseUpdate,
    void Function(String text)? onIntermediateUpdate,
  }) async {
    final token = cancelToken ?? CancelToken();
    if (token.isCancelled) {
      throw AgentRunFailedException(
        agentId: agent.id,
        agentName: agent.name,
        reason: 'cancelled',
      );
    }

    try {
      return await _runAgentInner(
        agent: agent,
        messages: messages,
        apiConfig: apiConfig,
        sessionId: sessionId,
        isFinalResponse: isFinalResponse,
        cancelToken: token,
        preResolvedConfig: preResolvedConfig,
        apiConfigId: apiConfigId,
        turnConfig: turnConfig,
        charName: charName,
        userName: userName,
        batchMaxTokens: batchMaxTokens,
        batchTemperature: batchTemperature,
        onFinalResponseUpdate: onFinalResponseUpdate,
        onIntermediateUpdate: onIntermediateUpdate,
      );
    } catch (e) {
      if (token.isCancelled || (e is DioException && CancelToken.isCancel(e))) {
        throw AgentRunFailedException(
          agentId: agent.id,
          agentName: agent.name,
          reason: 'cancelled',
        );
      }
      if (isFinalResponse) rethrow;
      // Wrap so Studio tracker callers can retry and then hard-fail with a
      // tracker-specific error.
      throw AgentRunFailedException(
        agentId: agent.id,
        agentName: agent.name,
        reason: formatError(e),
        cause: e,
      );
    }
  }

  Future<AgentRunResult> _runAgentInner({
    required StudioAgent agent,
    required List<Map<String, dynamic>> messages,
    required ApiConfig apiConfig,
    required String sessionId,
    required bool isFinalResponse,
    required CancelToken cancelToken,
    ResolvedAgentConfig? preResolvedConfig,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
    String? charName,
    String? userName,
    int? batchMaxTokens,
    double? batchTemperature,
    void Function(String text, String? reasoning)? onFinalResponseUpdate,
    void Function(String text)? onIntermediateUpdate,
  }) async {
    final resolved =
        preResolvedConfig ??
        await resolveAgentConfig(
          agent,
          apiConfig,
          sessionId,
          isFinalResponse: isFinalResponse,
          apiConfigId: apiConfigId,
          turnConfig: turnConfig,
        );
    if (resolved.endpoint.isEmpty || resolved.model.isEmpty) {
      throw Exception('Studio agent "${agent.name}" API is not configured');
    }
    final timeoutMs = effectiveTimeoutMs(agent, isFinalResponse, turnConfig);
    // When preResolvedConfig is provided, skip global tracker maxTokens/
    // temperature overrides — the agent carries the batch budget (sum of
    // all group agents' maxTokens, min temperature). Global overrides are
    // for individual tracker requests; applying them to a batch would
    // overwrite the computed batch budget with a per-agent cap.
    final maxTokensOverride =
        batchMaxTokens ??
        (preResolvedConfig != null && !isFinalResponse
            ? null
            : effectiveMaxTokens(agent, isFinalResponse, turnConfig));
    final temperatureOverride =
        batchTemperature ??
        (preResolvedConfig != null && !isFinalResponse
            ? null
            : effectiveTemperature(agent, isFinalResponse, turnConfig));
    final pipeline = turnConfig?.pipelineSettings ?? _readPipelineSettings();
    // Each reasoning parameter is gated on its `*Override` flag: when the flag
    // is off the argument stays null, and `copyWithReasoning` keeps whatever
    // the selected API preset resolved to. `DisableReasoning` is a hard kill
    // switch and wins over both the flag and the preset.
    final studio = pipeline.studioAgent;
    final cleaner = pipeline.cleaner;
    final effectiveResolved = isFinalResponse
        ? resolved.copyWithReasoning(
            useResponsesApi: studio.studioFinalUseResponsesApiOverride
                ? studio.studioFinalUseResponsesApi
                : null,
            requestReasoning: studio.studioFinalDisableReasoning
                ? false
                : studio.studioFinalRequestReasoningOverride
                ? studio.studioFinalRequestReasoning
                : null,
            showNativeReasoning: studio.studioFinalShowNativeReasoningOverride
                ? studio.studioFinalShowNativeReasoning
                : null,
            omitReasoning: studio.studioFinalDisableReasoning
                ? true
                : studio.studioFinalRequestReasoningOverride
                ? studio.studioFinalOmitReasoning
                : null,
            omitReasoningEffort: studio.studioFinalReasoningEffortOverride
                ? studio.studioFinalOmitReasoningEffort
                : null,
            reasoningEffort: studio.studioFinalReasoningEffortOverride
                ? studio.studioFinalReasoningEffort
                : null,
          )
        : agent.phase == 'post_processing'
        ? resolved.copyWithReasoning(
            useResponsesApi: cleaner.postCleanerUseResponsesApiOverride
                ? cleaner.postCleanerUseResponsesApi
                : null,
            requestReasoning: cleaner.postCleanerDisableReasoning
                ? false
                : cleaner.postCleanerRequestReasoningOverride
                ? cleaner.postCleanerRequestReasoning
                : null,
            showNativeReasoning: cleaner.postCleanerShowNativeReasoningOverride
                ? cleaner.postCleanerShowNativeReasoning
                : null,
            omitReasoning: cleaner.postCleanerDisableReasoning
                ? true
                : cleaner.postCleanerRequestReasoningOverride
                ? cleaner.postCleanerOmitReasoning
                : null,
            omitReasoningEffort: cleaner.postCleanerReasoningEffortOverride
                ? cleaner.postCleanerOmitReasoningEffort
                : null,
            reasoningEffort: cleaner.postCleanerReasoningEffortOverride
                ? cleaner.postCleanerReasoningEffort
                : null,
          )
        : resolved.copyWithReasoning(
            useResponsesApi: studio.studioControllerUseResponsesApiOverride
                ? studio.studioControllerUseResponsesApi
                : null,
            requestReasoning: studio.studioControllerDisableReasoning
                ? false
                : studio.studioControllerRequestReasoningOverride
                ? studio.studioControllerRequestReasoning
                : null,
            showNativeReasoning:
                studio.studioControllerShowNativeReasoningOverride
                ? studio.studioControllerShowNativeReasoning
                : null,
            omitReasoning: studio.studioControllerDisableReasoning
                ? true
                : studio.studioControllerRequestReasoningOverride
                ? studio.studioControllerOmitReasoning
                : null,
            omitReasoningEffort: studio.studioControllerReasoningEffortOverride
                ? studio.studioControllerOmitReasoningEffort
                : null,
            reasoningEffort: studio.studioControllerReasoningEffortOverride
                ? studio.studioControllerReasoningEffort
                : null,
          );
    return _streamRunner.run(
      agent: agent,
      messages: messages,
      resolved: effectiveResolved,
      sessionId: sessionId,
      isFinalResponse: isFinalResponse,
      cancelToken: cancelToken,
      timeoutMs: timeoutMs,
      maxTokensOverride: maxTokensOverride,
      temperatureOverride: temperatureOverride,
      tagStart: effectiveResolved.reasoningTagStart,
      tagEnd: effectiveResolved.reasoningTagEnd,
      headerModel: isFinalResponse ? 'reasoning_model'.tr() : null,
      headerInline: isFinalResponse ? 'reasoning_inline'.tr() : null,
      charName: charName,
      userName: userName,
      onFinalResponseUpdate: onFinalResponseUpdate,
      onIntermediateUpdate: onIntermediateUpdate,
    );
  }

  /// Resolve which API config an agent uses. Delegates to
  /// [AgentConfigResolver]. Kept as a facade so callers (ControllerBatcher,
  /// tests) can call `runner.resolveAgentConfig(...)` without importing the
  /// resolver directly.
  Future<ResolvedAgentConfig> resolveAgentConfig(
    StudioAgent agent,
    ApiConfig current,
    String sessionId, {
    bool isFinalResponse = false,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
  }) {
    return _configResolver.resolveAgentConfig(
      agent,
      current,
      sessionId,
      isFinalResponse: isFinalResponse,
      apiConfigId: apiConfigId,
      turnConfig: turnConfig,
    );
  }

  /// Per-agent idle timeout. The idle timer fires only if the model emits
  /// NO chunks (text or reasoning) within the window — once any chunk
  /// arrives the timer is cancelled entirely (see AgentStreamRunner). So
  /// this is effectively a "first-byte" timeout, not a total-generation
  /// timeout.
  ///
  /// Resolution order:
  /// 1. The agent spec's `timeoutMs` (>4000ms, minimum 1000ms) —
  ///    per-agent override set at Studio build time.
  /// 2. [PipelineSettings.studioAgent.studioTimeoutMs] (>0, minimum 1000ms)
  ///    — global user setting from the Post-Building menu.
  /// 3. hardcoded fallback: final generator 90s, trackers 60s.
  int effectiveTimeoutMs(
    StudioAgent agent,
    bool isFinalResponse, [
    StudioTurnConfigSnapshot? turnConfig,
  ]) {
    final fallback = isFinalResponse ? 90000 : 60000;
    final pipeline = turnConfig?.pipelineSettings ?? _readPipelineSettings();
    final slot = isFinalResponse
        ? pipeline.studioAgent.studioFinalTimeoutMs
        : agent.phase == 'post_processing'
        ? pipeline.cleaner.postCleanerTimeoutMs
        : pipeline.studioAgent.studioControllerTimeoutMs;
    if (slot > 0) {
      return slot < 1000 ? 1000 : slot;
    }
    final specTimeout =
        StudioControllerOntology.specForAgent(agent)?.timeoutMs ?? 4000;
    if (specTimeout > 4000) {
      return specTimeout < 1000 ? 1000 : specTimeout;
    }
    final global = pipeline.studioAgent.studioTimeoutMs;
    if (global > 0) {
      return global < 1000 ? 1000 : global;
    }
    return fallback;
  }

  /// Max tokens override. Two tiers:
  /// - Final generator: `studioFinalMaxTokensOverride` decides whether
  ///   `studioFinalMaxTokens` replaces the per-agent default. Zero is valid and
  ///   causes OpenAI-compatible transports to omit the token-limit field.
  /// - Trackers: [PipelineSettings.studioAgent.studioControllerMaxTokens] (>0) overrides the
  ///   per-agent default (1600). Lets the user tighten/loosen the compact JSON
  ///   brief budget for all 7 pre-gen agents at once from the Studio menu.
  /// Returns null when the relevant global override is 0 and the caller should
  /// use the agent's own value.
  int? effectiveMaxTokens(
    StudioAgent agent,
    bool isFinalResponse, [
    StudioTurnConfigSnapshot? turnConfig,
  ]) {
    final pipeline = turnConfig?.pipelineSettings ?? _readPipelineSettings();
    if (isFinalResponse) {
      final studio = pipeline.studioAgent;
      return studio.studioFinalMaxTokensOverride
          ? studio.studioFinalMaxTokens
          : null;
    }
    if (agent.phase == 'post_processing') {
      final cleanerGlobal = pipeline.cleaner.postCleanerMaxTokens;
      if (cleanerGlobal > 0) return cleanerGlobal;
      return null;
    }
    final trackerGlobal = pipeline.studioAgent.studioControllerMaxTokens;
    if (trackerGlobal > 0) return trackerGlobal;
    return null;
  }

  /// Temperature override. Two tiers:
  /// - Final generator: [PipelineSettings.studioAgent.studioFinalTemperature] (>= 0)
  ///   overrides the per-agent default (0.8).
  /// - Trackers: [PipelineSettings.studioAgent.studioControllerTemperature] (>= 0) overrides
  ///   the per-agent default (0.3). Lets the user tune the creativity of all
  ///   7 pre-gen agents at once from the Studio menu.
  /// - Post-processing: [PipelineSettings.cleaner.postCleanerTemperature]
  ///   (>= 0), same sentinel.
  /// Returns null when the relevant global override is negative and the
  /// caller should use the agent's own value.
  double? effectiveTemperature(
    StudioAgent agent,
    bool isFinalResponse, [
    StudioTurnConfigSnapshot? turnConfig,
  ]) {
    final pipeline = turnConfig?.pipelineSettings ?? _readPipelineSettings();
    if (isFinalResponse) {
      final global = pipeline.studioAgent.studioFinalTemperature;
      if (global >= 0) return global;
      return null;
    }
    if (agent.phase == 'post_processing') {
      final cleanerGlobal = pipeline.cleaner.postCleanerTemperature;
      if (cleanerGlobal >= 0) return cleanerGlobal;
      return null;
    }
    final trackerGlobal = pipeline.studioAgent.studioControllerTemperature;
    if (trackerGlobal >= 0) return trackerGlobal;
    return null;
  }
}

/// Successful single-agent run. Mirrors the former `_StudioAgentRunResult`.
class AgentRunResult {
  final String text;
  final String reasoning;
  final String? rawResponseJson;

  const AgentRunResult({
    required this.text,
    this.reasoning = '',
    this.rawResponseJson,
  });
}

/// Per-agent failure wrapper. Thrown by [AgentRunner.runAgent] for trackers
/// (non-final agents) when the underlying LLM call fails for any reason
/// (timeout, transport, parse). The caller retries and then returns a hard
/// Studio error. The final generator's failures propagate as the original
/// exception (no wrap).
class AgentRunFailedException implements Exception {
  final String agentId;
  final String agentName;
  final String reason;
  final Object? cause;

  const AgentRunFailedException({
    required this.agentId,
    required this.agentName,
    required this.reason,
    this.cause,
  });

  @override
  String toString() =>
      'AgentRunFailedException(agent="$agentName" id="$agentId" reason="$reason")';
}

/// Resolved per-agent API parameters. Mirrors the former private
/// `_ResolvedAgentConfig` from `MemoryStudioService`, now public on this
/// orchestrator so `MemoryStudioService.executeTrackerBatch` can read the
/// `maxTokens` cap and `stream` flag when computing a batch budget.
class ResolvedAgentConfig {
  final String endpoint;
  final String apiKey;
  final String model;
  final String protocol;
  final double topP;
  final int topK;
  final double frequencyPenalty;
  final double presencePenalty;
  final bool omitTemperature;
  final bool omitTopP;
  final bool requestReasoning;
  final bool showNativeReasoning;
  final bool useResponsesApi;
  final String? reasoningEffort;
  final bool omitReasoning;
  final bool omitReasoningEffort;
  final bool stream;
  final String cacheControlTtl;
  final String cacheBreakpointMode;
  final String sessionIdMode;
  final String promptPostProcessing;
  final int contextSize;
  final List<ExtraRequestParameter> extraRequestParameters;
  final String? reasoningTagStart;
  final String? reasoningTagEnd;

  const ResolvedAgentConfig({
    required this.endpoint,
    required this.apiKey,
    required this.model,
    required this.protocol,
    this.topP = 1.0,
    this.topK = 0,
    this.frequencyPenalty = 0.0,
    this.presencePenalty = 0.0,
    this.omitTemperature = false,
    this.omitTopP = false,
    this.requestReasoning = false,
    this.showNativeReasoning = true,
    this.useResponsesApi = false,
    this.reasoningEffort,
    this.omitReasoning = false,
    this.omitReasoningEffort = false,
    this.stream = false,
    this.cacheControlTtl = 'off',
    this.cacheBreakpointMode = 'depth',
    this.sessionIdMode = 'openrouter',
    this.promptPostProcessing = 'none',
    this.contextSize = 32000,
    this.extraRequestParameters = const [],
    this.reasoningTagStart,
    this.reasoningTagEnd,
  });

  factory ResolvedAgentConfig.fromApiConfig(
    ApiConfig config, {
    String modelOverride = '',
  }) {
    return ResolvedAgentConfig(
      endpoint: config.endpoint,
      apiKey: config.apiKey,
      model: modelOverride.isNotEmpty ? modelOverride : config.model,
      protocol: config.protocol,
      topP: config.topP,
      topK: config.topK,
      frequencyPenalty: config.frequencyPenalty,
      presencePenalty: config.presencePenalty,
      omitTemperature: config.omitTemperature,
      omitTopP: config.omitTopP,
      requestReasoning: config.requestReasoning,
      showNativeReasoning: config.showNativeReasoning,
      useResponsesApi: config.useResponsesApi,
      reasoningEffort: config.reasoningEffort,
      omitReasoning: config.omitReasoning,
      omitReasoningEffort: config.omitReasoningEffort,
      stream: config.stream,
      cacheControlTtl: config.cacheControlTtl,
      cacheBreakpointMode: config.cacheBreakpointMode,
      sessionIdMode: config.sessionIdMode,
      promptPostProcessing: config.promptPostProcessing,
      contextSize: config.contextSize,
      extraRequestParameters: config.extraRequestParameters,
      reasoningTagStart: config.reasoningTagStart,
      reasoningTagEnd: config.reasoningTagEnd,
    );
  }

  /// Per-call override of the reasoning-related flags. Used by
  /// [AgentRunner._runAgentInner] when `studioFinalDisableReasoning` is on.
  ResolvedAgentConfig copyWithReasoning({
    bool? useResponsesApi,
    bool? requestReasoning,
    bool? showNativeReasoning,
    bool? omitReasoning,
    bool? omitReasoningEffort,
    String? reasoningEffort,
  }) {
    return ResolvedAgentConfig(
      endpoint: endpoint,
      apiKey: apiKey,
      model: model,
      protocol: protocol,
      topP: topP,
      topK: topK,
      frequencyPenalty: frequencyPenalty,
      presencePenalty: presencePenalty,
      omitTemperature: omitTemperature,
      omitTopP: omitTopP,
      requestReasoning: requestReasoning ?? this.requestReasoning,
      showNativeReasoning: showNativeReasoning ?? this.showNativeReasoning,
      useResponsesApi: useResponsesApi ?? this.useResponsesApi,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      omitReasoning: omitReasoning ?? this.omitReasoning,
      omitReasoningEffort: omitReasoningEffort ?? this.omitReasoningEffort,
      stream: stream,
      cacheControlTtl: cacheControlTtl,
      cacheBreakpointMode: cacheBreakpointMode,
      sessionIdMode: sessionIdMode,
      promptPostProcessing: promptPostProcessing,
      contextSize: contextSize,
      extraRequestParameters: extraRequestParameters,
      reasoningTagStart: reasoningTagStart,
      reasoningTagEnd: reasoningTagEnd,
    );
  }

  ResolvedAgentConfig copyWithSampling({
    double? topP,
    int? topK,
    double? frequencyPenalty,
    double? presencePenalty,
    bool? omitTemperature,
    bool? omitTopP,
    List<ExtraRequestParameter>? extraRequestParameters,
  }) {
    return ResolvedAgentConfig(
      endpoint: endpoint,
      apiKey: apiKey,
      model: model,
      protocol: protocol,
      topP: topP ?? this.topP,
      topK: topK ?? this.topK,
      frequencyPenalty: frequencyPenalty ?? this.frequencyPenalty,
      presencePenalty: presencePenalty ?? this.presencePenalty,
      omitTemperature: omitTemperature ?? this.omitTemperature,
      omitTopP: omitTopP ?? this.omitTopP,
      requestReasoning: requestReasoning,
      showNativeReasoning: showNativeReasoning,
      useResponsesApi: useResponsesApi,
      reasoningEffort: reasoningEffort,
      omitReasoning: omitReasoning,
      omitReasoningEffort: omitReasoningEffort,
      stream: stream,
      cacheControlTtl: cacheControlTtl,
      cacheBreakpointMode: cacheBreakpointMode,
      sessionIdMode: sessionIdMode,
      promptPostProcessing: promptPostProcessing,
      contextSize: contextSize,
      extraRequestParameters:
          extraRequestParameters ?? this.extraRequestParameters,
      reasoningTagStart: reasoningTagStart,
      reasoningTagEnd: reasoningTagEnd,
    );
  }
}
