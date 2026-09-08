import 'dart:async';

import 'package:dio/dio.dart';

import '../../db/repositories/studio_preset_repo.dart';
import '../../models/api_config.dart';
import '../../models/pipeline_settings.dart';
import '../../models/studio_config.dart';
import '../prompt_builder.dart';
import '../studio_activation_gate.dart';
import '../studio_agent_executor.dart';
import '../studio_batch_coordinator.dart';
import '../studio_brief_cache.dart';
import '../studio_brief_parser.dart';
import '../studio_stage_brief.dart';
import '../studio_turn_config_snapshot.dart';
import '../tracker_batcher.dart';
import 'studio_tracker_result_mapper.dart';

/// Result of the shared pre-gen tracker phase. Both [MemoryStudioService.runTrackerCycle]
/// and [MemoryStudioService.runTrackersOnly] call [StudioTrackerPhaseRunner.run]
/// and receive this. `runTrackerCycle` continues with the generator + post-gen
/// trackers using [split], [turnIndex], [historyForScan], [studioPreset];
/// `runTrackersOnly` returns immediately with [briefs].
class PreGenPhaseResult {
  final String status;
  final List<StudioStageBrief> briefs;
  final String? error;
  final AgentPhaseSplit? split;
  final int turnIndex;
  final List<String> historyForScan;
  final StudioPreset? studioPreset;

  const PreGenPhaseResult({
    required this.status,
    this.briefs = const [],
    this.error,
    this.split,
    this.turnIndex = 0,
    this.historyForScan = const [],
    this.studioPreset,
  });
}

/// Runs the shared pre-gen tracker phase: preset resolution → agent split →
/// due-tracker filtering → cache probing → batched execution → brief assembly.
/// Extracted from `MemoryStudioService` (plan Phase 5a) to eliminate ~180 lines
/// of duplication between `runTrackerCycle` and `runTrackersOnly`.
///
/// Deps via constructor (no `Ref` — all repos/batcher are injected).
class StudioTrackerPhaseRunner {
  final StudioPresetRepo _presetRepo;
  final TrackerBatcher _batcher;
  final StudioBriefCache _briefCache;
  final StudioBriefParser _briefParser;
  final StudioBatchCoordinator _batchCoordinator;
  final StudioAgentExecutor _executor;
  final StudioTrackerResultMapper _resultMapper;
  final PipelineSettings Function() _readPipelineSettings;
  final void Function(String message) _log;

  StudioTrackerPhaseRunner({
    required this._presetRepo,
    required this._batcher,
    required this._briefCache,
    required this._briefParser,
    required this._batchCoordinator,
    required this._executor,
    required this._resultMapper,
    required this._readPipelineSettings,
    required this._log,
  });

  /// Resolves the DB Studio preset for [config]. Returns the preset or an
  /// error string if no preset is found.
  Future<({StudioPreset? preset, String? error})> resolvePreset(
    String presetId,
  ) async {
    final presetRepo = _presetRepo;
    final presetById = await presetRepo.getById(presetId);
    if (presetById != null) {
      return (preset: presetById, error: null);
    }
    final presetDefault = await presetRepo.getDefault();
    if (presetDefault == null) {
      return (
        preset: null,
        error: 'No Studio preset found in DB. Rebuild Studio.',
      );
    }
    return (preset: presetDefault, error: null);
  }

  /// Runs the full pre-gen tracker phase. Returns [PreGenPhaseResult] with
  /// `status == 'ok'` and [briefs] on success, or an error status.
  Future<PreGenPhaseResult> run({
    required StudioConfig config,
    required String presetId,
    required PromptResult promptResult,
    required PromptPayload promptPayload,
    required ApiConfig apiConfig,
    required String sessionId,
    required CancelToken token,
    StudioPreset? studioPreset,
    StudioTurnConfigSnapshot? turnConfig,
  }) async {
    if (token.isCancelled) {
      return const PreGenPhaseResult(status: 'aborted');
    }

    final resolvedPreset = studioPreset == null
        ? await resolvePreset(presetId)
        : (preset: studioPreset, error: null);
    if (resolvedPreset.error != null) {
      return PreGenPhaseResult(status: 'error', error: resolvedPreset.error);
    }
    final effectivePreset = resolvedPreset.preset!;

    try {
      final agents = config.agents.where((a) => a.enabled).toList()
        ..sort((a, b) => a.order.compareTo(b.order));
      if (agents.isEmpty) {
        return const PreGenPhaseResult(status: 'disabled');
      }

      if (token.isCancelled) {
        return const PreGenPhaseResult(status: 'aborted');
      }

      final split = StudioActivationGate.splitAgentsByPhase(agents);
      final finalAgent = split.finalAgent;
      if (finalAgent == null) {
        return const PreGenPhaseResult(status: 'disabled');
      }
      final preGenTrackers = split.preGenTrackers;

      final sceneKey = _briefCache.sceneCacheKey(promptPayload);
      final turnIndex = _briefCache.assistantTurnCount(promptPayload);

      final allHistory = promptResult.messages
          .where((m) => m.isHistory)
          .map((m) => m.content)
          .toList();
      final historyForScan = allHistory.length > 8
          ? allHistory.sublist(allHistory.length - 8)
          : allHistory;
      final dueTrackers = preGenTrackers.where((a) {
        final interval = a.runInterval <= 0 ? 1 : a.runInterval;
        if (turnIndex % interval != 0) return false;
        if (a.activationKeywords.isEmpty) return true;
        return StudioActivationGate.matchesActivationKeywords(
          a.activationKeywords,
          historyForScan,
          a.activationScanDepth,
        );
      }).toList();

      final cachedBriefs = <StudioStageBrief>[];
      final fetchTrackers = <StudioAgent>[];
      final cacheProbeByAgent = <String, CacheProbe>{};
      final trackerContextOverride =
          (turnConfig?.pipelineSettings ?? _readPipelineSettings())
              .studioAgent
              .studioTrackerContextSize;
      for (final agent in dueTrackers) {
        final resolvedConfig = await _executor.resolveTrackerConfig(
          agent: agent,
          apiConfig: apiConfig,
          sessionId: sessionId,
          apiConfigId: config.cheapApiConfigId,
          turnConfig: turnConfig,
        );
        if (token.isCancelled) {
          return const PreGenPhaseResult(status: 'aborted');
        }
        final probe = _briefCache.probeCache(
          agent: agent,
          config: config,
          studioPreset: effectivePreset,
          sessionId: sessionId,
          resolvedConfig: resolvedConfig,
          trackerContextSize: trackerContextOverride,
          maxTokensOverride: _executor.effectiveMaxTokens(agent, turnConfig),
          temperatureOverride: _executor.effectiveTemperature(
            agent,
            turnConfig,
          ),
          promptPayload: promptPayload,
          sceneKey: sceneKey,
          turnIndex: turnIndex,
        );
        cacheProbeByAgent[agent.id] = probe;
        if (probe.hit && probe.brief != null) {
          cachedBriefs.add(probe.brief!);
        } else {
          fetchTrackers.add(agent);
        }
      }

      final batcher = _batcher;
      final grouping = await batcher.groupAgents(
        agents: fetchTrackers,
        apiConfig: apiConfig,
        sessionId: sessionId,
        apiConfigId: config.cheapApiConfigId,
        turnConfig: turnConfig,
      );

      final fetchedResults = await batcher.runPhase(
        batchGroups: grouping.batchGroups,
        individualAgents: grouping.individualAgents,
        runBatch: (group) => _batchCoordinator.runBatchGroup(
          group: group,
          config: config,
          studioPreset: effectivePreset,
          promptResult: promptResult,
          promptPayload: promptPayload,
          apiConfig: apiConfig,
          sessionId: sessionId,
          cancelToken: token,
          apiConfigId: config.cheapApiConfigId,
          batchContextSize: trackerContextOverride,
          turnConfig: turnConfig,
        ),
        runIndividual: (agent) => _executor.runIndividualTracker(
          agent: agent.copyWith(contextSize: trackerContextOverride),
          config: config,
          studioPreset: effectivePreset,
          promptResult: promptResult,
          promptPayload: promptPayload,
          apiConfig: apiConfig,
          sessionId: sessionId,
          cancelToken: token,
          apiConfigId: config.cheapApiConfigId,
          turnConfig: turnConfig,
        ),
      );
      if (token.isCancelled) {
        return const PreGenPhaseResult(status: 'aborted');
      }
      final trackerFailure = _resultMapper.firstFailedTrackerResult(
        fetchedResults,
      );
      if (trackerFailure != null) {
        final failedBriefs = _resultMapper.trackerResultsToBriefs(
          fetchedResults,
          dueTrackers,
          cacheProbeByAgent,
        );
        final error = _resultMapper.trackerFailureMessage(trackerFailure);
        _log('tracker cycle failed session=$sessionId error=$error');
        return PreGenPhaseResult(
          status: 'error',
          briefs: failedBriefs,
          error: error,
        );
      }

      final fetchedBriefs = <StudioStageBrief>[];
      for (final result in fetchedResults) {
        final probe = cacheProbeByAgent[result.agentId];
        final agent = dueTrackers.firstWhere((a) => a.id == result.agentId);
        final sanitized = result.status == 'ok'
            ? _briefParser.sanitizeIntermediateAgentOutput(agent, result.text)
            : result.text;
        final brief = StudioStageBrief(
          agentId: result.agentId,
          agentName: result.agentName,
          brief: sanitized,
          status: result.status,
          error: result.error,
          refreshPolicy: probe?.policy ?? 'turn',
          cacheKey: _briefCache.isCacheablePolicy(probe?.policy ?? 'turn')
              ? probe?.cacheKey
              : null,
          cacheHit: false,
        );
        _briefCache.persistCacheIfCacheable(
          agent: agent,
          brief: brief,
          cacheKey: probe?.cacheKey ?? '',
          policy: probe?.policy ?? 'turn',
          turnIndex: turnIndex,
          cancelToken: token,
        );
        fetchedBriefs.add(brief);
      }

      final briefs = <StudioStageBrief>[];
      for (final agent in dueTrackers) {
        final cached = cachedBriefs
            .where((b) => b.agentId == agent.id)
            .firstOrNull;
        if (cached != null) {
          briefs.add(cached);
          continue;
        }
        final fetched = fetchedBriefs
            .where((b) => b.agentId == agent.id)
            .firstOrNull;
        if (fetched != null) briefs.add(fetched);
      }

      if (token.isCancelled) {
        return const PreGenPhaseResult(status: 'aborted');
      }

      return PreGenPhaseResult(
        status: 'ok',
        briefs: briefs,
        split: split,
        turnIndex: turnIndex,
        historyForScan: historyForScan,
        studioPreset: effectivePreset,
      );
    } on TimeoutException catch (e) {
      _log('tracker cycle timeout session=$sessionId error=${e.message}');
      return PreGenPhaseResult(
        status: 'timeout',
        error: e.message?.isNotEmpty == true ? e.message : 'Studio timed out',
      );
    } catch (e) {
      if (token.isCancelled || (e is DioException && CancelToken.isCancel(e))) {
        return const PreGenPhaseResult(status: 'aborted');
      }
      _log('tracker cycle error session=$sessionId error=$e');
      return PreGenPhaseResult(status: 'error', error: '$e');
    }
  }
}
