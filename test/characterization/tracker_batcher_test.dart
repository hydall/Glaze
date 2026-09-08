import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/agent_runner.dart';
import 'package:glaze_flutter/core/llm/tracker_batcher.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  group('TrackerBatcher.buildBatchSystemPrompt', () {
    late TrackerBatcher batcher;

    setUp(() {
      batcher = TrackerBatcher();
    });

    test('encodes per-agent tasks in <agent_task> XML with id+name', () {
      final group = TrackerBatchGroup(
        key: 'openai|gpt-4',
        resolved: _stubResolved(),
        agents: [
          StudioAgent(id: 'a1', name: 'Continuity'),
          StudioAgent(id: 'a2', name: 'Director'),
        ],
        batchMaxTokens: 8000,
        batchTemperature: 0.3,
        batchContextSize: 5,
      );
      final prompt = batcher.buildBatchSystemPrompt(
        group: group,
        sharedMessages: [
          {'role': 'system', 'content': 'You are an RP assistant.'},
          {'role': 'user', 'content': 'Hello there.'},
        ],
        perAgentTaskText: {
          'a1': 'Continuity task body',
          'a2': 'Director task body',
        },
        roleText: 'Global rules: stay in character.',
      );

      expect(prompt, contains('<role>'));
      expect(prompt, contains('Global rules: stay in character.'));
      expect(prompt, contains('</role>'));
      expect(prompt, contains('<lore>'));
      expect(prompt, contains('[system]'));
      expect(prompt, contains('You are an RP assistant.'));
      expect(prompt, contains('[user]'));
      expect(prompt, contains('Hello there.'));
      expect(prompt, contains('</lore>'));
      expect(prompt, contains('<agents>'));
      expect(prompt, contains('<agent_task id="a1" name="Continuity">'));
      expect(prompt, contains('Continuity task body'));
      expect(prompt, contains('</agent_task>'));
      expect(prompt, contains('<agent_task id="a2" name="Director">'));
      expect(prompt, contains('Director task body'));
      // Required output format: every agent's <result agent="id"> template
      expect(prompt, contains('REQUIRED OUTPUT FORMAT'));
      expect(prompt, contains('<result agent="a1">'));
      expect(prompt, contains('<result agent="a2">'));
      expect(prompt, contains('CRITICAL:'));
    });

    test('escapes XML special chars in task body and attributes', () {
      final group = TrackerBatchGroup(
        key: 'openai|gpt-4',
        resolved: _stubResolved(),
        agents: [
          StudioAgent(id: 'a<b>', name: 'Name & Co'),
        ],
        batchMaxTokens: 1000,
        batchTemperature: 0.3,
        batchContextSize: 5,
      );
      final prompt = batcher.buildBatchSystemPrompt(
        group: group,
        sharedMessages: const [],
        perAgentTaskText: {'a<b>': 'Use <foo> & bar > baz'},
        roleText: '',
      );

      // Attribute values are escaped with &quot;/&apos; too.
      expect(prompt, contains('id="a&lt;b&gt;"'));
      expect(prompt, contains('name="Name &amp; Co"'));
      // Body: <, >, & are escaped.
      expect(prompt, contains('Use &lt;foo&gt; &amp; bar &gt; baz'));
      // Raw <foo> must NOT appear unescaped.
      expect(prompt, isNot(contains('<foo>')));
    });

    test('Phase 6.1 — cache-friendly order: <role> → <lore> → <agents>', () {
      // The shared stable prefix must come FIRST (cache hit window), the
      // per-agent volatile tail LAST. Otherwise the prompt cache cannot
      // find a stable prefix across turns.
      final group = TrackerBatchGroup(
        key: 'anthropic|claude',
        resolved: _stubResolved(model: 'claude-3-5-sonnet'),
        agents: [
          StudioAgent(id: 'a1', name: 'Continuity'),
        ],
        batchMaxTokens: 1000,
        batchTemperature: 0.3,
        batchContextSize: 5,
      );
      final prompt = batcher.buildBatchSystemPrompt(
        group: group,
        sharedMessages: [
          {'role': 'system', 'content': 'STABLE_CHAR_CARD'},
          {'role': 'user', 'content': 'VOLATILE_HISTORY'},
        ],
        perAgentTaskText: {'a1': 'VOLATILE_TASK'},
        roleText: 'STABLE_ROLE',
      );

      final roleIdx = prompt.indexOf('<role>');
      final loreIdx = prompt.indexOf('<lore>');
      final agentsIdx = prompt.indexOf('<agents>');
      expect(roleIdx, lessThan(loreIdx), reason: '<role> must precede <lore>');
      expect(loreIdx, lessThan(agentsIdx), reason: '<lore> must precede <agents>');
      // Output-format block comes AFTER <agents> (tail) — never inside the
      // cached prefix.
      final formatIdx = prompt.indexOf('REQUIRED OUTPUT FORMAT');
      expect(agentsIdx, lessThan(formatIdx));
      // Stable content is inside the prefix region; volatile content inside
      // the tail region.
      expect(prompt.indexOf('STABLE_ROLE'), lessThan(loreIdx));
      expect(prompt.indexOf('STABLE_CHAR_CARD'), lessThan(agentsIdx));
      expect(prompt.indexOf('VOLATILE_TASK'), greaterThan(agentsIdx));
    });
  });

  group('TrackerBatcher.parseBatchResponse', () {
    late TrackerBatcher batcher;

    setUp(() {
      batcher = TrackerBatcher();
    });

    test('extracts one <result agent="id"> block per agent in order', () {
      final group = TrackerBatchGroup(
        key: 'openai|gpt-4',
        resolved: _stubResolved(),
        agents: [
          StudioAgent(id: 'a1', name: 'Continuity'),
          StudioAgent(id: 'a2', name: 'Director'),
          StudioAgent(id: 'a3', name: 'Guard'),
        ],
        batchMaxTokens: 1000,
        batchTemperature: 0.3,
        batchContextSize: 5,
      );
      const raw = '''
<result agent="a1">
Focus: continuity
Constraints: no contradictions
</result>
<result agent="a2">
Focus: pacing
</result>
<result agent="a3">
Focus: anti-loop
</result>
''';

      final results = batcher.parseBatchResponse(raw, group);

      expect(results.length, 3);
      expect(results[0].agentId, 'a1');
      expect(results[0].status, 'ok');
      expect(results[0].text, contains('Focus: continuity'));
      expect(results[1].agentId, 'a2');
      expect(results[1].text, contains('Focus: pacing'));
      expect(results[2].agentId, 'a3');
      expect(results[2].text, contains('Focus: anti-loop'));
    });

    test('tolerates missing closing tag — takes up to next <result', () {
      final group = TrackerBatchGroup(
        key: 'openai|gpt-4',
        resolved: _stubResolved(),
        agents: [
          StudioAgent(id: 'a1', name: 'A'),
          StudioAgent(id: 'a2', name: 'B'),
        ],
        batchMaxTokens: 1000,
        batchTemperature: 0.3,
        batchContextSize: 5,
      );
      // a1 has NO closing tag — parser should take up to <result agent="a2">.
      const raw =
          '<result agent="a1">first output\n<result agent="a2">second</result>';

      final results = batcher.parseBatchResponse(raw, group);

      expect(results[0].agentId, 'a1');
      // a1 body is trimmed before return — `first output\n` → `first output`.
      // The next `<result` opening acted as the implicit boundary since a1
      // had no closing tag.
      expect(results[0].text, 'first output');
      expect(results[1].agentId, 'a2');
      expect(results[1].text, 'second');
    });

    test('falls back to legacy <result_ID>...</result_ID> format', () {
      final group = TrackerBatchGroup(
        key: 'openai|gpt-4',
        resolved: _stubResolved(),
        agents: [
          StudioAgent(id: 'a1', name: 'A'),
        ],
        batchMaxTokens: 1000,
        batchTemperature: 0.3,
        batchContextSize: 5,
      );
      const raw = '<result_a1>legacy body</result_a1>';

      final results = batcher.parseBatchResponse(raw, group);

      expect(results.length, 1);
      expect(results[0].agentId, 'a1');
      expect(results[0].text, 'legacy body');
      expect(results[0].status, 'ok');
    });

    test('marks agent as failed when no block is found', () {
      final group = TrackerBatchGroup(
        key: 'openai|gpt-4',
        resolved: _stubResolved(),
        agents: [
          StudioAgent(id: 'a1', name: 'A'),
          StudioAgent(id: 'a2', name: 'B'),
        ],
        batchMaxTokens: 1000,
        batchTemperature: 0.3,
        batchContextSize: 5,
      );
      // Only a1 present; a2 missing.
      const raw = '<result agent="a1">present</result>';

      final results = batcher.parseBatchResponse(raw, group);

      expect(results[0].agentId, 'a1');
      expect(results[0].status, 'ok');
      expect(results[1].agentId, 'a2');
      expect(results[1].status, 'failed');
      expect(results[1].error, 'no <result> block in batch response');
    });
  });

  group('TrackerBatcher.shouldRunIndividually', () {
    late TrackerBatcher batcher;
    setUp(() {
      batcher = TrackerBatcher();
    });

    test('returns true when agent.runIndividually is set', () {
      final agent = StudioAgent(
        id: 'x',
        name: 'Custom',
        runIndividually: true,
      );
      expect(batcher.shouldRunIndividually(agent), isTrue);
    });

    test('returns true when name matches expression/illustrator/lorebook', () {
      expect(
        batcher.shouldRunIndividually(
          StudioAgent(id: 'x', name: 'Expression Tracker'),
        ),
        isTrue,
      );
      expect(
        batcher.shouldRunIndividually(
          StudioAgent(id: 'x', name: 'Illustrator'),
        ),
        isTrue,
      );
      expect(
        batcher.shouldRunIndividually(
          StudioAgent(id: 'x', name: 'Lorebook Keeper'),
        ),
        isTrue,
      );
    });

    test('returns false for normal tracker names', () {
      expect(
        batcher.shouldRunIndividually(
          StudioAgent(id: 'x', name: 'Continuity'),
        ),
        isFalse,
      );
      expect(
        batcher.shouldRunIndividually(
          StudioAgent(id: 'x', name: 'Director'),
        ),
        isFalse,
      );
    });
  });

  group('TrackerBatcher.normalizeMaxParallelJobs + splitGroupForParallelJobs', () {
    late TrackerBatcher batcher;
    setUp(() {
      batcher = TrackerBatcher();
    });

    test('clamps maxParallelJobs to [1, 16]', () {
      expect(batcher.normalizeMaxParallelJobs(-1), 1);
      expect(batcher.normalizeMaxParallelJobs(0), 1);
      expect(batcher.normalizeMaxParallelJobs(1), 1);
      expect(batcher.normalizeMaxParallelJobs(8), 8);
      expect(batcher.normalizeMaxParallelJobs(16), 16);
      expect(batcher.normalizeMaxParallelJobs(100), 16);
    });

    test('returns group unchanged when maxParallelJobs=1 (MVP)', () {
      final group = TrackerBatchGroup(
        key: 'openai|gpt-4',
        resolved: _stubResolved(),
        agents: [
          StudioAgent(id: 'a1', name: 'A', maxParallelJobs: 1),
          StudioAgent(id: 'a2', name: 'B', maxParallelJobs: 1),
        ],
        batchMaxTokens: 1000,
        batchTemperature: 0.3,
        batchContextSize: 5,
      );
      final split = batcher.splitGroupForParallelJobs(group);
      expect(split.length, 1);
      expect(split.first, same(group));
    });

    test('splits into N sub-groups when maxParallelJobs>1', () {
      final group = TrackerBatchGroup(
        key: 'openai|gpt-4',
        resolved: _stubResolved(),
        agents: [
          StudioAgent(id: 'a1', name: 'A', maxParallelJobs: 2),
          StudioAgent(id: 'a2', name: 'B', maxParallelJobs: 2),
          StudioAgent(id: 'a3', name: 'C', maxParallelJobs: 2),
          StudioAgent(id: 'a4', name: 'D', maxParallelJobs: 2),
        ],
        batchMaxTokens: 8000,
        batchTemperature: 0.3,
        batchContextSize: 5,
      );
      final split = batcher.splitGroupForParallelJobs(group);
      expect(split.length, 2);
      expect(split[0].agents.length, 2);
      expect(split[1].agents.length, 2);
      // Sub-group keys are distinct.
      expect(split[0].key, isNot(split[1].key));
    });
  });
}

ResolvedAgentConfig _stubResolved({String model = 'gpt-4'}) {
  return ResolvedAgentConfig(
    endpoint: 'https://test',
    apiKey: 'k',
    model: model,
    protocol: 'openai',
    stream: false,
  );
}

/// Pure prompt-building / parsing tests construct the batcher WITHOUT a
/// runner — `TrackerBatcher()` is a no-arg constructor. Only `groupAgents` /
/// `runPhase` require a runner; we don't touch them here.

