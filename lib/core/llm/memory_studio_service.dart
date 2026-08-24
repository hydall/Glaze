import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/api_config.dart';
import '../models/studio_config.dart';
import '../state/active_studio_preset_provider.dart';
import '../state/db_provider.dart';
import 'agent_runner.dart';
import 'studio_activation_gate.dart';
import 'studio_agent_executor.dart';
import 'studio_batch_coordinator.dart';
import 'studio_brief_cache.dart';
import 'studio_brief_deduper.dart';
import 'studio_brief_parser.dart';
import 'studio_message_builder.dart';
import 'studio_prompt_text.dart';
import 'studio_stage_brief.dart';
import 'studio_turn_config_snapshot.dart';
import 'controller_batcher.dart';
import 'studio/controller_phase_runner.dart';
import 'studio/controller_result_mapper.dart';
import 'generation_context_inputs.dart';
import 'studio/studio_context.dart';

// Re-export so existing importers of `AgentPhaseSplit` via this file (e.g.
// tests, studio_post_processing) keep their import path after the move to
// studio_activation_gate.dart.
export 'studio_activation_gate.dart' show AgentPhaseSplit;
export 'studio/controller_phase_runner.dart' show PreGenPhaseResult;

/// Session-bound Studio pipeline.
///
/// The Studio menu stores a user-editable [StudioConfig]. At generation time
/// this service runs enabled agents in order. Intermediate agents produce
/// compact briefs; the last enabled agent produces the actual RP response.
class MemoryStudioService {
  final Ref _ref;
  final AgentRunner _runner;
  final ControllerBatcher _batcher;
  final StudioPromptText _promptText = const StudioPromptText();
  late final StudioBriefParser _briefParser = StudioBriefParser(_log);
  late final StudioBriefDeduper _briefDeduper = StudioBriefDeduper(
    _briefParser,
  );
  late final StudioBriefCache _briefCache = StudioBriefCache(_briefParser);
  late final StudioMessageBuilder _messageBuilder = StudioMessageBuilder(
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
    _messageBuilder,
    _log,
  );
  late final StudioTrackerResultMapper _resultMapper =
      StudioTrackerResultMapper(_briefParser, _briefCache);
  late final ControllerPhaseRunner _phaseRunner = ControllerPhaseRunner(
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
    required GenerationContextInputs inputs,
    required StudioContext trackerContext,
    required StudioContext finalContext,
    required ApiConfig apiConfig,
    required String sessionId,
    StudioTurnConfigSnapshot? turnConfig,
    CancelToken? cancelToken,
    void Function(String text, String? reasoning)? onFinalResponseUpdate,
    void Function()? onFinalStart,
    void Function(List<Map<String, dynamic>> messages)? onFinalMessagesBuilt,
    void Function(Set<String> classifications)?
    onFinalLorebookClassificationsBuilt,
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
      inputs: inputs,
      context: trackerContext,
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
    final studioPreset = phaseResult.studioPreset!;
    final finalAgent = split.finalAgent!;
    onFinalStart?.call();
    final agentResult = await _executor.runFinalGenerator(
      agent: finalAgent,
      context: finalContext,
      apiConfig: apiConfig,
      config: config,
      studioPreset: studioPreset,
      priorBriefs: briefs,
      sessionId: sessionId,
      cancelToken: token,
      apiConfigId: studioPreset.expensiveApiConfigId,
      onFinalResponseUpdate: onFinalResponseUpdate,
      onMessagesBuilt: onFinalMessagesBuilt,
      onLorebookClassificationsBuilt: onFinalLorebookClassificationsBuilt,
      turnConfig: turnConfig,
    );
    if (token.isCancelled) {
      return const StudioPipelineResult(status: 'aborted', response: '');
    }
    var mainResponse = agentResult.text;
    var mainReasoning = agentResult.reasoning;
    final postBriefs = <StudioStageBrief>[];
    for (final agent in split.postGenTrackers) {
      if (token.isCancelled) {
        return const StudioPipelineResult(status: 'aborted', response: '');
      }
      // Post-processing agents run every turn: cadence and keyword gating were
      // per-agent overrides, and an agent no longer carries any (§4).
      final result = await _executor.runPostProcessingTracker(
        agent: agent,
        mainResponse: mainResponse,
        context: finalContext,
        apiConfig: apiConfig,
        config: config,
        studioPreset: studioPreset,
        sessionId: sessionId,
        cancelToken: token,
        apiConfigId: studioPreset.cleanerApiConfigId,
        turnConfig: turnConfig,
      );
      postBriefs.add(result);
      if (result.status == 'error') {
        return StudioPipelineResult(
          status: 'error',
          response: '',
          stageBriefs: [...briefs, ...postBriefs],
          error:
              'Studio tracker "${result.agentName}" failed after 2 retries: '
              '${result.error ?? 'tracker failed'}. Please restart generation.',
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
      rawResponseJson: agentResult.rawResponseJson,
      stageBriefs: [...briefs, ...postBriefs],
      error: mainResponse.trim().isEmpty
          ? 'Final generator returned an empty response'
          : null,
    );
  }

  /// Tracker-only cycle: runs the pre-gen tracker phase and returns the
  /// produced briefs WITHOUT firing the final generator or post-gen
  /// trackers. Used by [ControllerMemoryRecoveryService] to restore lost
  /// `studioOutputs` without burning the final-generator model on every
  /// historical message.
  Future<StudioPipelineResult> runTrackersOnly({
    required StudioConfig config,
    required GenerationContextInputs inputs,
    required StudioContext context,
    required ApiConfig apiConfig,
    required String sessionId,
    StudioTurnConfigSnapshot? turnConfig,
    CancelToken? cancelToken,
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
      inputs: inputs,
      context: context,
      apiConfig: apiConfig,
      sessionId: sessionId,
      token: token,
      turnConfig: turnConfig,
    );
    return StudioPipelineResult(
      status: phaseResult.status,
      response: '',
      stageBriefs: phaseResult.briefs,
      error: phaseResult.error,
    );
  }

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
