import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:glaze_flutter/core/llm/agent_runner.dart';
import 'package:glaze_flutter/core/llm/memory_studio_service.dart';
import 'package:glaze_flutter/core/llm/studio/agent_config_resolver.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/llm/controller_batcher.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

/// A fake [AgentRunner] that overrides [resolveAgentConfig] to return a
/// fixed [ResolvedAgentConfig] for every agent — without touching the
/// database / apiListProvider. Used by the `groupAgents` tests so they can
/// exercise the real batching-key logic (which now includes `phase`) without
/// a live API config. All other methods are inherited unchanged and are not
/// called by these tests.
class _FakeAgentRunner extends AgentRunner {
  _FakeAgentRunner()
      : super(
          configResolver: AgentConfigResolver(
            loadApiConfigs: () async => const [],
            readActiveApiConfig: () => null,
            readPipelineSettings: () => const PipelineSettings(),
          ),
          readPipelineSettings: () => const PipelineSettings(),
        );

  @override
  Future<ResolvedAgentConfig> resolveAgentConfig(
    StudioAgent agent,
    ApiConfig current,
    String sessionId, {
    bool isFinalResponse = false,
    String? apiConfigId,
    StudioTurnConfigSnapshot? turnConfig,
  }) async {
    return ResolvedAgentConfig(
      endpoint: 'https://test',
      apiKey: 'k',
      model: current.model.isNotEmpty ? current.model : 'test-model',
      protocol: 'openai',
      stream: false,
    );
  }
}

ApiConfig _stubApiConfig({String model = 'test-model'}) {
  return ApiConfig(
    id: 'test',
    name: 'test',
    endpoint: 'https://test',
    apiKey: 'k',
    model: model,
    protocol: 'openai',
  );
}

void main() {
  group('StudioAgent.normalizeAgentPhaseForType', () {
    test('is a no-op for unknown agent types — returns configured phase', () {
      // Glaze has no built-in typed agents, so the user's configured
      // phase is always respected. This is the documented stub seam: future
      // built-in types (prose-guardian / continuity) would be forced to
      // post_processing here.
      expect(
        StudioAgent.normalizeAgentPhaseForType('any-id', 'pre_generation'),
        'pre_generation',
      );
      expect(
        StudioAgent.normalizeAgentPhaseForType('any-id', 'post_processing'),
        'post_processing',
      );
      expect(
        StudioAgent.normalizeAgentPhaseForType('prose-guardian', 'pre_generation'),
        'pre_generation',
      );
      expect(
        StudioAgent.normalizeAgentPhaseForType('continuity', 'pre_generation'),
        'pre_generation',
      );
    });

    test('default phase is pre_generation (backward compat)', () {
      final agent = StudioAgent(id: 'a', name: 'A');
      expect(agent.phase, 'pre_generation');
    });

    test('phase is preserved through JSON round-trip', () {
      final agent = StudioAgent(
        id: 'a',
        name: 'Rewriter',
        phase: 'post_processing',
      );
      final json = agent.toJson();
      final restored = StudioAgent.fromJson(json);
      expect(restored.phase, 'post_processing');
    });
  });

  group('MemoryStudioService.splitAgentsByPhase', () {
    test('empty agents → empty split, null finalAgent', () {
      final split = MemoryStudioService.splitAgentsByPhase(const []);
      expect(split.preGenTrackers, isEmpty);
      expect(split.postGenTrackers, isEmpty);
      expect(split.finalAgent, isNull);
    });

    test('all pre-gen: last pre-gen = generator, rest = pre-gen trackers', () {
      // The classic 2-phase layout: 3 pre-gen trackers + 1 generator.
      final agents = [
        StudioAgent(id: 't1', name: 'T1', order: 0, phase: 'pre_generation'),
        StudioAgent(id: 't2', name: 'T2', order: 1, phase: 'pre_generation'),
        StudioAgent(id: 't3', name: 'T3', order: 2, phase: 'pre_generation'),
        StudioAgent(id: 'gen', name: 'Gen', order: 3, phase: 'pre_generation'),
      ];
      final split = MemoryStudioService.splitAgentsByPhase(agents);
      expect(split.preGenTrackers.map((a) => a.id), ['t1', 't2', 't3']);
      expect(split.postGenTrackers, isEmpty);
      expect(split.finalAgent?.id, 'gen');
    });

    test('post-gen agents are excluded from generator selection', () {
      // 2 pre-gen + 1 generator (pre-gen) + 2 post-gen.
      final agents = [
        StudioAgent(id: 't1', name: 'T1', order: 0, phase: 'pre_generation'),
        StudioAgent(id: 'gen', name: 'Gen', order: 1, phase: 'pre_generation'),
        StudioAgent(id: 'p1', name: 'P1', order: 2, phase: 'post_processing'),
        StudioAgent(id: 'p2', name: 'P2', order: 3, phase: 'post_processing'),
      ];
      final split = MemoryStudioService.splitAgentsByPhase(agents);
      expect(split.preGenTrackers.map((a) => a.id), ['t1']);
      expect(split.postGenTrackers.map((a) => a.id), ['p1', 'p2']);
      // Generator = last PRE-gen agent, NOT the last agent overall.
      expect(split.finalAgent?.id, 'gen');
    });

    test('post-gen tracker after generator in order still post-gen', () {
      // A post-gen agent with a higher order than the generator must not
      // become the generator.
      final agents = [
        StudioAgent(id: 'gen', name: 'Gen', order: 0, phase: 'pre_generation'),
        StudioAgent(id: 'rewriter', name: 'Rewriter', order: 1, phase: 'post_processing'),
      ];
      final split = MemoryStudioService.splitAgentsByPhase(agents);
      expect(split.preGenTrackers, isEmpty);
      expect(split.postGenTrackers.map((a) => a.id), ['rewriter']);
      expect(split.finalAgent?.id, 'gen');
    });

    test('fallback: all post-gen → last agent is generator, removed from post-gen', () {
      // No pre-gen agent at all. The last enabled agent becomes the generator
      // regardless of phase, and is removed from the post-gen list so it is
      // not run twice.
      final agents = [
        StudioAgent(id: 'p1', name: 'P1', order: 0, phase: 'post_processing'),
        StudioAgent(id: 'p2', name: 'P2', order: 1, phase: 'post_processing'),
      ];
      final split = MemoryStudioService.splitAgentsByPhase(agents);
      expect(split.preGenTrackers, isEmpty);
      // p2 was pulled out to be the generator.
      expect(split.postGenTrackers.map((a) => a.id), ['p1']);
      expect(split.finalAgent?.id, 'p2');
    });
  });

  group('ControllerBatcher.groupAgents — postProcessingDataKey (phase)', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    test('pre-gen and post-gen agents on same model → separate groups', () async {
      // Two agents on the same (protocol, model) but different phases must
      // NOT be batched together — the post-gen one needs mainResponse in
      // its context, the pre-gen one does not. The `|<phase>` suffix in the
      // grouping key separates them.
            final runner = _FakeAgentRunner();
      final batcher = ControllerBatcher(runner);

      final apiConfig = _stubApiConfig(model: 'same-model');
      final agents = [
        StudioAgent(
          id: 'pre1',
          name: 'PreTracker',
          order: 0,
          phase: 'pre_generation',
        ),
        StudioAgent(
          id: 'post1',
          name: 'PostTracker',
          order: 1,
          phase: 'post_processing',
        ),
      ];

      final grouping = await batcher.groupAgents(
        agents: agents,
        apiConfig: apiConfig,
        sessionId: 's1',
      );

      expect(grouping.batchGroups.length, 2,
          reason: 'pre-gen and post-gen on the same model must NOT batch together');
      expect(grouping.individualAgents, isEmpty);

      // Each group has exactly one agent.
      final preGroup = grouping.batchGroups.firstWhere(
        (g) => g.agents.any((a) => a.id == 'pre1'),
      );
      final postGroup = grouping.batchGroups.firstWhere(
        (g) => g.agents.any((a) => a.id == 'post1'),
      );
      expect(preGroup.agents.length, 1);
      expect(postGroup.agents.length, 1);
      // The keys differ by the phase suffix.
      expect(preGroup.key, contains('pre_generation'));
      expect(postGroup.key, contains('post_processing'));
      expect(preGroup.key, isNot(postGroup.key));
    });

    test('two pre-gen agents on same model → one group (unchanged behavior)', () async {
      // Backward compat: pre-gen agents on the same model still batch together
      // (the `|pre_generation` suffix is uniform, so it does not split them).
            final runner = _FakeAgentRunner();
      final batcher = ControllerBatcher(runner);

      final apiConfig = _stubApiConfig(model: 'same-model');
      final agents = [
        StudioAgent(
          id: 'pre1',
          name: 'PreA',
          order: 0,
          phase: 'pre_generation',
        ),
        StudioAgent(
          id: 'pre2',
          name: 'PreB',
          order: 1,
          phase: 'pre_generation',
        ),
      ];

      final grouping = await batcher.groupAgents(
        agents: agents,
        apiConfig: apiConfig,
        sessionId: 's1',
      );

      expect(grouping.batchGroups.length, 1,
          reason: 'two pre-gen agents on the same model batch together');
      expect(grouping.batchGroups.first.agents.length, 2);
    });

    test('two post-gen agents on same model → one group', () async {
      // Two post-gen agents on the same model DO batch together (they both
      // receive mainResponse; uniform phase suffix keeps them in one group).
            final runner = _FakeAgentRunner();
      final batcher = ControllerBatcher(runner);

      final apiConfig = _stubApiConfig(model: 'same-model');
      final agents = [
        StudioAgent(
          id: 'post1',
          name: 'PostA',
          order: 0,
          phase: 'post_processing',
        ),
        StudioAgent(
          id: 'post2',
          name: 'PostB',
          order: 1,
          phase: 'post_processing',
        ),
      ];

      final grouping = await batcher.groupAgents(
        agents: agents,
        apiConfig: apiConfig,
        sessionId: 's1',
      );

      expect(grouping.batchGroups.length, 1);
      expect(grouping.batchGroups.first.agents.length, 2);
    });
  });

  group('runTrackerCycle — characterization (post-gen agent does not crash)', () {
    // `runTrackerCycle` is too entangled with caching / batcher / AgentRunner
    // to mock cleanly for a full 3-phase integration test. This characterization
    // test verifies the smallest public seam: `splitAgentsByPhase` correctly
    // partitions a realistic 1-tracker + 1-generator + 1-post-gen config, so
    // the 3-phase flow in `runTrackerCycle` will route the post-gen agent to
    // the post-processing phase (not to the pre-gen batch, not to the
    // generator slot). The full live LLM path is covered by manual /
    // integration testing (see docs/PLAN_AGENTIC_STUDIO.md Feature 6).
    test('1 pre-gen + 1 generator + 1 post-gen → correct split', () {
      final agents = [
        StudioAgent(id: 'tracker', name: 'T', order: 0, phase: 'pre_generation'),
        StudioAgent(id: 'gen', name: 'G', order: 1, phase: 'pre_generation'),
        StudioAgent(id: 'rewriter', name: 'R', order: 2, phase: 'post_processing'),
      ];
      final split = MemoryStudioService.splitAgentsByPhase(agents);
      expect(split.preGenTrackers.map((a) => a.id), ['tracker']);
      expect(split.finalAgent?.id, 'gen');
      expect(split.postGenTrackers.map((a) => a.id), ['rewriter']);
    });
  });
}
