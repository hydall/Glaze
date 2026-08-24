import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/generation_context_inputs.dart';
import 'package:glaze_flutter/core/llm/memory_selector.dart';
import 'package:glaze_flutter/core/llm/prompt/recalled_message_chunk.dart';
import 'package:glaze_flutter/core/llm/prompt/runtime_prompt_block.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context_preparer.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_mode.dart';
import 'package:glaze_flutter/core/models/ledger_prompt_injection_policy.dart';
import 'package:glaze_flutter/core/llm/prompt/effective_canon_prompt_formatter.dart';
import 'package:glaze_flutter/core/llm/prompt/selective_ledger_projection_filter.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  const preparer = StudioContextPreparer();

  test('builds exact Studio lorebook provenance from merged entries', () {
    final context = preparer.prepare(
      inputs: const GenerationContextInputs(
        character: Character(id: 'char', name: 'Lucy'),
        history: [ChatMessage(id: 'user', role: 'user', content: 'Key')],
        sessionId: 'session',
        apiConfig: ApiConfig(id: 'api'),
        lorebooks: [
          Lorebook(
            id: 'book',
            name: 'Book',
            enabled: true,
            entries: [
              LorebookEntry(
                id: 'entry',
                lorebookId: 'book',
                lorebookName: 'Book',
                keys: ['Key'],
                content: 'Lore for {{char}}',
                position: 'lorebooksMacro',
              ),
            ],
          ),
        ],
      ),
      visibleMessageIds: const {'user'},
      studioPreset: const StudioPreset(id: 'studio'),
    );

    final manifest = context.diagnostics.exactLorebookManifest!;
    expect(manifest.entries, hasLength(1));
    expect(manifest.entries.single.entryId, 'entry');
    expect(manifest.entries.single.renderedContent, 'Lore for Lucy');
    expect(manifest.entries.single.classification, 'lorebooksMacro');
    expect(manifest.promptProvenance.sessionId, 'session');
    expect(manifest.promptProvenance.presetSnapshotHash, isNotEmpty);
  });

  test('prepares typed slots against the explicit Studio source window', () {
    const memory = MemoryEntry(
      id: 'memory',
      title: 'Older fact',
      content: 'A remembered fact',
      messageIds: ['old'],
    );
    final selection = MemorySelector.select(
      const MemorySelectionInput(
        selectionMode: 'hybrid',
        entries: [memory],
        visibleMessageIds: {},
        maxInjectedEntries: 4,
      ),
    );
    final context = preparer.prepare(
      inputs: GenerationContextInputs(
        character: const Character(
          id: 'char',
          name: 'Lucy',
          description: 'Original description',
          personality: 'Kind',
          scenario: 'At home',
          mesExample: 'Lucy: Hello',
        ),
        persona: const Persona(id: 'persona', name: 'Sam', prompt: 'Curious'),
        history: const [
          ChatMessage(id: 'old', role: 'assistant', content: 'Old reply'),
          ChatMessage(id: 'current', role: 'user', content: 'Current turn'),
          ChatMessage(
            id: 'hidden',
            role: 'user',
            content: 'Hidden turn',
            isHidden: true,
          ),
        ],
        sessionId: 'session',
        apiConfig: const ApiConfig(
          id: 'api',
          reasoningTagStart: '<api-think>',
          reasoningTagEnd: '</api-think>',
        ),
        summaryContent: 'Scene summary',
        summaryPrefix: 'Summary: ',
        memorySelection: selection,
        recalledMessageChunks: const [
          RecalledMessageChunk(text: 'Old reply', messageIds: ['old']),
          RecalledMessageChunk(text: 'External evidence', messageIds: ['x']),
        ],
        characterKnowledgeContent: '<knowledge>canon</knowledge>',
        studioSessionStateContent:
            '<studio_session_state>state</studio_session_state>',
        runtimePromptBlocks: const [
          RuntimePromptBlock(
            id: 'runtime',
            content: 'Runtime for {{char}}',
            depth: 2,
            role: 'user',
          ),
        ],
      ),
      visibleMessageIds: const {'current'},
    );

    expect(context.history.map((message) => message.content), ['Current turn']);
    expect(
      context.join(StudioContextSlot.characterCard),
      contains('Original description'),
    );
    expect(context.join(StudioContextSlot.userPersona), contains('Sam'));
    expect(context.join(StudioContextSlot.summary), 'Summary: Scene summary');
    expect(
      context.join(StudioContextSlot.memory),
      contains('A remembered fact'),
    );
    expect(
      context.join(StudioContextSlot.recalledMessages),
      allOf(contains('Old reply'), contains('External evidence')),
    );
    expect(
      context.join(StudioContextSlot.characterKnowledge),
      '<knowledge>canon</knowledge>',
    );
    expect(
      context.join(StudioContextSlot.studioSessionState),
      contains('state'),
    );
    expect(
      context.join(StudioContextSlot.runtimeDynamic),
      contains('Runtime for Lucy'),
    );
    expect(context.diagnostics.triggeredMemories.single.id, 'memory');
    expect(context.diagnostics.visibleMessageIds, {'current'});
    expect(context.macroContext.reasoningStart, '<api-think>');
    expect(context.macroContext.reasoningEnd, '</api-think>');
  });

  test('finalizes memory and recall independently for each source window', () {
    const entry = MemoryEntry(
      id: 'm1',
      title: 'Visible source',
      content: 'Memory content',
      messageIds: ['source'],
    );
    final selection = MemorySelector.select(
      const MemorySelectionInput(
        selectionMode: 'hybrid',
        entries: [entry],
        visibleMessageIds: {},
        maxInjectedEntries: 4,
      ),
    );
    final inputs = GenerationContextInputs(
      character: const Character(id: 'char', name: 'Lucy'),
      history: const [
        ChatMessage(id: 'source', role: 'assistant', content: 'Source'),
        ChatMessage(id: 'latest', role: 'user', content: 'Latest'),
      ],
      apiConfig: const ApiConfig(id: 'api'),
      memorySelection: selection,
      recalledMessageChunks: const [
        RecalledMessageChunk(text: 'Source evidence', messageIds: ['source']),
      ],
    );

    final narrow = preparer.prepare(
      inputs: inputs,
      visibleMessageIds: const {'latest'},
    );
    final wide = preparer.prepare(
      inputs: inputs,
      visibleMessageIds: const {'source', 'latest'},
    );

    expect(narrow.messagesFor(StudioContextSlot.memory), isNotEmpty);
    expect(narrow.messagesFor(StudioContextSlot.recalledMessages), isNotEmpty);
    expect(wide.messagesFor(StudioContextSlot.memory), isEmpty);
    expect(wide.messagesFor(StudioContextSlot.recalledMessages), isEmpty);
    expect(wide.diagnostics.triggeredMemories, isEmpty);
  });

  test('maps lore positions and keeps absent optional slots empty', () {
    const lorebook = Lorebook(
      id: 'book',
      name: 'World',
      entries: [
        LorebookEntry(
          id: 'before',
          lorebookId: 'book',
          lorebookName: 'World',
          content: 'Before {{char}}',
          constant: true,
          position: 'worldInfoBefore',
        ),
        LorebookEntry(
          id: 'macro',
          lorebookId: 'book',
          lorebookName: 'World',
          content: 'Macro lore',
          constant: true,
          position: 'lorebooksMacro',
        ),
      ],
    );
    final context = preparer.prepare(
      inputs: const GenerationContextInputs(
        character: Character(id: 'char', name: 'Lucy'),
        history: [],
        apiConfig: ApiConfig(id: 'api'),
        lorebooks: [lorebook],
      ),
      visibleMessageIds: const {},
    );

    expect(context.join(StudioContextSlot.loreBefore), 'Before Lucy');
    expect(context.join(StudioContextSlot.loreMacro), 'Macro lore');
    expect(context.messagesFor(StudioContextSlot.loreAfter), isEmpty);
    expect(context.messagesFor(StudioContextSlot.authorsNote), isEmpty);
    expect(context.diagnostics.triggeredLorebooks, hasLength(2));
  });

  test('disabled policy removes only Ledger-owned dynamic channels', () {
    final context = preparer.prepare(
      inputs: GenerationContextInputs(
        character: const Character(id: 'char', name: 'Lucy'),
        history: const [
          ChatMessage(id: 'latest', role: 'user', content: 'Latest'),
        ],
        apiConfig: const ApiConfig(id: 'api'),
        characterKnowledgeContent:
            '<current_character_state>fact</current_character_state>',
        studioSessionStateContent:
            '<studio_session_state>state</studio_session_state>',
        arcContent: '<arc_state>arc</arc_state>',
        guidanceText: 'guidance',
        entitiesContent: 'entities',
        runtimePromptBlocks: const [
          RuntimePromptBlock(
            id: 'runtime',
            content: 'runtime {{studio_state}} preserved',
            depth: 0,
            role: 'system',
          ),
        ],
      ),
      visibleMessageIds: const {'latest'},
      ledgerPromptInjectionPolicy: const LedgerPromptInjectionPolicy(
        presetOptIn: false,
        mode: LedgerPromptInjectionMode.disabled,
      ),
    );

    expect(context.messagesFor(StudioContextSlot.characterKnowledge), isEmpty);
    expect(context.messagesFor(StudioContextSlot.studioSessionState), isEmpty);
    final runtime = context.join(StudioContextSlot.runtimeDynamic);
    expect(runtime, contains('guidance'));
    expect(runtime, contains('entities'));
    expect(runtime, contains('runtime  preserved'));
    expect(runtime, isNot(contains('<arc_state>')));
  });

  test('formatter-owned transition content is injected exactly once', () {
    final context = preparer.prepare(
      inputs: GenerationContextInputs(
        character: const Character(id: 'char', name: 'Lucy'),
        history: const [
          ChatMessage(id: 'latest', role: 'user', content: 'Latest'),
        ],
        sessionId: 'session',
        apiConfig: const ApiConfig(id: 'api'),
        effectiveCanonProjection: const EffectiveCanonPromptProjection(
          facts: [],
          trackers: [],
          unblockedTransitionClaims: ['The door is now open.'],
          revisionNumber: 1,
          revisionHash: 'revision',
          cacheIdentity: 'canon',
        ),
      ),
      visibleMessageIds: const {'latest'},
    );

    final session = context.join(StudioContextSlot.studioSessionState);
    expect(
      RegExp('<effective_canon_transitions>').allMatches(session),
      hasLength(1),
    );
    expect(session, contains('The door is now open.'));
  });

  test(
    'filtered null character and arc channels do not resurrect raw fields',
    () {
      final context = preparer.prepare(
        inputs: GenerationContextInputs(
          character: const Character(id: 'char', name: 'Lucy'),
          history: const [
            ChatMessage(id: 'source', role: 'assistant', content: 'Source'),
            ChatMessage(id: 'latest', role: 'user', content: 'Latest'),
          ],
          sessionId: 'session',
          apiConfig: const ApiConfig(id: 'api'),
          characterKnowledgeContent: 'RAW KNOWLEDGE',
          arcContent: 'RAW ARC',
          effectiveCanonProjection: const EffectiveCanonPromptProjection(
            facts: [],
            trackers: [
              Tracker(
                sessionId: 'session',
                name: 'scene.immediate_thread',
                value: 'Source',
                provenance: 'messageId=source',
              ),
            ],
            unblockedTransitionClaims: [],
            revisionNumber: 1,
            revisionHash: 'revision',
            cacheIdentity: 'canon',
          ),
          ledgerProjectionFreshnessProvenCurrent: true,
        ),
        visibleMessageIds: const {'source', 'latest'},
        ledgerPromptInjectionPolicy: const LedgerPromptInjectionPolicy(
          presetOptIn: true,
          mode: LedgerPromptInjectionMode.gapFiller,
        ),
      );

      expect(
        context.messagesFor(StudioContextSlot.characterKnowledge),
        isEmpty,
      );
      expect(
        context.join(StudioContextSlot.runtimeDynamic),
        isNot(contains('RAW ARC')),
      );
    },
  );

  test(
    'tracker and final materialize against their distinct visible windows',
    () {
      final inputs = GenerationContextInputs(
        character: const Character(id: 'char', name: 'Lucy'),
        history: const [
          ChatMessage(id: 'source', role: 'assistant', content: 'Lucy waits.'),
          ChatMessage(id: 'latest', role: 'user', content: 'Continue.'),
        ],
        sessionId: 'session',
        apiConfig: const ApiConfig(id: 'api'),
        effectiveCanonProjection: const EffectiveCanonPromptProjection(
          facts: [],
          trackers: [
            Tracker(
              sessionId: 'session',
              name: 'scene.immediate_thread',
              value: 'Lucy waits',
              provenance: 'messageId=source',
            ),
          ],
          unblockedTransitionClaims: [],
          revisionNumber: 1,
          revisionHash: 'revision',
          cacheIdentity: 'canon',
        ),
        ledgerProjectionFreshnessProvenCurrent: true,
      );
      const policy = LedgerPromptInjectionPolicy(
        presetOptIn: true,
        mode: LedgerPromptInjectionMode.gapFiller,
      );

      final tracker = preparer.prepare(
        inputs: inputs,
        visibleMessageIds: const {'latest'},
        ledgerPromptInjectionPolicy: policy,
        consumerPath: 'studio-tracker',
      );
      final finalWriter = preparer.prepare(
        inputs: inputs,
        visibleMessageIds: const {'source', 'latest'},
        ledgerPromptInjectionPolicy: policy,
        consumerPath: 'studio-final',
      );

      expect(
        tracker.join(StudioContextSlot.studioSessionState),
        contains('Lucy waits'),
      );
      expect(
        finalWriter.join(StudioContextSlot.studioSessionState),
        isNot(contains('Lucy waits')),
      );
      expect(
        finalWriter.diagnostics.ledgerProjectionDiagnostics.any(
          (item) =>
              !item.selected &&
              item.reason ==
                  LedgerProjectionDecisionReason.visibleSourceEvidence,
        ),
        isTrue,
      );
      expect(
        tracker.diagnostics.ledgerInjectionIdentity,
        isNot(finalWriter.diagnostics.ledgerInjectionIdentity),
      );
    },
  );
}
