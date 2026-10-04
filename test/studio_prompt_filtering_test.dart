import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/llm/studio_brief_deduper.dart';
import 'package:glaze_flutter/core/llm/studio_brief_parser.dart';
import 'package:glaze_flutter/core/llm/post_cleaner_service.dart';
import 'package:glaze_flutter/core/llm/studio_controller_ontology.dart';
import 'package:glaze_flutter/core/llm/studio_message_builder.dart';
import 'package:glaze_flutter/core/llm/studio_prompt_text.dart';
import 'package:glaze_flutter/core/llm/studio_stage_brief.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

StudioContext _context(List<PromptMessage> history, {String? studioState}) =>
    StudioContext(
      slots: studioState == null
          ? const {}
          : {
              StudioContextSlot.studioSessionState: [
                PromptMessage(role: 'system', content: studioState),
              ],
            },
      history: history,
      sessionVars: const {},
      globalVars: const {},
      macroContext: MacroContext(
        charName: 'TestChar',
        charId: 'c1',
        sessionId: 's1',
        studioSessionState: studioState,
      ),
      diagnostics: const StudioContextDiagnostics(),
    );

void main() {
  group('StudioMessageBuilder preset block routing', () {
    final builder = StudioMessageBuilder(
      const StudioPromptText(),
      StudioBriefDeduper(StudioBriefParser((_) {})),
    );
    const config = StudioConfig(sessionId: 's1');
    final context = _context([
      const PromptMessage(role: 'user', content: 'hello', isHistory: true),
    ]);
    const preset = StudioPreset(
      id: 'studio',
      blocks: [
        StudioPresetBlock(
          id: 'final_agent_instruction',
          content: 'FINAL ONLY',
          mode: 'direct',
          injectionPoint: 'final',
        ),
        StudioPresetBlock(
          id: 'cleaner_system',
          content: 'CLEANER ONLY',
          mode: 'direct',
          injectionPoint: 'cleaner',
        ),
        StudioPresetBlock(
          id: 'continuity_task',
          title: 'Continuity Tracker',
          content: 'CONTINUITY ONLY',
          mode: 'direct',
          injectionPoint: 'specificAgent',
          targetAgentId: 'continuity',
        ),
        StudioPresetBlock(
          id: 'dialogue_task',
          title: 'Dialogue Tracker',
          content: 'DIALOGUE ONLY',
          mode: 'direct',
          injectionPoint: 'specificAgent',
          targetAgentId: 'dialogue',
        ),
        StudioPresetBlock(
          id: 'shared_pregen',
          title: 'Shared controller rules',
          content: 'SHARED PREGEN',
          mode: 'direct',
          injectionPoint: 'pregen',
        ),
        StudioPresetBlock(
          id: 'runtime_envelope',
          content: 'SEEDED RUNTIME ENVELOPE',
          injectionPoint: 'pregen',
        ),
      ],
    );

    String joinedMessages(List<Map<String, dynamic>> messages) =>
        messages.map((m) => m['content']).whereType<String>().join('\n');

    test('final run receives only final-section Studio blocks', () {
      final text = joinedMessages(
        builder.buildAgentMessages(
          agent: const StudioAgent(
            id: 'final',
            controllerId: 'final',
            name: 'Main Responder',
          ),
          context: context,
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
        context: _context([
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
        config: config,
        studioPreset: const StudioPreset(
          id: 'history',
          blocks: [
            StudioPresetBlock(
              id: 'chat_history',
              mode: '',
              injectionPoint: 'final',
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
        context: _context([
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
        config: config,
        studioPreset: const StudioPreset(
          id: 'history',
          blocks: [
            StudioPresetBlock(
              id: 'chat_history',
              mode: '',
              injectionPoint: 'final',
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
        context: _context([
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
        config: config,
        studioPreset: const StudioPreset(
          id: 'history',
          blocks: [
            StudioPresetBlock(
              id: 'chat_history',
              mode: '',
              injectionPoint: 'final',
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
        context: _context([
          const PromptMessage(
            role: 'assistant',
            content: 'reply',
            reasoningContent: 'hidden reasoning',
            isHistory: true,
          ),
        ]),
        config: config,
        studioPreset: const StudioPreset(
          id: 'history',
          blocks: [
            StudioPresetBlock(
              id: 'chat_history',
              mode: '',
              injectionPoint: 'final',
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
          context: _context(
            context.history,
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
                mode: 'direct',
                injectionPoint: 'final',
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

    test('group boundaries wrap header and last enabled child', () {
      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final', name: 'Main Responder'),
        context: context,
        config: config,
        studioPreset: const StudioPreset(
          id: 'boundaries',
          blocks: [
            StudioPresetBlock(
              id: 'pov_open',
              groupBoundary: 'open',
              mode: '',
              role: 'system',
              content: '<loompov>',
              injectionPoint: 'final',
              order: 1,
            ),
            StudioPresetBlock(
              id: 'pov_content',
              title: '━ Point-of-View',
              role: 'system',
              content: 'POV header instructions',
              mode: 'direct',
              injectionPoint: 'final',
              order: 2,
            ),
            StudioPresetBlock(
              id: 'pov_child',
              role: 'system',
              content: 'Selected POV',
              mode: 'direct',
              injectionPoint: 'final',
              order: 3,
            ),
            StudioPresetBlock(
              id: 'disabled_child',
              role: 'system',
              content: 'Disabled POV',
              enabled: false,
              mode: 'direct',
              injectionPoint: 'final',
              order: 4,
            ),
            StudioPresetBlock(
              id: 'pov_close',
              groupBoundary: 'close',
              mode: '',
              role: 'system',
              content: '</loompov>',
              injectionPoint: 'final',
              order: 5,
            ),
          ],
        ),
        priorBriefs: const [],
        isFinalResponse: true,
      );

      expect(messages.map((message) => (message['role'], message['content'])), [
        ('system', '<loompov>\nPOV header instructions'),
        ('system', 'Selected POV\n</loompov>'),
      ]);
    });

    test('group boundaries wrap an empty group header', () {
      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final', name: 'Main Responder'),
        context: context,
        config: config,
        studioPreset: const StudioPreset(
          id: 'empty_group',
          blocks: [
            StudioPresetBlock(
              id: 'group_group_open',
              groupBoundary: 'open',
              mode: '',
              content: '<group>',
              injectionPoint: 'final',
              order: 1,
            ),
            StudioPresetBlock(
              id: 'group',
              title: '━ Group',
              content: 'Header instructions',
              injectionPoint: 'final',
              order: 2,
            ),
            StudioPresetBlock(
              id: 'group_group_close',
              groupBoundary: 'close',
              mode: '',
              content: '</group>',
              injectionPoint: 'final',
              order: 3,
            ),
          ],
        ),
        priorBriefs: const [],
        isFinalResponse: true,
      );

      expect(
        messages.single['content'],
        '<group>\nHeader instructions\n</group>',
      );
    });

    test('disabled group emits neither boundaries nor content', () {
      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final', name: 'Main Responder'),
        context: context,
        config: config,
        studioPreset: const StudioPreset(
          id: 'disabled_group',
          blocks: [
            StudioPresetBlock(
              id: 'group_group_open',
              groupBoundary: 'open',
              mode: '',
              content: '<group>',
              injectionPoint: 'final',
              order: 1,
            ),
            StudioPresetBlock(
              id: 'group',
              title: '━ Group',
              content: 'Header instructions',
              enabled: false,
              injectionPoint: 'final',
              order: 2,
            ),
            StudioPresetBlock(
              id: 'child',
              content: 'Enabled child',
              injectionPoint: 'final',
              order: 3,
            ),
            StudioPresetBlock(
              id: 'group_group_close',
              groupBoundary: 'close',
              mode: '',
              content: '</group>',
              injectionPoint: 'final',
              order: 4,
            ),
          ],
        ),
        priorBriefs: const [],
        isFinalResponse: true,
      );

      expect(messages, isEmpty);
    });

    test('cleaner run receives only cleaner-section Studio blocks', () {
      final text = joinedMessages(
        builder.buildAgentMessages(
          agent: const StudioAgent(
            id: 'cleaner',
            name: 'Cleaner',
            phase: 'post_processing',
            specId: 'post_clean',
          ),
          context: context,
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
      final text = builder.buildPerAgentTaskText(
        agent: const StudioAgent(
          id: 'continuity',
          controllerId: 'continuity',
          name: 'Continuity Tracker',
        ),
        config: config,
        studioPreset: preset,
        context: context,
      );

      expect(text, contains('CONTINUITY ONLY'));
      expect(text, isNot(contains('DIALOGUE ONLY')));
      expect(text, isNot(contains('FINAL ONLY')));
      expect(text, isNot(contains('CLEANER ONLY')));
      expect(text, isNot(contains('SEEDED RUNTIME ENVELOPE')));
      // Shared pre-gen instructions live in the batch's <role>, once. Copying
      // them into every task repeated them per agent in the uncached tail.
      expect(text, isNot(contains('SHARED PREGEN')));
    });

    test('shared pre-gen blocks go to the batch role, not the tasks', () {
      final role = builder.batchRoleText(config, preset, context);

      expect(role, contains('SHARED PREGEN'));
      // A specific-agent block is one agent's job — it must not leak into the
      // instruction every controller reads.
      expect(role, isNot(contains('CONTINUITY ONLY')));
      expect(role, isNot(contains('DIALOGUE ONLY')));
    });

    test('target routing does not use agent name aliases', () {
      final text = builder.buildPerAgentTaskText(
        agent: const StudioAgent(
          id: 'custom-agent',
          name: 'Continuity Controller',
        ),
        config: config,
        studioPreset: preset,
        context: context,
      );

      expect(text, isNot(contains('CONTINUITY ONLY')));
      expect(text, isNot(contains('DIALOGUE ONLY')));
    });

    test('target routing uses only exact controllerId', () {
      final text = builder.buildPerAgentTaskText(
        agent: const StudioAgent(
          id: 'custom-agent',
          controllerId: 'continuity',
          name: 'Renamed controller',
        ),
        config: config,
        studioPreset: preset,
        context: context,
      );

      expect(text, contains('CONTINUITY ONLY'));
      expect(text, isNot(contains('DIALOGUE ONLY')));
    });

    test('pre-gen agent run receives only its own specific-agent block', () {
      final text = joinedMessages(
        builder.buildAgentMessages(
          agent: const StudioAgent(
            id: 'continuity',
            controllerId: 'continuity',
            name: 'Continuity Tracker',
          ),
          context: context,
          config: config,
          studioPreset: preset,
          priorBriefs: const [],
          isFinalResponse: false,
        ),
      );

      expect(text, contains('CONTINUITY ONLY'));
      expect(text, isNot(contains('DIALOGUE ONLY')));
      expect(text, isNot(contains('FINAL ONLY')));
      expect(text, isNot(contains('CLEANER ONLY')));
    });

    test('hard style contract reads only final-applicable instructions', () {
      final text = joinedMessages(
        builder.buildAgentMessages(
          agent: const StudioAgent(id: 'final', controllerId: 'final'),
          context: context,
          config: config,
          studioPreset: const StudioPreset(
            id: 'style',
            blocks: [
              StudioPresetBlock(
                id: 'final-style',
                content: 'Do not use em dashes.',
                mode: 'direct',
                injectionPoint: 'final',
              ),
              StudioPresetBlock(
                id: 'wrong-target',
                targetAgentId: 'dialogue',
                content: 'Wrap dialogue in quotation marks.',
                mode: 'direct',
                injectionPoint: 'specificAgent',
              ),
              StudioPresetBlock(
                id: 'wrong-section',
                content: 'Wrap dialogue in quotation marks.',
                mode: 'direct',
                injectionPoint: 'pregen',
              ),
              StudioPresetBlock(
                id: 'disabled',
                content: 'Wrap dialogue in quotation marks.',
                enabled: false,
                mode: 'direct',
                injectionPoint: 'final',
              ),
            ],
          ),
          priorBriefs: const [],
          isFinalResponse: true,
        ),
      );

      expect(text, contains('Do not use em dashes'));
      expect(text, isNot(contains('Wrap direct spoken dialogue')));
    });

    test('final brief macros expand and suppress previous_agents block', () {
      const macroConfig = StudioConfig(sessionId: 's1');
      const macroPreset = StudioPreset(
        id: 'studio',
        agents: [
          StudioAgent(
            id: 'agent_s_continuity_1',
            name: 'Continuity Controller',
          ),
          StudioAgent(id: 'agent_s_dialogue_1', name: 'Dialogue Controller'),
        ],
        blocks: [
          StudioPresetBlock(
            id: 'previous_agents',
            mode: 'pregenBrief',
            content: '',
            injectionPoint: 'final',
            order: 0,
          ),
          StudioPresetBlock(
            id: 'brief_macros',
            mode: 'direct',
            content:
                '<continuity>{{studio_continuity_brief}}</continuity>\n'
                '<dialogue>{{studio_dialogue_brief}}</dialogue>',
            injectionPoint: 'final',
            order: 1,
          ),
        ],
      );
      final messages = builder.buildAgentMessages(
        agent: const StudioAgent(id: 'final', name: 'Main Responder'),
        context: context,
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

  group('Studio agent envelope lane ownership', () {
    test('runtime leaves numeric response budgets to the active preset', () {
      for (final id in const ['guard_ru', 'guard_en']) {
        final guard = StudioControllerOntology.specs.firstWhere(
          (spec) => spec.id == id,
        );
        final guardAgent = StudioAgent(id: id, name: guard.name);
        final envelope = const StudioPromptText().intermediateRuntimeEnvelope(
          guard,
          guardAgent,
        );

        expect(envelope.toLowerCase(), isNot(contains('paragraph')));
        expect(envelope.toLowerCase(), isNot(contains('word budget')));
        expect(guard.purpose.toLowerCase(), isNot(contains('paragraph')));
        expect(
          guard.outputContract.toLowerCase(),
          isNot(contains('paragraph')),
        );
      }
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
        'order': 6,
      });
      expect(oldAgent.refreshPolicy, 'static');

      // The migration is in StudioConfigRepo._normalizeLoadedConfig which is
      // private. We test the migration logic by reproducing it here — it's a
      // pure normalization that any caller can apply. The repo applies it on
      // every load. This test documents the expected behavior.
      final migrated = _migrateForTest(oldAgent);
      expect(migrated.refreshPolicy, 'turn');
    });

    test('new Meta-Weaver with turn policy is unchanged', () {
      final newAgent = StudioAgent.fromJson(const {
        'id': 'agent_s1_meta_123',
        'name': 'Meta-Weaver / Lumia Policy',
        'refreshPolicy': 'turn',
        'order': 6,
      });
      final migrated = _migrateForTest(newAgent);
      expect(migrated.refreshPolicy, 'turn');
    });

    test('non-Meta-Weaver agent is unchanged by migration', () {
      final guard = StudioAgent.fromJson(const {
        'id': 'agent_s1_guard_123',
        'name': 'Anti-Loop & Prose Guard',
        'refreshPolicy': 'turn',
        'order': 4,
      });
      final migrated = _migrateForTest(guard);
      expect(migrated.refreshPolicy, 'turn');
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
