import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/agent_runner.dart';
import 'package:glaze_flutter/core/llm/studio_brief_cache.dart';
import 'package:glaze_flutter/core/llm/studio_brief_parser.dart';
import 'package:glaze_flutter/core/llm/studio_stage_brief.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  late StudioBriefCache cache;

  setUp(() {
    cache = StudioBriefCache(StudioBriefParser((_) {}));
  });

  test('same profile in different sessions does not share static briefs', () {
    final firstKey = _cacheKey(cache, sessionId: 'session-a');
    final secondKey = _cacheKey(cache, sessionId: 'session-b');

    cache.persistCacheIfCacheable(
      agent: _agent,
      brief: _brief('session-a brief'),
      cacheKey: firstKey,
      policy: 'static',
      turnIndex: 3,
      cancelToken: CancelToken(),
    );

    expect(firstKey, isNot(secondKey));
    expect(
      cache.usableCachedBrief(
        cacheKey: secondKey,
        policy: 'static',
        sceneChanged: false,
        turnIndex: 3,
      ),
      isNull,
    );
  });

  test('preset content edit changes the cache key', () {
    final original = _cacheKey(cache);
    final edited = _cacheKey(
      cache,
      preset: _preset.copyWith(
        blocks: [
          _preset.blocks.single.copyWith(content: 'Edited instructions'),
        ],
      ),
    );

    expect(edited, isNot(original));
  });

  test('agentEnabled map insertion order does not change the cache key', () {
    final first = _cacheKey(
      cache,
      preset: _preset.copyWith(
        agentEnabled: {'continuity': true, 'narrative': false},
      ),
    );
    final second = _cacheKey(
      cache,
      preset: _preset.copyWith(
        agentEnabled: {'narrative': false, 'continuity': true},
      ),
    );

    expect(second, first);
  });

  test('older turn cannot overwrite a newer cached brief', () {
    final key = _cacheKey(cache);
    cache.persistCacheIfCacheable(
      agent: _agent,
      brief: _brief('newer'),
      cacheKey: key,
      policy: 'static',
      turnIndex: 8,
      cancelToken: CancelToken(),
    );
    cache.persistCacheIfCacheable(
      agent: _agent,
      brief: _brief('older'),
      cacheKey: key,
      policy: 'static',
      turnIndex: 7,
      cancelToken: CancelToken(),
    );

    final cached = cache.usableCachedBrief(
      cacheKey: key,
      policy: 'static',
      sceneChanged: false,
      turnIndex: 8,
    );
    expect(cached?.brief, 'newer');
    expect(cached?.createdTurnIndex, 8);
  });
}

const _config = StudioConfig(
  sessionId: 'profile-storage-id',
  profileId: 'shared-profile',
  enabled: true,
  cheapApiConfigId: 'tracker-api',
);

const _agent = StudioAgent(
  id: 'continuity',
  name: 'Continuity',
  sourceBlockNames: 'continuity_rules',
  refreshPolicy: 'static',
);

const _preset = StudioPreset(
  id: 'preset-id',
  executionMode: StudioExecutionMode.assisted,
  agentEnabled: {'continuity': true},
  blocks: [
    StudioPresetBlock(
      id: 'continuity-rules',
      section: 'pregen',
      kind: 'agent_instruction',
      role: 'system',
      order: 2,
      content: 'Original instructions',
    ),
  ],
);

const _resolvedConfig = ResolvedAgentConfig(
  endpoint: 'https://example.test/v1',
  apiKey: 'not-part-of-the-cache-key',
  model: 'tracker-model',
  protocol: 'openai',
);

String _cacheKey(
  StudioBriefCache cache, {
  String sessionId = 'session-a',
  StudioPreset preset = _preset,
}) {
  return cache.cacheKeyForAgent(
    config: _config,
    studioPreset: preset,
    sessionId: sessionId,
    resolvedConfig: _resolvedConfig,
    trackerContextSize: 5,
    maxTokensOverride: null,
    temperatureOverride: null,
    agent: _agent,
    policy: 'static',
    sceneKey: '',
  );
}

StudioStageBrief _brief(String text) =>
    StudioStageBrief(agentId: _agent.id, agentName: _agent.name, brief: text);
