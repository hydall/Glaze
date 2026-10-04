import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/studio_config.dart';
import '../models/chat_message.dart';
import '../utils/cast_helpers.dart';
import 'agent_runner.dart';
import 'generation_context_inputs.dart';
import 'prompt_builder.dart';
import 'studio_brief_parser.dart';
import 'studio_controller_ontology.dart';
import 'studio_stage_brief.dart';
import 'studio/studio_context.dart';

/// Owns the Studio brief cache: probe, persist, key derivation, and
/// refresh-policy normalization. Extracted from [MemoryStudioService] (plan §2):
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
  /// batchable/individual before invoking `ControllerBatcher`.
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
    String studioRegexIdentity = '',
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
      studioRegexIdentity: studioRegexIdentity,
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

  CacheProbe probeCacheFromInputs({
    required StudioAgent agent,
    required StudioConfig config,
    required StudioPreset studioPreset,
    required String sessionId,
    required ResolvedAgentConfig resolvedConfig,
    required int trackerContextSize,
    required int? maxTokensOverride,
    required double? temperatureOverride,
    required GenerationContextInputs inputs,
    required StudioContext context,
    required String sceneKey,
    required int turnIndex,
    String studioRegexIdentity = '',
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
      ledgerInjectionIdentity: context.diagnostics.ledgerInjectionIdentity,
      studioRegexIdentity: studioRegexIdentity,
    );
    final cached = usableCachedBrief(
      cacheKey: cacheKey,
      policy: policy,
      sceneChanged: lastUserMessageSuggestsSceneChangeFromInputs(inputs),
      turnIndex: turnIndex,
    );
    if (cached == null) {
      return CacheProbe(hit: false, policy: policy, cacheKey: cacheKey);
    }
    return CacheProbe(
      hit: true,
      policy: policy,
      cacheKey: cacheKey,
      brief: StudioStageBrief(
        agentId: agent.id,
        agentName: agent.name,
        brief: _briefParser.sanitizeIntermediateAgentOutput(
          agent,
          cached.brief,
        ),
        status: 'cached',
        refreshPolicy: policy,
        cacheKey: cacheKey,
        cacheHit: true,
      ),
    );
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
    String ledgerInjectionIdentity = '',
    String studioRegexIdentity = '',
  }) {
    // Generation parameters live on the agent's spec, not on the agent (§4),
    // so the cache key must read them from there or it stops noticing changes.
    final spec = StudioControllerOntology.specForAgent(agent);
    final agentEnabledKeys = studioPreset.agentEnabled.keys.toList()..sort();
    final blocks = studioPreset.blocks.indexed.toList()
      ..sort((a, b) {
        final result = a.$2.order.compareTo(b.$2.order);
        if (result != 0) return result;
        return a.$1.compareTo(b.$1);
      });
    final base = <String, dynamic>{
      'v': 8,
      'sessionId': sessionId,
      'studioConfigId': config.sessionId,
      'cheapApiConfigId': studioPreset.cheapApiConfigId,
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
        'agentEnabled': {
          for (final key in agentEnabledKeys)
            key: studioPreset.agentEnabled[key],
        },
        'blocks': [
          for (final (_, block) in blocks)
            {
              'id': block.id,
              'title': block.title,
              'type': block.type.name,
              'contextSlot': block.contextSlot?.name,
              'mode': block.mode,
              'injectionPoint': block.injectionPoint,
              'targetAgentId': block.targetAgentId,
              'sourceAgentId': block.sourceAgentId,
              'role': block.role,
              'enabled': block.enabled,
              'locked': block.locked,
              'order': block.order,
              'section': block.section,
              'isStatic': block.isStatic,
              'groupBoundary': block.groupBoundary,
              'content': block.content,
            },
        ],
      },
      'agent': {
        'id': agent.id,
        'controllerId': agent.controllerId,
        'name': agent.name,
        'role': agent.role,
        'order': agent.order,
        'enabled': agent.enabled,
        'timeoutMs': spec?.timeoutMs ?? 4000,
        'temperature': spec?.temperature ?? 0.3,
        'maxTokens': spec?.maxTokens ?? 8000,
        'refreshPolicy': agent.refreshPolicy,
        'contextSize': StudioControllerOntology.contextSizeOf(spec),
        'maxParallelJobs': agent.maxParallelJobs,
        'phase': agent.phase,
      },
      'refreshPolicy': policy,
      'ledgerInjectionIdentity': ledgerInjectionIdentity,
      'studioRegexIdentity': studioRegexIdentity,
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

  String sceneCacheKeyFromInputs(GenerationContextInputs inputs) {
    final summary = inputs.summaryContent?.trim() ?? '';
    final authorsNote = inputs.authorsNote?.content.trim() ?? '';
    final recentAssistants = inputs.history
        .where((message) => message.role == 'assistant')
        .length;
    return computeHash(
      jsonEncode({
        'characterId': inputs.character.id,
        'personaId': inputs.persona?.id ?? '',
        'summary': summary,
        'authorsNote': authorsNote,
        'assistantBucket': recentAssistants ~/ 4,
      }),
    );
  }

  int assistantTurnCountFromInputs(GenerationContextInputs inputs) =>
      inputs.history.where((message) => message.role == 'assistant').length;

  bool lastUserMessageSuggestsSceneChangeFromInputs(
    GenerationContextInputs inputs,
  ) => _historySuggestsSceneChange(inputs.history);

  bool lastUserMessageSuggestsSceneChange(PromptPayload payload) {
    return _historySuggestsSceneChange(payload.history);
  }

  bool _historySuggestsSceneChange(List<ChatMessage> history) {
    for (final message in history.reversed) {
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
    return normalizeRefreshPolicy(agent.refreshPolicy);
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
