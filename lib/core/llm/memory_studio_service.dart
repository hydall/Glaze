import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/api_config.dart';
import '../models/studio_config.dart';
import '../state/active_studio_preset_provider.dart';
import '../state/db_provider.dart';
import 'agent_runner.dart';
import 'prompt_builder.dart';
import 'studio_activation_gate.dart';
import 'studio_agent_executor.dart';
import 'studio_batch_coordinator.dart';
import 'studio_brief_cache.dart';
import 'studio_brief_deduper.dart';
import 'studio_brief_parser.dart';
import 'studio_context_bucketizer.dart';
import 'studio_message_builder.dart';
import 'studio_prompt_text.dart';
import 'studio_stage_brief.dart';
import 'studio_turn_config_snapshot.dart';
import 'tracker_batcher.dart';
import 'studio/studio_tracker_phase_runner.dart';
import 'studio/studio_tracker_result_mapper.dart';

// Re-export so existing importers of `AgentPhaseSplit` via this file (e.g.
// tests, studio_post_processing) keep their import path after the move to
// studio_activation_gate.dart.
export 'studio_activation_gate.dart' show AgentPhaseSplit;
export 'studio/studio_tracker_phase_runner.dart' show PreGenPhaseResult;

/// Session-bound Studio pipeline.
///
/// The Studio menu stores a user-editable [StudioConfig]. At generation time
/// this service runs enabled agents in order. Intermediate agents produce
/// compact briefs; the last enabled agent produces the actual RP response.
class MemoryStudioService {
  final Ref _ref;
  final AgentRunner _runner;
  final TrackerBatcher _batcher;
  final StudioPromptText _promptText = const StudioPromptText();
  final StudioContextBucketizer _bucketizer = const StudioContextBucketizer();
  late final StudioBriefParser _briefParser = StudioBriefParser(_log);
  late final StudioBriefDeduper _briefDeduper = StudioBriefDeduper(
    _briefParser,
  );
  late final StudioBriefCache _briefCache = StudioBriefCache(_briefParser);
  late final StudioMessageBuilder _messageBuilder = StudioMessageBuilder(
    _bucketizer,
    _promptText,
    _briefDeduper,
  );
  late final StudioAgentExecutor _executor = StudioAgentExecutor(
    _runner,
    _messageBuilder,
    _briefParser,
    () => _ref.read(pipelineSettingsProvider),
  );
  late final StudioBatchCoordinator _batchCoordinator = StudioBatchCoordinator(
    _batcher,
    _runner,
    _bucketizer,
    _messageBuilder,
    _executor,
    _log,
  );
  late final StudioTrackerResultMapper _resultMapper =
      StudioTrackerResultMapper(_briefParser, _briefCache);
  late final StudioTrackerPhaseRunner _phaseRunner = StudioTrackerPhaseRunner(
    presetRepo: _ref.read(studioPresetRepoProvider),
    batcher: _batcher,
    briefCache: _briefCache,
    briefParser: _briefParser,
    batchCoordinator: _batchCoordinator,
    executor: _executor,
    resultMapper: _resultMapper,
    readPipelineSettings: () => _ref.read(pipelineSettingsProvider),
    log: _log,
  );

  MemoryStudioService(this._ref, this._runner, this._batcher);

  /// Run the tracker cycle: pre-generation trackers (intermediate agents)
  /// run first, then the main generator (final agent) produces the response.
  /// Trackers receive compact briefs; the generator gets the full context
  /// plus the tracker briefs. See docs/PLAN_AGENTIC_STUDIO.md.
  Future<StudioPipelineResult> runTrackerCycle({
    required StudioConfig config,
    required PromptResult promptResult,
    required PromptPayload promptPayload,
    PromptResult? finalPromptResult,
    PromptPayload? finalPromptPayload,
    required ApiConfig apiConfig,
    required String sessionId,
    StudioTurnConfigSnapshot? turnConfig,
    CancelToken? cancelToken,
    void Function(String text, String? reasoning)? onFinalResponseUpdate,
    void Function()? onFinalStart,
    void Function(List<Map<String, dynamic>> messages)? onFinalMessagesBuilt,
  }) async {
    final token = cancelToken ?? CancelToken();
    if (token.isCancelled) {
      return const StudioPipelineResult(status: 'aborted', response: '');
    }

    final phaseResult = await _phaseRunner.run(
      config: config,
      presetId:
          turnConfig?.preset?.id ??
          await _ref.read(activeStudioPresetProvider.future),
      studioPreset: turnConfig?.preset,
      promptResult: promptResult,
      promptPayload: promptPayload,
      apiConfig: apiConfig,
      sessionId: sessionId,
      token: token,
      turnConfig: turnConfig,
    );

    if (phaseResult.status != 'ok') {
      return StudioPipelineResult(
        status: phaseResult.status,
        response: '',
        stageBriefs: phaseResult.briefs,
        error: phaseResult.error,
      );
    }

    final briefs = phaseResult.briefs;
    final split = phaseResult.split!;
    final turnIndex = phaseResult.turnIndex;
    final historyForScan = phaseResult.historyForScan;
    final studioPreset = phaseResult.studioPreset!;
    final finalAgent = split.finalAgent!;
    final postGenTrackers = split.postGenTrackers;

    final generatorPromptResult = finalPromptResult ?? promptResult;
    final generatorPromptPayload = finalPromptPayload ?? promptPayload;
    // Notify the caller that the final generator is about to start — before
    // the first token arrives. Lets the UI switch from "trackers running" to
    // "main responder generating" immediately, so a long first-byte latency
    // does not leave the user staring at a stale tracker-phase indicator.
    onFinalStart?.call();
    final agentResult = await _executor.runFinalGenerator(
      agent: finalAgent,
      promptResult: generatorPromptResult,
      promptPayload: generatorPromptPayload,
      apiConfig: apiConfig,
      config: config,
      studioPreset: studioPreset,
      priorBriefs: briefs,
      sessionId: sessionId,
      cancelToken: token,
      apiConfigId: config.expensiveApiConfigId,
      onFinalResponseUpdate: onFinalResponseUpdate,
      onMessagesBuilt: onFinalMessagesBuilt,
      turnConfig: turnConfig,
    );
    if (token.isCancelled) {
      return const StudioPipelineResult(status: 'aborted', response: '');
    }

    var mainResponse = agentResult.text;
    var mainReasoning = agentResult.reasoning;
    final rawResponseJson = agentResult.rawResponseJson;

    // Feature 6 — post-processing phase. Post-gen trackers run AFTER the
    // generator, receive `mainResponse` in their context, and can produce
    // an edited/rewritten version. They run sequentially in `order`, each
    // receiving the current `mainResponse`. The final post-gen tracker's
    // non-empty output replaces `mainResponse`. Post-gen trackers do NOT
    // stream to the UI.
    final postBriefs = <StudioStageBrief>[];
    for (final agent in postGenTrackers) {
      if (token.isCancelled) {
        return const StudioPipelineResult(status: 'aborted', response: '');
      }
      final interval = agent.runInterval <= 0 ? 1 : agent.runInterval;
      if (turnIndex % interval != 0) continue;
      if (agent.activationKeywords.isNotEmpty &&
          !StudioActivationGate.matchesActivationKeywords(
            agent.activationKeywords,
            historyForScan,
            agent.activationScanDepth,
          )) {
        continue;
      }
      final result = await _executor.runPostProcessingTracker(
        agent: agent,
        mainResponse: mainResponse,
        promptResult: generatorPromptResult,
        promptPayload: generatorPromptPayload,
        apiConfig: apiConfig,
        config: config,
        studioPreset: studioPreset,
        sessionId: sessionId,
        cancelToken: token,
        apiConfigId: config.cleanerApiConfigId,
        turnConfig: turnConfig,
      );
      postBriefs.add(result);
      if (token.isCancelled) {
        return const StudioPipelineResult(status: 'aborted', response: '');
      }
      if (result.status == 'error') {
        final error =
            'Studio tracker "${result.agentName}" failed after '
            '2 retries: ${result.error ?? 'tracker failed'}. Please '
            'restart generation.';
        _log('post tracker cycle failed session=$sessionId error=$error');
        return StudioPipelineResult(
          status: 'error',
          response: '',
          stageBriefs: [...briefs, ...postBriefs],
          error: error,
        );
      }
      if (result.status == 'ok' && result.brief.trim().isNotEmpty) {
        mainResponse = result.brief.trim();
        mainReasoning = '';
      }
    }

    return StudioPipelineResult(
      status: mainResponse.trim().isEmpty ? 'error' : 'ok',
      response: mainResponse,
      reasoning: mainReasoning,
      rawResponseJson: rawResponseJson,
      stageBriefs: [...briefs, ...postBriefs],
      error: mainResponse.trim().isEmpty
          ? 'Final generator returned an empty response'
          : null,
    );
  }

  /// Tracker-only cycle: runs the pre-gen tracker phase and returns the
  /// produced briefs WITHOUT firing the final generator or post-gen
  /// trackers. Used by [TrackerMemoryRecoveryService] to restore lost
  /// `studioOutputs` without burning the final-generator model on every
  /// historical message.
  Future<StudioPipelineResult> runTrackersOnly({
    required StudioConfig config,
    required PromptResult promptResult,
    required PromptPayload promptPayload,
    required ApiConfig apiConfig,
    required String sessionId,
    CancelToken? cancelToken,
  }) async {
    final token = cancelToken ?? CancelToken();
    if (token.isCancelled) {
      return const StudioPipelineResult(status: 'aborted', response: '');
    }

    final presetId = await _ref.read(activeStudioPresetProvider.future);
    final phaseResult = await _phaseRunner.run(
      config: config,
      presetId: presetId,
      promptResult: promptResult,
      promptPayload: promptPayload,
      apiConfig: apiConfig,
      sessionId: sessionId,
      token: token,
    );

    return StudioPipelineResult(
      status: phaseResult.status,
      response: '',
      stageBriefs: phaseResult.briefs,
      error: phaseResult.error,
    );
  }

  /// Static delegator — see [StudioActivationGate.matchesActivationKeywords].
  /// Kept on this class because tests reference
  /// `MemoryStudioService.matchesActivationKeywords`.
  @visibleForTesting
  static bool matchesActivationKeywords(
    List<String> keywords,
    List<String> historyContents,
    int scanDepth,
  ) => StudioActivationGate.matchesActivationKeywords(
    keywords,
    historyContents,
    scanDepth,
  );

  /// Static delegator — see [StudioActivationGate.splitAgentsByPhase]. Kept on
  /// this class because tests reference `MemoryStudioService.splitAgentsByPhase`.
  @visibleForTesting
  static AgentPhaseSplit splitAgentsByPhase(List<StudioAgent> agents) =>
      StudioActivationGate.splitAgentsByPhase(agents);

  void _log(String message) {
    debugPrint('[Studio] $message');
  }
}

class StudioPipelineResult {
  final String status;
  final String response;
  final String reasoning;
  final String? rawResponseJson;
  final List<StudioStageBrief> stageBriefs;
  final String? error;

  const StudioPipelineResult({
    required this.status,
    required this.response,
    this.reasoning = '',
    this.rawResponseJson,
    this.stageBriefs = const [],
    this.error,
  });
}
