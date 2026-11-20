import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/agents/agent_prompt_builder.dart';
import 'package:glaze_flutter/core/llm/agents/agent_turn_plan.dart';
import 'package:glaze_flutter/core/llm/agents/agent_templates.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/prompt/runtime_prompt_block.dart';
import 'package:glaze_flutter/core/models/agent_binding.dart';
import 'package:glaze_flutter/core/models/agent_definition.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/chat/services/agents/agent_turn_service.dart';

AgentDefinition _agent(
  String id, {
  String phase = AgentPhase.preGeneration,
  String? resultType,
  bool global = false,
  int everyN = 1,
  List<String> keywords = const [],
  List<String> dependsOn = const [],
  List<String> sees = const [],
}) => AgentDefinition(
  id: id,
  name: id,
  phase: phase,
  resultType: resultType ?? AgentResultType.allowedFor(phase).first,
  enabledGlobally: global,
  cadence: AgentCadence(everyN: everyN, keywords: keywords),
  dependsOn: dependsOn,
  seesOutputsOf: sees,
);

ChatMessage _msg(String id, String role, String text) =>
    ChatMessage(id: id, role: role, content: text);

void main() {
  group('binding resolution', () {
    final agent = _agent('a', global: true);

    test('global flag applies without bindings', () {
      final state = resolveAgentState(
        agent,
        const [],
        charId: 'c',
        sessionId: 's',
      );
      expect(state.enabled, isTrue);
      expect(state.source, AgentStateSource.global);
    });

    test('character overrides global, chat overrides character', () {
      const character = AgentBinding(
        agentId: 'a',
        scope: AgentBindingScope.character,
        targetId: 'c',
        enabled: false,
      );
      const chat = AgentBinding(
        agentId: 'a',
        scope: AgentBindingScope.chat,
        targetId: 's',
        enabled: true,
      );
      expect(
        resolveAgentState(agent, [character], charId: 'c', sessionId: 's'),
        isA<AgentChatState>()
            .having((s) => s.enabled, 'enabled', false)
            .having((s) => s.source, 'source', AgentStateSource.character),
      );
      expect(
        resolveAgentState(
          agent,
          [character, chat],
          charId: 'c',
          sessionId: 's',
        ).source,
        AgentStateSource.chat,
      );
      // Another chat of the same character keeps the character's switch.
      expect(
        resolveAgentState(
          agent,
          [character, chat],
          charId: 'c',
          sessionId: 'other',
        ).enabled,
        isFalse,
      );
    });
  });

  group('turn plan', () {
    test('splits by phase and keeps only valid shapes', () {
      final plan = AgentTurnPlan.build(
        enabled: [
          _agent('pre'),
          _agent('par', phase: AgentPhase.parallel),
          _agent(
            'clean',
            phase: AgentPhase.postProcessing,
            resultType: AgentResultType.textRewrite,
          ),
          // Any agent can drive the Tracker engine.
          _agent(
            'tracker',
            phase: AgentPhase.postProcessing,
            resultType: AgentResultType.ledgerUpdate,
          ),
          // A result type the phase cannot carry.
          _agent('bad', resultType: AgentResultType.textRewrite),
        ],
        history: const [],
      );
      expect(plan.preGeneration.map((a) => a.id), ['pre']);
      expect(plan.parallel.map((a) => a.id), ['par']);
      expect(plan.postProcessing.map((a) => a.id), ['clean', 'tracker']);
      expect(plan.firstOfType(AgentResultType.ledgerUpdate)?.id, 'tracker');
    });

    test('every N-th reply counts the reply about to be written', () {
      final history = [
        _msg('u1', 'user', 'hi'),
        _msg('a1', 'assistant', 'hello'),
        _msg('u2', 'user', 'go'),
      ];
      // Reply number 2.
      expect(
        AgentTurnPlan.build(
          enabled: [_agent('even', everyN: 2)],
          history: history,
        ).preGeneration,
        hasLength(1),
      );
      expect(
        AgentTurnPlan.build(
          enabled: [_agent('third', everyN: 3)],
          history: history,
        ).preGeneration,
        isEmpty,
      );
    });

    test('keywords scan only the last messages', () {
      final history = [
        _msg('u1', 'user', 'a dragon appears'),
        _msg('a1', 'assistant', 'it roars'),
        _msg('u2', 'user', 'I run'),
      ];
      AgentTurnPlan plan(int depth) => AgentTurnPlan.build(
        enabled: [
          _agent('k', keywords: ['Dragon']).copyWith(
            cadence: AgentCadence(keywords: const ['Dragon'], scanDepth: depth),
          ),
        ],
        history: history,
      );
      expect(plan(2).preGeneration, isEmpty);
      expect(plan(3).preGeneration, hasLength(1));
    });

    test('drops agents whose dependency does not run', () {
      final plan = AgentTurnPlan.build(
        enabled: [
          _agent('needs_missing', dependsOn: ['missing']),
          _agent('chain', dependsOn: ['needs_missing']),
          _agent('ok'),
        ],
        history: const [],
      );
      expect(plan.preGeneration.map((a) => a.id), ['ok']);
    });

    test('orders readers after the agents they read', () {
      final plan = AgentTurnPlan.build(
        enabled: [
          _agent('reader', sees: ['source']),
          _agent('source'),
          _agent('loop_a', sees: ['loop_b']),
          _agent('loop_b', sees: ['loop_a']),
        ],
        history: const [],
      );
      final waves = [
        for (final wave in plan.preGenerationWaves)
          wave.map((a) => a.id).toList(),
      ];
      expect(waves.first, ['source']);
      expect(waves[1], ['reader']);
      expect(waves.last, containsAll(['loop_a', 'loop_b']));
    });
  });

  group('agent prompt', () {
    const ctx = MacroContext(
      charName: 'Alice',
      userName: 'Bob',
      charId: 'c',
      sessionId: 's',
      extBlocks: {'agent:notes': 'NOTES'},
    );
    final history = [
      _msg('u1', 'user', 'one'),
      _msg('a1', 'assistant', 'two'),
      _msg('u2', 'user', 'three'),
    ];

    test('sends the transcript last when no block asks for it', () {
      final messages = const AgentPromptBuilder().build(
        agent: _agent('a').copyWith(
          contextSize: 2,
          blocks: const [
            PresetBlock(
              id: 'b',
              name: 'b',
              role: 'system',
              content: 'Watch {{char}}. {{agent::notes}}',
            ),
          ],
        ),
        macroContext: ctx,
        history: history,
      );
      expect(messages.first, {
        'role': 'system',
        'content': 'Watch Alice. NOTES',
      });
      expect(messages.last['role'], 'user');
      expect(messages.last['content'], contains('Alice: two'));
      expect(messages.last['content'], contains('Bob: three'));
      expect(messages.last['content'], isNot(contains('one')));
    });

    test(
      'places the transcript where {{history}} is and ends on a user turn',
      () {
        final messages = const AgentPromptBuilder().build(
          agent: _agent('a').copyWith(
            blocks: const [
              PresetBlock(
                id: 'b',
                name: 'b',
                role: 'system',
                content: 'Chat:\n{{history}}',
              ),
            ],
          ),
          macroContext: ctx,
          history: history,
        );
        expect(messages.first['content'], contains('Bob: one'));
        expect(messages.last, {'role': 'user', 'content': 'Respond now.'});
      },
    );

    test('skips stashed blocks and blocks in a disabled folder', () {
      final messages = const AgentPromptBuilder().build(
        agent: _agent('a').copyWith(
          blocks: const [
            PresetBlock(id: 'k', name: 'k', role: 'system', content: 'KEEP'),
            PresetBlock(
              id: 's',
              name: 's',
              role: 'system',
              content: 'STASHED',
              isStashed: true,
            ),
            PresetBlock(
              id: 'f',
              name: 'f',
              role: 'system',
              content: 'FOLDED',
              folderId: 'off',
            ),
          ],
          blockFolders: const [
            PresetBlockFolder(id: 'off', name: 'off', enabled: false),
          ],
        ),
        macroContext: ctx,
        history: history,
      );
      final text = messages.map((m) => m['content']).join('\n');
      expect(text, contains('KEEP'));
      expect(text, isNot(contains('STASHED')));
      expect(text, isNot(contains('FOLDED')));
    });
  });

  group('injection', () {
    test('a depth result also fills {{agent::id}}', () {
      final blocks = injectionBlocksFor(
        _agent('mood').copyWith(
          name: 'Mood Tracker',
          injection: const AgentInjection(depth: 2, role: 'user'),
        ),
        ' calm ',
      );
      expect(blocks.map((b) => b.placement), [
        RuntimePromptPlacement.macro,
        RuntimePromptPlacement.depth,
      ]);
      expect(blocks.last.content, '<mood_tracker>\ncalm\n</mood_tracker>');
      expect(blocks.last.depth, 2);
      expect(blocks.last.role, 'user');
      expect(
        replaceAgentMacros('x {{agent::mood}} y', extBlocksMacroValues(blocks)),
        'x calm y',
      );
    });

    test('a macro-only result is not placed', () {
      final blocks = injectionBlocksFor(
        _agent('m').copyWith(
          injection: const AgentInjection(placement: AgentPlacement.macroOnly),
        ),
        'text',
      );
      expect(blocks.single.placement, RuntimePromptPlacement.macro);
    });

    test('an empty result adds nothing', () {
      expect(injectionBlocksFor(_agent('e'), '  '), isEmpty);
    });
  });

  group('engine config', () {
    const chat = ApiConfig(id: 'chat', name: 'Chat');
    final seeds = {for (final t in agentTemplates) t.id: t.build()};

    test('Post Clean and Tracker map onto the engines', () {
      final config = buildEngineConfig(
        rewrite: seeds['post_clean']!.copyWith(
          connection: const AgentConnection(
            mode: AgentConnectionMode.config,
            apiConfigId: 'cheap',
            model: 'm1',
          ),
        ),
        tracker: seeds['tracker'],
        cardRewriter: null,
        pipelineSettings: const PipelineSettings(),
        apiConfigs: const [chat],
        activeApiConfig: chat,
      );
      expect(config.cleanerEnabled, isTrue);
      expect(config.ledgerEnabled, isTrue);
      expect(config.cleanerApiConfigId, 'cheap');
      expect(config.pipelineSettings.cleaner.postCleanerModel, 'm1');
      // The Tracker on the chat connection names it, instead of borrowing
      // Post Clean's.
      expect(config.ledgerApiConfigId, 'chat');
      expect(config.cleanerBlocks, isNotEmpty);
      expect(config.ledgerBlocks.map((b) => b.id), contains('ledger_system'));
      expect(config.pipelineSettings.cardRewriter.enabled, isFalse);
    });

    test('Card Rewriter switches its lane on', () {
      final config = buildEngineConfig(
        rewrite: null,
        tracker: seeds['tracker'],
        cardRewriter: seeds['card_rewriter'],
        pipelineSettings: const PipelineSettings(),
        apiConfigs: const [chat],
        activeApiConfig: chat,
      );
      expect(config.cleanerEnabled, isFalse);
      expect(config.pipelineSettings.cardRewriter.enabled, isTrue);
    });

    test('the helper connection comes from the agent settings', () {
      final config = buildEngineConfig(
        rewrite: seeds['post_clean']!.copyWith(
          connection: const AgentConnection(mode: AgentConnectionMode.helper),
        ),
        tracker: null,
        cardRewriter: null,
        pipelineSettings: const PipelineSettings().copyWith(
          agents: const PipelineSettings().agents.copyWith(
            helperApiConfigId: 'helper',
            helperModel: 'small',
          ),
        ),
        apiConfigs: const [chat],
        activeApiConfig: chat,
      );
      expect(config.cleanerApiConfigId, 'helper');
      expect(config.pipelineSettings.cleaner.postCleanerModel, 'small');
    });
  });

  test('an agent survives a JSON round trip', () {
    final agent = _agent('a').copyWith(
      blocks: const [
        PresetBlock(id: 'b', name: 'n', role: 'user', content: 'c'),
      ],
      params: const AgentParams(temperature: 0.3, maxTokens: 99),
    );
    expect(AgentDefinition.fromJson(agent.toJson()), agent);
  });
}
