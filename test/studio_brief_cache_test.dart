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

  test('typed block routing changes the cache key', () {
    final original = _cacheKey(cache);
    final context = _cacheKey(
      cache,
      preset: _preset.copyWith(
        blocks: [_preset.blocks.single.copyWith(injectionPoint: 'final')],
      ),
    );
    final targeted = _cacheKey(
      cache,
      preset: _preset.copyWith(
        blocks: [_preset.blocks.single.copyWith(targetAgentId: 'continuity')],
      ),
    );

    expect(context, isNot(original));
    expect(targeted, isNot(original));
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

  test('controller identity changes the cache key', () {
    final original = _cacheKey(cache);
    final changed = cache.cacheKeyForAgent(
      config: _config,
      studioPreset: _preset,
      sessionId: 'session-a',
      resolvedConfig: _resolvedConfig,
      trackerContextSize: 5,
      maxTokensOverride: null,
      temperatureOverride: null,
      agent: _agent.copyWith(controllerId: 'narrative'),
      policy: 'static',
      sceneKey: '',
    );

    expect(changed, isNot(original));
  });

  test('Ledger materialization identity changes the cache key', () {
    final first = _cacheKey(cache, ledgerInjectionIdentity: 'ledger-a');
    final second = _cacheKey(cache, ledgerInjectionIdentity: 'ledger-b');

    expect(first, isNot(second));
  });

  test('Studio regex identity changes the cache key', () {
    final first = _cacheKey(cache, studioRegexIdentity: 'regex-a');
    final second = _cacheKey(cache, studioRegexIdentity: 'regex-b');

    expect(first, isNot(second));
  });

  test('refresh policy uses only the normalized explicit value', () {
    expect(
      cache.effectiveRefreshPolicy(
        const StudioAgent(
          id: 'meta-looking',
          name: 'Meta-Weaver forbidden words director',
          refreshPolicy: 'invalid',
        ),
      ),
      'turn',
    );
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

const _config = StudioConfig(sessionId: 'profile-storage-id', enabled: true);

const _agent = StudioAgent(
  id: 'continuity',
  controllerId: 'continuity',
  name: 'Continuity',
  refreshPolicy: 'static',
);

const _preset = StudioPreset(
  id: 'preset-id',
  cheapApiConfigId: 'tracker-api',
  agentEnabled: {'continuity': true},
  blocks: [
    StudioPresetBlock(
      id: 'continuity-rules',
      section: 'pregen',
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
  String ledgerInjectionIdentity = '',
  String studioRegexIdentity = '',
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
    ledgerInjectionIdentity: ledgerInjectionIdentity,
    studioRegexIdentity: studioRegexIdentity,
  );
}

StudioStageBrief _brief(String text) =>
    StudioStageBrief(agentId: _agent.id, agentName: _agent.name, brief: text);
