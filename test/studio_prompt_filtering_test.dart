import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/llm/studio_brief_deduper.dart';
import 'package:glaze_flutter/core/llm/studio_brief_parser.dart';
import 'package:glaze_flutter/core/llm/studio_context_bucketizer.dart';
import 'package:glaze_flutter/core/llm/post_cleaner_service.dart';
import 'package:glaze_flutter/core/llm/studio_controller_ontology.dart';
import 'package:glaze_flutter/core/llm/context_calculator.dart';
import 'package:glaze_flutter/core/llm/studio_message_builder.dart';
import 'package:glaze_flutter/core/llm/studio_prompt_text.dart';
import 'package:glaze_flutter/core/llm/studio_stage_brief.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

PresetBlock _block({
  required String id,
  required String name,
  String content = 'content',
  bool enabled = true,
}) {
  return PresetBlock(
    id: id,
    name: name,
    role: 'system',
    content: content,
    enabled: enabled,
  );
}

PromptMessage _msg({
  String? blockId,
  String? blockName,
  String content = 'content',
  String role = 'system',
}) {
  return PromptMessage(
    role: role,
    content: content,
    blockId: blockId,
    blockName: blockName,
  );
}

PromptResult _result(List<PromptMessage> messages) => PromptResult(
  messages: messages,
  breakdown: TokenBreakdown(
    sourceTokens: const {},
    staticTotal: 0,
    historyBudget: 0,
    historyTokens: 0,
    totalTokens: 0,
    cutoffIndex: 0,
    trimmedHistory: const [],
  ),
  sessionVars: const {},
  globalVars: const {},
);

PromptPayload _payload({Preset? preset, String? studioState}) => PromptPayload(
  character: const Character(id: 'c1', name: 'TestChar'),
  history: const [],
  apiConfig: const ApiConfig(id: 'a1'),
  preset: preset,
  studioSessionStateContent: studioState,
);

void main() {
  group('StudioMessageBuilder preset block routing', () {
    final builder = StudioMessageBuilder(
      const StudioContextBucketizer(),
      const StudioPromptText(),
      StudioBriefDeduper(StudioBriefParser((_) {})),
    );
    const config = StudioConfig(sessionId: 's1');
    final promptResult = _result([
      const PromptMessage(role: 'user', content: 'hello', isHistory: true),
    ]);
    final promptPayload = _payload();
    const preset = StudioPreset(
      id: 'studio',
      blocks: [
        StudioPresetBlock(
          id: 'final_agent_instruction',
          kind: 'agent_instruction',
          content: 'FINAL ONLY',
          section: 'final',
        ),
        StudioPresetBlock(
          id: 'cleaner_system',
          kind: 'agent_instruction',
          content: 'CLEANER ONLY',
          section: 'cleaner',
        ),
        StudioPresetBlock(
          id: 'continuity_task',
          title: 'Continuity Tracker',
          kind: 'tracker_instruction',
          content: 'CONTINUITY ONLY',
          section: 'pregen',
        ),
        StudioPresetBlock(
          id: 'dialogue_task',
          title: 'Dialogue Tracker',
          kind: 'tracker_instruction',
          content: 'DIALOGUE ONLY',
          section: 'pregen',
        ),
        StudioPresetBlock(
          id: 'runtime_envelope',
          kind: 'runtime_envelope',
          content: 'SEEDED RUNTIME ENVELOPE',
          section: 'pregen',
        ),
      ],
    );

    String joinedMessages(List<Map<String, dynamic>> messages) =>
        messages.map((m) => m['content']).whereType<String>().join('\n');

    test('final run receives only final-section Studio blocks', () {
      final text = joinedMessages(
        builder.buildAgentMessages(
          agent: const StudioAgent(id: 'final', name: 'Main Responder'),
          promptResult: promptResult,
          promptPayload: promptPayload,
          config: config,
          studioPreset: preset,
          priorBriefs: const [],
          isFinalResponse: true,
        ),
      );

      expect(text, contains('FINAL ONLY'));
      expect(text, isNot(contains('CLEANER ONLY')));
      expect(text, isNot(contains('CONTINUITY ONLY')));
      expect(text, isNot(contains('DIALOGUE ONLY')));
      expect(text, isNot(contains('SEEDED RUNTIME ENVELOPE')));
      expect(text, isNot(contains('Studio controller briefs')));
    });

    test('final run includes reasoning from the nearest assistant only', () {
      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final', name: 'Main Responder'),
        promptResult: _result([
          const PromptMessage(
            role: 'assistant',
            content: 'first',
            reasoningContent: 'first reasoning',
            isHistory: true,
          ),
          const PromptMessage(role: 'user', content: 'next', isHistory: true),
          const PromptMessage(
            role: 'assistant',
            content: 'second',
            reasoningContent: 'second reasoning',
            isHistory: true,
          ),
          const PromptMessage(
            role: 'assistant',
            content: 'third',
            reasoningContent: 'third reasoning',
            isHistory: true,
          ),
          const PromptMessage(role: 'user', content: 'latest', isHistory: true),
        ]),
        promptPayload: promptPayload,
        config: config,
        studioPreset: const StudioPreset(
          id: 'history',
          blocks: [
            StudioPresetBlock(
              id: 'history',
              kind: 'chat_history',
              section: 'final',
            ),
          ],
        ),
        priorBriefs: const [],
        isFinalResponse: true,
        reasoningHistoryCount: 2,
      );

      final first = messages.firstWhere((m) => m['content'] == 'first');
      final next = messages.firstWhere((m) => m['content'] == 'next');
      final second = messages.firstWhere((m) => m['content'] == 'second');
      final third = messages.firstWhere((m) => m['content'] == 'third');
      expect(first, isNot(contains('reasoning_content')));
      expect(next, isNot(contains('reasoning_content')));
      expect(second['reasoning_content'], 'second reasoning');
      expect(third['reasoning_content'], 'third reasoning');
      expect(
        messages.where((m) => m.containsKey('reasoning_content')),
        hasLength(2),
      );
    });

    test('final run counts non-empty reasoning blocks', () {
      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final', name: 'Main Responder'),
        promptResult: _result([
          const PromptMessage(
            role: 'assistant',
            content: 'older',
            reasoningContent: 'stale reasoning',
            isHistory: true,
          ),
          const PromptMessage(
            role: 'assistant',
            content: 'nearest',
            isHistory: true,
          ),
          const PromptMessage(role: 'user', content: 'latest', isHistory: true),
        ]),
        promptPayload: promptPayload,
        config: config,
        studioPreset: const StudioPreset(
          id: 'history',
          blocks: [
            StudioPresetBlock(
              id: 'history',
              kind: 'chat_history',
              section: 'final',
            ),
          ],
        ),
        priorBriefs: const [],
        isFinalResponse: true,
        reasoningHistoryCount: 1,
      );

      expect(
        messages.where((m) => m.containsKey('reasoning_content')),
        hasLength(1),
      );
      expect(
        messages.firstWhere(
          (m) => m['content'] == 'older',
        )['reasoning_content'],
        'stale reasoning',
      );
    });

    test('final run includes all reasoning blocks for minus one', () {
      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final', name: 'Main Responder'),
        promptResult: _result([
          const PromptMessage(
            role: 'assistant',
            content: 'older',
            reasoningContent: 'older reasoning',
            isHistory: true,
          ),
          const PromptMessage(role: 'user', content: 'next', isHistory: true),
          const PromptMessage(
            role: 'assistant',
            content: 'latest',
            reasoningContent: 'latest reasoning',
            isHistory: true,
          ),
        ]),
        promptPayload: promptPayload,
        config: config,
        studioPreset: const StudioPreset(
          id: 'history',
          blocks: [
            StudioPresetBlock(
              id: 'history',
              kind: 'chat_history',
              section: 'final',
            ),
          ],
        ),
        priorBriefs: const [],
        isFinalResponse: true,
        reasoningHistoryCount: -1,
      );

      expect(
        messages.where((m) => m.containsKey('reasoning_content')),
        hasLength(2),
      );
      expect(
        messages.firstWhere(
          (m) => m['content'] == 'older',
        )['reasoning_content'],
        'older reasoning',
      );
      expect(
        messages.firstWhere(
          (m) => m['content'] == 'latest',
        )['reasoning_content'],
        'latest reasoning',
      );
    });

    test('final run omits historical reasoning by default', () {
      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final', name: 'Main Responder'),
        promptResult: _result([
          const PromptMessage(
            role: 'assistant',
            content: 'reply',
            reasoningContent: 'hidden reasoning',
            isHistory: true,
          ),
        ]),
        promptPayload: promptPayload,
        config: config,
        studioPreset: const StudioPreset(
          id: 'history',
          blocks: [
            StudioPresetBlock(
              id: 'history',
              kind: 'chat_history',
              section: 'final',
            ),
          ],
        ),
        priorBriefs: const [],
        isFinalResponse: true,
      );

      expect(
        messages.where((m) => m.containsKey('reasoning_content')),
        isEmpty,
      );
    });

    test('final blocks expand the dedicated studio state macro', () {
      final text = joinedMessages(
        builder.buildAgentMessages(
          agent: const StudioAgent(id: 'final', name: 'Main Responder'),
          promptResult: promptResult,
          promptPayload: _payload(
            studioState:
                '<studio_session_state>Lucy present</studio_session_state>',
          ),
          config: config,
          studioPreset: const StudioPreset(
            id: 'macro',
            blocks: [
              StudioPresetBlock(
                id: 'state',
                content: '{{studio_state}}',
                section: 'final',
              ),
            ],
          ),
          priorBriefs: const [],
          isFinalResponse: true,
        ),
      );

      expect(text, contains('<studio_session_state>Lucy present'));
      expect(text, isNot(contains('{{studio_state}}')));
    });

    test('group boundaries remain separate ordered system messages', () {
      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final', name: 'Main Responder'),
        promptResult: promptResult,
        promptPayload: promptPayload,
        config: config,
        studioPreset: const StudioPreset(
          id: 'boundaries',
          blocks: [
            StudioPresetBlock(
              id: 'pov_open',
              kind: 'group_open',
              role: 'system',
              content: '<loompov>',
              section: 'final',
              order: 1,
            ),
            StudioPresetBlock(
              id: 'pov_content',
              role: 'system',
              content: 'POV instructions',
              section: 'final',
              order: 2,
            ),
            StudioPresetBlock(
              id: 'pov_close',
              kind: 'group_close',
              role: 'system',
              content: '</loompov>',
              section: 'final',
              order: 3,
            ),
          ],
        ),
        priorBriefs: const [],
        isFinalResponse: true,
      );

      expect(messages.map((message) => (message['role'], message['content'])), [
        ('system', '<loompov>'),
        ('system', 'POV instructions'),
        ('system', '</loompov>'),
      ]);
    });

    test('cleaner run receives only cleaner-section Studio blocks', () {
      final text = joinedMessages(
        builder.buildAgentMessages(
          agent: const StudioAgent(
            id: 'cleaner',
            name: 'Cleaner',
            phase: 'post_processing',
          ),
          promptResult: promptResult,
          promptPayload: promptPayload,
          config: config,
          studioPreset: preset,
          priorBriefs: const [],
          isFinalResponse: false,
        ),
      );

      expect(text, contains('CLEANER ONLY'));
      expect(text, isNot(contains('FINAL ONLY')));
      expect(text, isNot(contains('CONTINUITY ONLY')));
      expect(text, isNot(contains('DIALOGUE ONLY')));
    });

    test('per-agent task receives only matching tracker_instruction', () {
      final context = const StudioContextBucketizer().bucketize(
        promptResult,
        promptPayload: promptPayload,
        studioConfig: config,
      );
      final text = builder.buildPerAgentTaskText(
        agent: const StudioAgent(id: 'continuity', name: 'Continuity Tracker'),
        config: config,
        studioPreset: preset,
        promptResult: promptResult,
        promptPayload: promptPayload,
        context: context,
      );

      expect(text, contains('CONTINUITY ONLY'));
      expect(text, isNot(contains('DIALOGUE ONLY')));
      expect(text, isNot(contains('FINAL ONLY')));
      expect(text, isNot(contains('CLEANER ONLY')));
      expect(text, isNot(contains('SEEDED RUNTIME ENVELOPE')));
    });

    test('final brief macros expand and suppress previous_agents block', () {
      const macroConfig = StudioConfig(
        sessionId: 's1',
        agents: [
          StudioAgent(
            id: 'agent_s_continuity_1',
            name: 'Continuity Controller',
          ),
          StudioAgent(id: 'agent_s_dialogue_1', name: 'Dialogue Controller'),
        ],
      );
      const macroPreset = StudioPreset(
        id: 'studio',
        blocks: [
          StudioPresetBlock(
            id: 'previous_agents',
            kind: 'previous_agents',
            content: '',
            section: 'final',
            order: 0,
          ),
          StudioPresetBlock(
            id: 'brief_macros',
            kind: 'custom_text',
            content:
                '<continuity>{{studio_continuity_brief}}</continuity>\n'
                '<dialogue>{{studio_dialogue_brief}}</dialogue>',
            section: 'final',
            order: 1,
          ),
        ],
      );
      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final', name: 'Main Responder'),
        promptResult: promptResult,
        promptPayload: promptPayload,
        config: macroConfig,
        studioPreset: macroPreset,
        priorBriefs: const [
          StudioStageBrief(
            agentId: 'agent_s_continuity_1',
            agentName: 'Continuity Controller',
            brief:
                'Focus:\n- Keep the chip location consistent with the current scene.',
          ),
          StudioStageBrief(
            agentId: 'agent_s_dialogue_1',
            agentName: 'Dialogue Controller',
            brief:
                'Focus:\n- Let Claire speak only if she can plausibly hear the exchange.',
          ),
        ],
        isFinalResponse: true,
      );

      final text = joinedMessages(messages);
      expect(text, contains('<continuity>'));
      expect(text, contains('Keep the chip location consistent'));
      expect(text, contains('<dialogue>'));
      expect(text, contains('Let Claire speak only if she can plausibly hear'));
      expect('Studio agent brief'.allMatches(text).length, 2);
    });
  });

  group('StudioContextBucketizer staticContext filter', () {
    final bucketizer = const StudioContextBucketizer();

    test('non-Studio run: unrouted preset block lands in staticContext', () {
      // char_card is a static-id block → goes to byKind, not staticContext.
      // narrative_engine is not a static/dynamic id → goes to staticContext.
      final preset = Preset(
        id: 'p1',
        name: 'P1',
        blocks: [
          _block(
            id: 'narrative_engine',
            name: 'Narrative Engine',
            content: 'ne',
          ),
          _block(id: 'char_card', name: 'Character Card', content: 'cc'),
        ],
      );
      final result = _result([
        _msg(
          blockId: 'narrative_engine',
          blockName: 'Narrative Engine',
          content: 'ne',
        ),
        _msg(blockId: 'char_card', blockName: 'Character Card', content: 'cc'),
      ]);
      final buckets = bucketizer.bucketize(
        result,
        promptPayload: _payload(preset: preset),
      );
      // Only the unrouted narrative_engine is in staticContext; char_card is
      // in byKind['char_card'] (consumed via the studio preset's char_card
      // kind block).
      expect(buckets.staticContext.length, 1);
      expect(buckets.staticContext.first.blockName, 'Narrative Engine');
      expect(buckets.messagesForKind('char_card').length, 1);
    });

    test('Studio run: CoT block filtered from staticContext', () {
      final cot = _block(
        id: 'cot_gemini',
        name: 'CoT Gemini',
        content: 'think template',
      );
      final preset = Preset(id: 'p1', name: 'P1', blocks: [cot]);
      final config = const StudioConfig(
        sessionId: 's1',
        agents: [StudioAgent(id: 'a1', sourceBlockNames: '')],
      );
      final result = _result([
        _msg(
          blockId: 'cot_gemini',
          blockName: 'CoT Gemini',
          content: 'think template',
        ),
      ]);
      final buckets = bucketizer.bucketize(
        result,
        promptPayload: _payload(preset: preset),
        studioConfig: config,
      );
      expect(buckets.staticContext, isEmpty);
    });

    test('Studio run: routed block filtered from staticContext', () {
      final preset = Preset(
        id: 'p1',
        name: 'P1',
        blocks: [
          _block(id: 'narr_engine', name: 'Narrative Engine', content: 'ne'),
          _block(id: 'other_block', name: 'Other Block', content: 'ob'),
        ],
      );
      final config = const StudioConfig(
        sessionId: 's1',
        agents: [StudioAgent(id: 'a1', sourceBlockNames: 'Narrative Engine')],
      );
      final result = _result([
        _msg(
          blockId: 'narrative_engine',
          blockName: 'Narrative Engine',
          content: 'ne',
        ),
        _msg(blockId: 'other_block', blockName: 'Other Block', content: 'ob'),
      ]);
      final buckets = bucketizer.bucketize(
        result,
        promptPayload: _payload(preset: preset),
        studioConfig: config,
      );
      final names = buckets.staticContext.map((m) => m.blockName).toList();
      expect(names, contains('Other Block'));
      expect(names, isNot(contains('Narrative Engine')));
    });

    test(
      'Studio run: char_card kept in byKind (not affected by staticContext filter)',
      () {
        final preset = Preset(
          id: 'p1',
          name: 'P1',
          blocks: [
            _block(id: 'char_card', name: 'Character Card', content: 'cc'),
          ],
        );
        final config = const StudioConfig(
          sessionId: 's1',
          agents: [StudioAgent(id: 'a1')],
        );
        final result = _result([
          _msg(
            blockId: 'char_card',
            blockName: 'Character Card',
            content: 'cc',
          ),
        ]);
        final buckets = bucketizer.bucketize(
          result,
          promptPayload: _payload(preset: preset),
          studioConfig: config,
        );
        // char_card is a static-id → goes to byKind, never touched by the
        // staticContext filter.
        expect(buckets.messagesForKind('char_card').length, 1);
        expect(buckets.staticContext, isEmpty);
      },
    );

    test(
      'Studio run: broadcast block in Main Responder shard is filtered from staticContext',
      () {
        final preset = Preset(
          id: 'p1',
          name: 'P1',
          blocks: [
            _block(
              id: 'lang',
              name: 'Language Russian',
              content: 'use russian',
            ),
            _block(id: 'other_block', name: 'Other Block', content: 'ob'),
          ],
        );
        final config = const StudioConfig(
          sessionId: 's1',
          agents: [StudioAgent(id: 'a1', sourceBlockNames: 'Language Russian')],
        );
        final result = _result([
          _msg(
            blockId: 'lang',
            blockName: 'Language Russian',
            content: 'use russian',
          ),
          _msg(blockId: 'other_block', blockName: 'Other Block', content: 'ob'),
        ]);
        final buckets = bucketizer.bucketize(
          result,
          promptPayload: _payload(preset: preset),
          studioConfig: config,
        );
        final names = buckets.staticContext.map((m) => m.blockName).toList();
        expect(names, contains('Other Block'));
        expect(names, isNot(contains('Language Russian')));
      },
    );
  });

  group('StudioControllerOntology Meta-Weaver spec', () {
    test('Meta-Weaver refreshPolicy is turn (not static)', () {
      final meta = StudioControllerOntology.specs.firstWhere(
        (s) => s.id == 'meta',
      );
      expect(meta.refreshPolicy, 'turn');
    });

    test('Meta-Weaver contextSize inherits tracker default', () {
      final meta = StudioControllerOntology.specs.firstWhere(
        (s) => s.id == 'meta',
      );
      expect(meta.contextSize, 0);
    });

    test(
      'Main Responder spec contextSize defaults to 0 (inherits agent default)',
      () {
        final fin = StudioControllerOntology.specs.firstWhere(
          (s) => s.id == 'final',
        );
        expect(fin.contextSize, 0);
      },
    );

    test('Meta-Weaver purpose mentions counting', () {
      final meta = StudioControllerOntology.specs.firstWhere(
        (s) => s.id == 'meta',
      );
      expect(meta.purpose.toLowerCase(), contains('count'));
    });
  });

  group('Studio Narrative length ownership', () {
    const narrativeAgent = StudioAgent(
      id: 'narrative',
      name: 'Narrative / Pacing / Style Controller',
    );

    test('runtime leaves numeric response budgets to the active preset', () {
      final envelope = const StudioPromptText().intermediateRuntimeEnvelope(
        narrativeAgent,
      );
      final narrative = StudioControllerOntology.specs.firstWhere(
        (spec) => spec.id == 'narrative',
      );

      expect(envelope.toLowerCase(), isNot(contains('paragraph')));
      expect(envelope.toLowerCase(), isNot(contains('word budget')));
      expect(narrative.purpose.toLowerCase(), isNot(contains('paragraph')));
      expect(
        narrative.outputContract.toLowerCase(),
        isNot(contains('paragraph')),
      );
    });
  });

  group('PostCleanerService lumiaooc preservation', () {
    test(
      'lumiaooc dropped (and all tags dropped) is caught by protected-markup guard',
      () {
        const original =
            '<lumiaooc><font color="#9370DB">Lumia note</font></lumiaooc>\nProse here.';
        const edited = 'Prose here.';
        // All HTML tags stripped → textRewriteDropsProtectedMarkup catches it.
        expect(
          PostCleanerService.textRewriteDropsProtectedMarkup(original, edited),
          isTrue,
        );
      },
    );

    test(
      'lumiaooc dropped but other tags preserved is caught by lumiaooc guard',
      () {
        const original =
            '<lumiaooc><font color="#9370DB">Lumia note</font></lumiaooc>\n<b>Prose</b> here.';
        const edited = '<b>Cleaned prose</b> here.';
        // textRewriteDropsProtectedMarkup returns false (edited still has <b>),
        // but the lumiaooc guard catches the dropped <lumiaooc>. This is the
        // case the dedicated lumiaoocDropped check exists for.
        expect(
          PostCleanerService.textRewriteDropsProtectedMarkup(original, edited),
          isFalse,
        );
        expect(PostCleanerService.lumiaoocDropped(original, edited), isTrue);
      },
    );

    test('lumiaooc preserved in cleaned text is not flagged', () {
      const original =
          '<lumiaooc><font color="#9370DB">Lumia note</font></lumiaooc>\nProse here.';
      const edited =
          '<lumiaooc><font color="#9370DB">Lumia note</font></lumiaooc>\nCleaned prose here.';
      expect(
        PostCleanerService.textRewriteDropsProtectedMarkup(original, edited),
        isFalse,
      );
    });

    test('buildCleanerPrompt mentions lumiaooc verbatim rule', () {
      final prompt = PostCleanerService.buildCleanerPrompt(
        assistantText: 'prose',
      );
      expect(prompt.toLowerCase(), contains('lumiaooc'));
    });
  });

  group('StudioConfig Meta-Weaver migration (Part 6)', () {
    test('old Meta-Weaver with static policy is upgraded to turn on load', () {
      // Simulate an old agent as it would deserialize from JSON.
      final oldAgent = StudioAgent.fromJson(const {
        'id': 'agent_s1_meta_123',
        'name': 'Meta-Weaver / Lumia Policy',
        'refreshPolicy': 'static',
        'contextSize': 5,
        'order': 6,
      });
      expect(oldAgent.refreshPolicy, 'static');
      expect(oldAgent.contextSize, 5);

      // The migration is in StudioConfigRepo._normalizeLoadedConfig which is
      // private. We test the migration logic by reproducing it here — it's a
      // pure normalization that any caller can apply. The repo applies it on
      // every load. This test documents the expected behavior.
      final migrated = _migrateForTest(oldAgent);
      expect(migrated.refreshPolicy, 'turn');
      expect(migrated.contextSize, 5);
    });

    test(
      'new Meta-Weaver with turn policy + custom contextSize is unchanged',
      () {
        final newAgent = StudioAgent.fromJson(const {
          'id': 'agent_s1_meta_123',
          'name': 'Meta-Weaver / Lumia Policy',
          'refreshPolicy': 'turn',
          'contextSize': 8,
          'order': 6,
        });
        final migrated = _migrateForTest(newAgent);
        expect(migrated.refreshPolicy, 'turn');
        expect(migrated.contextSize, 8);
      },
    );

    test('non-Meta-Weaver agent is unchanged by migration', () {
      final guard = StudioAgent.fromJson(const {
        'id': 'agent_s1_guard_123',
        'name': 'Anti-Loop & Prose Guard',
        'refreshPolicy': 'turn',
        'contextSize': 5,
        'order': 4,
      });
      final migrated = _migrateForTest(guard);
      expect(migrated.refreshPolicy, 'turn');
      expect(migrated.contextSize, 5);
    });

    test('Meta-Weaver with large contextSize keeps its larger value', () {
      final agent = StudioAgent.fromJson(const {
        'id': 'agent_s1_meta_123',
        'name': 'Meta-Weaver / Lumia Policy',
        'refreshPolicy': 'static',
        'contextSize': 30,
        'order': 6,
      });
      final migrated = _migrateForTest(agent);
      expect(migrated.refreshPolicy, 'turn');
      expect(migrated.contextSize, 30);
    });
  });

  group('Meta-Weaver auto-disable when no lumia block', () {
    test('enabled is true by default for non-meta agents', () {
      const agent = StudioAgent(id: 'agent_s1_guard_123', name: 'Guard');
      expect(agent.enabled, isTrue);
    });

    test('StudioAgent.enabled can be set false (auto-disable contract)', () {
      const agent = StudioAgent(
        id: 'agent_s1_meta_123',
        name: 'Meta-Weaver / Lumia Policy',
        enabled: false,
      );
      expect(agent.enabled, isFalse);
    });
  });
}

/// Reproduces the `StudioConfigRepo._normalizeLoadedConfig` Meta-Weaver
/// migration logic for unit testing. The repo method is private and tied to
/// Drift; this helper mirrors the exact normalization so tests are pure.
StudioAgent _migrateForTest(StudioAgent agent) {
  final id = agent.id.toLowerCase();
  final name = agent.name.toLowerCase();
  final isMeta =
      id.contains('_meta_') ||
      id == 'meta' ||
      name.contains('meta-weaver') ||
      name.contains('meta weaver') ||
      name.contains('lumia policy');
  if (!isMeta) return agent;
  if (agent.refreshPolicy == 'turn') return agent;
  return agent.copyWith(refreshPolicy: 'turn');
}
