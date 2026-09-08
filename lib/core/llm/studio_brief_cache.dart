import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/studio_config.dart';
import '../utils/cast_helpers.dart';
import 'agent_runner.dart';
import 'prompt_builder.dart';
import 'studio_brief_parser.dart';
import 'studio_stage_brief.dart';

/// Owns the Studio brief cache: probe, persist, key derivation, and
/// refresh-policy inference. Extracted from [MemoryStudioService] (plan §2):
/// the cache is the single piece of mutable state in the chat-time pipeline,
/// and the surrounding helpers are pure functions of their parameters.
///
/// The cache is per-session-lifetime (in-memory, not persisted to Drift). Keys
/// hash the session, execution-relevant agent and preset content, and (for
/// `scene` policy) the scene signature, so edits invalidate automatically.
class StudioBriefCache {
  final Map<String, CachedStudioBrief> _briefCache = {};
  final StudioBriefParser _briefParser;

  StudioBriefCache(this._briefParser);

  /// Probe the cache for one tracker. [hit] = true when a usable cached brief
  /// exists for this turn; [brief] carries the sanitized cached brief. Used by
  /// the orchestrator to split trackers into cached (skip LLM) vs.
  /// batchable/individual before invoking `TrackerBatcher`.
  CacheProbe probeCache({
    required StudioAgent agent,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required String sessionId,
    required ResolvedAgentConfig resolvedConfig,
    required int trackerContextSize,
    required int? maxTokensOverride,
    required double? temperatureOverride,
    required PromptPayload promptPayload,
    required String sceneKey,
    required int turnIndex,
  }) {
    final policy = effectiveRefreshPolicy(agent);
    final cacheKey = cacheKeyForAgent(
      config: config,
      studioPreset: studioPreset,
      sessionId: sessionId,
      resolvedConfig: resolvedConfig,
      trackerContextSize: trackerContextSize,
      maxTokensOverride: maxTokensOverride,
      temperatureOverride: temperatureOverride,
      agent: agent,
      policy: policy,
      sceneKey: sceneKey,
    );
    final cached = usableCachedBrief(
      cacheKey: cacheKey,
      policy: policy,
      sceneChanged: lastUserMessageSuggestsSceneChange(promptPayload),
      turnIndex: turnIndex,
    );
    if (cached != null) {
      final sanitizedCachedBrief = _briefParser.sanitizeIntermediateAgentOutput(
        agent,
        cached.brief,
      );
      return CacheProbe(
        hit: true,
        policy: policy,
        cacheKey: cacheKey,
        brief: StudioStageBrief(
          agentId: agent.id,
          agentName: agent.name,
          brief: sanitizedCachedBrief,
          status: 'cached',
          refreshPolicy: policy,
          cacheKey: cacheKey,
          cacheHit: true,
        ),
      );
    }
    return CacheProbe(hit: false, policy: policy, cacheKey: cacheKey);
  }

  /// Persist a freshly-fetched brief into the cache if its refresh policy is
  /// cacheable and the run was successful.
  void persistCacheIfCacheable({
    required StudioAgent agent,
    required StudioStageBrief brief,
    required String cacheKey,
    required String policy,
    required int turnIndex,
    required CancelToken cancelToken,
  }) {
    if (cancelToken.isCancelled) return;
    if (brief.status != 'ok') return;
    if (!isCacheablePolicy(policy)) return;
    final existing = _briefCache[cacheKey];
    if (existing != null && existing.createdTurnIndex > turnIndex) return;
    _briefCache[cacheKey] = CachedStudioBrief(
      brief: brief.brief,
      policy: policy,
      createdTurnIndex: turnIndex,
    );
  }

  bool isCacheablePolicy(String policy) =>
      policy == 'static' || policy == 'scene';

  CachedStudioBrief? usableCachedBrief({
    required String cacheKey,
    required String policy,
    required bool sceneChanged,
    required int turnIndex,
  }) {
    if (!isCacheablePolicy(policy)) return null;
    if (policy == 'scene' && sceneChanged) return null;
    final cached = _briefCache[cacheKey];
    if (cached == null) return null;
    if (policy == 'scene' && turnIndex - cached.createdTurnIndex >= 4) {
      return null;
    }
    return cached;
  }

  String cacheKeyForAgent({
    required StudioConfig config,
    required StudioPreset studioPreset,
    required String sessionId,
    required ResolvedAgentConfig resolvedConfig,
    required int trackerContextSize,
    required int? maxTokensOverride,
    required double? temperatureOverride,
    required StudioAgent agent,
    required String policy,
    required String sceneKey,
  }) {
    final agentEnabledKeys = studioPreset.agentEnabled.keys.toList()..sort();
    final blocks = studioPreset.blocks.indexed.toList()
      ..sort((a, b) {
        final result = a.$2.order.compareTo(b.$2.order);
        if (result != 0) return result;
        return a.$1.compareTo(b.$1);
      });
    final base = <String, dynamic>{
      'v': 3,
      'sessionId': sessionId,
      'profileId': config.profileId,
      'studioConfigId': config.sessionId,
      'runApiConfigId': config.runApiConfigId,
      'cheapApiConfigId': config.cheapApiConfigId,
      'resolvedExecution': {
        'endpoint': resolvedConfig.endpoint,
        'model': resolvedConfig.model,
        'protocol': resolvedConfig.protocol,
        'topP': resolvedConfig.topP,
        'topK': resolvedConfig.topK,
        'frequencyPenalty': resolvedConfig.frequencyPenalty,
        'presencePenalty': resolvedConfig.presencePenalty,
        'omitTemperature': resolvedConfig.omitTemperature,
        'omitTopP': resolvedConfig.omitTopP,
        'stream': resolvedConfig.stream,
        'cacheControlTtl': resolvedConfig.cacheControlTtl,
        'cacheBreakpointMode': resolvedConfig.cacheBreakpointMode,
        'sessionIdMode': resolvedConfig.sessionIdMode,
        'contextSize': resolvedConfig.contextSize,
        'trackerContextSize': trackerContextSize,
        'maxTokensOverride': maxTokensOverride,
        'temperatureOverride': temperatureOverride,
        'extraRequestParameters': [
          for (final parameter in resolvedConfig.extraRequestParameters)
            {
              'key': parameter.key,
              'value': parameter.value,
              'enabled': parameter.enabled,
            },
        ],
      },
      'preset': {
        'id': studioPreset.id,
        'executionMode': studioPreset.executionMode.wireName,
        'agentEnabled': {
          for (final key in agentEnabledKeys)
            key: studioPreset.agentEnabled[key],
        },
        'blocks': [
          for (final (_, block) in blocks)
            {
              'id': block.id,
              'section': block.section,
              'kind': block.kind,
              'role': block.role,
              'enabled': block.enabled,
              'order': block.order,
              'content': block.content,
            },
        ],
      },
      'agent': {
        'id': agent.id,
        'name': agent.name,
        'role': agent.role,
        'order': agent.order,
        'enabled': agent.enabled,
        'endpoint': agent.endpoint,
        'timeoutMs': agent.timeoutMs,
        'temperature': agent.temperature,
        'maxTokens': agent.maxTokens,
        'sourceBlockNames': agent.sourceBlockNames,
        'refreshPolicy': agent.refreshPolicy,
        'invalidationSignals': agent.invalidationSignals,
        'contextSize': agent.contextSize,
        'runInterval': agent.runInterval,
        'maxParallelJobs': agent.maxParallelJobs,
        'runIndividually': agent.runIndividually,
        'activationKeywords': agent.activationKeywords,
        'activationScanDepth': agent.activationScanDepth,
        'phase': agent.phase,
      },
      'refreshPolicy': policy,
      if (policy == 'scene') 'sceneKey': sceneKey,
    };
    return computeHash(jsonEncode(base));
  }

  String sceneCacheKey(PromptPayload payload) {
    final summary = payload.summaryContent?.trim() ?? '';
    final authorsNote = payload.authorsNote?.content.trim() ?? '';
    final recentAssistants = payload.history
        .where((m) => m.role == 'assistant')
        .length;
    return computeHash(
      jsonEncode({
        'characterId': payload.character.id,
        'personaId': payload.persona?.id ?? '',
        'summary': summary,
        'authorsNote': authorsNote,
        'assistantBucket': recentAssistants ~/ 4,
      }),
    );
  }

  int assistantTurnCount(PromptPayload payload) {
    return payload.history.where((m) => m.role == 'assistant').length;
  }

  bool lastUserMessageSuggestsSceneChange(PromptPayload payload) {
    for (final message in payload.history.reversed) {
      if (message.role != 'user') continue;
      final text = message.content.toLowerCase();
      return RegExp(
        r'\b(new scene|next scene|time skip|timeskip|later|meanwhile|the next day|next morning|новая сцена|следующая сцена|позже|тем временем|на следующий день|утром|вечером|ночью|перенес[её]мся)\b',
        caseSensitive: false,
      ).hasMatch(text);
    }
    return false;
  }

  String normalizeRefreshPolicy(String policy) {
    return switch (policy.trim().toLowerCase()) {
      'static' || 'scene' || 'turn' => policy.trim().toLowerCase(),
      _ => 'turn',
    };
  }

  String effectiveRefreshPolicy(StudioAgent agent) {
    final policy = normalizeRefreshPolicy(agent.refreshPolicy);
    if (policy != 'turn' || agent.invalidationSignals.isNotEmpty) {
      return policy;
    }

    final text = [agent.name, agent.sourceBlockNames].join('\n').toLowerCase();
    if (RegExp(
      r'ban|banned|forbidden|clich|клиш|запрет|forbidden words',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'static';
    }
    if (RegExp(
      r'lumia|ghost in the machine|meta-weaver|meta weaver|ooc interface|ooc policy|weaver',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'scene';
    }
    if (RegExp(
      r'last\s+3|recent chat|last beat|last user|continuity|memory|current scene|anti-loop|anti-echo',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'turn';
    }
    if (RegExp(
      r'tone|genre|style|romantic|fluff|comfort|lumia|ghost|meta-weaver|meta weaver|director',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'scene';
    }
    return policy;
  }
}

class CachedStudioBrief {
  final String brief;
  final String policy;
  final int createdTurnIndex;

  const CachedStudioBrief({
    required this.brief,
    required this.policy,
    required this.createdTurnIndex,
  });
}

/// Result of probing the cache for one tracker before batching.
class CacheProbe {
  final bool hit;
  final String policy;
  final String cacheKey;
  final StudioStageBrief? brief;

  const CacheProbe({
    required this.hit,
    required this.policy,
    required this.cacheKey,
    this.brief,
  });
}
