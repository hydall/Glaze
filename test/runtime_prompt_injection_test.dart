import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/llm/memory_selector.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/extensions/services/runtime_prompt_injection_service.dart';

void main() {
  test('runtime prompt injections are session-scoped and removable', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(runtimePromptInjectionProvider.notifier);
    notifier.inject(
      sessionId: 's1',
      id: 'mood',
      content: 'Keep the scene tense.',
      depth: 1,
      role: 'system',
    );
    notifier.inject(
      sessionId: 's2',
      id: 'mood',
      content: 'Keep the scene quiet.',
    );

    expect(notifier.bySession('s1').single.content, 'Keep the scene tense.');
    expect(notifier.bySession('s2').single.content, 'Keep the scene quiet.');

    expect(notifier.uninject(sessionId: 's1', id: 'mood'), isTrue);
    expect(notifier.bySession('s1'), isEmpty);
    expect(notifier.bySession('s2'), hasLength(1));
  });

  test(
    'runtime prompt blocks are inserted by depth during prompt assembly',
    () {
      final result = buildPrompt(
        PromptPayload(
          character: Character(id: 'c1', name: 'Alice'),
          preset: const Preset(
            id: 'p1',
            name: 'Prompt',
            blocks: [
              PresetBlock(
                id: 'chat_history',
                name: 'History',
                role: 'system',
                content: '',
              ),
            ],
          ),
          history: const [
            ChatMessage(id: 'm1', role: 'user', content: 'First'),
            ChatMessage(id: 'm2', role: 'assistant', content: 'Second'),
          ],
          apiConfig: const ApiConfig(
            id: 'api',
            name: 'API',
            contextSize: 10000,
            maxTokens: 100,
          ),
          runtimePromptBlocks: const [
            RuntimePromptBlock(
              id: 'mood',
              content: 'Keep the scene tense.',
              depth: 1,
              role: 'system',
            ),
          ],
        ),
      );

      expect(result.messages.map((message) => message.content).toList(), [
        'First',
        'Keep the scene tense.',
        'Second',
      ]);
      expect(result.messages[1].blockId, 'runtime_prompt:mood');
      expect(result.messages[1].isDepth, isTrue);
    },
  );

  test('factual-continuity guard is opt-in and prompt-only', () {
    PromptPayload payload({required bool guardActive}) => PromptPayload(
      character: Character(id: 'c1', name: 'Alice'),
      preset: const Preset(
        id: 'p1',
        name: 'Prompt',
        blocks: [
          PresetBlock(
            id: 'chat_history',
            name: 'History',
            role: 'system',
            content: '',
          ),
        ],
      ),
      history: const [
        ChatMessage(id: 'm1', role: 'user', content: 'Do you remember?'),
      ],
      apiConfig: const ApiConfig(
        id: 'api',
        name: 'API',
        contextSize: 10000,
        maxTokens: 100,
      ),
      memorySelection: const MemorySelection(),
      memoryCoverage: {
        'diagnostics': {
          'missingContextSuspected': true,
          'reliableCandidateFound': false,
          'factualContinuityGuardActive': guardActive,
        },
      },
    );

    final defaultResult = buildPrompt(payload(guardActive: false));
    expect(
      defaultResult.messages.any(
        (message) => message.content.contains('Factual continuity note'),
      ),
      isFalse,
    );

    final guardedResult = buildPrompt(payload(guardActive: true));
    expect(
      guardedResult.messages.any(
        (message) => message.content.contains('Factual continuity note'),
      ),
      isTrue,
    );
    expect(guardedResult.messages.where((m) => m.isHistory), hasLength(1));
  });

  test('deferred memory injection can inject source-linked excerpts', () {
    final content = [
      'The bridge scene opened with rain and silence.',
      'Sable promised Ren she would hide the ritual map until the debt was paid.',
      'They argued about lanterns and horses for several minutes.',
    ].join('\n\n');
    final entry = MemoryEntry(
      id: 'm1',
      title: 'Bridge memory',
      content: content,
      keys: const ['ritual map', 'debt'],
      status: 'active',
    );
    final selection = MemorySelector.select(
      MemorySelectionInput(
        entries: [entry],
        keywordMatchedTerms: const {
          'm1': ['ritual map', 'debt'],
        },
        maxInjectionTokens: 12,
        maxInjectedEntries: 1,
        vectorWeight: 0,
        recencyBoost: false,
        importanceBoost: false,
        diversityAware: false,
      ),
      tokenCounter: (entry) => entry.content.split(RegExp(r'\s+')).length,
    );

    final result = buildPrompt(
      PromptPayload(
        character: Character(id: 'c1', name: 'Alice'),
        preset: const Preset(
          id: 'p1',
          name: 'Prompt',
          blocks: [
            PresetBlock(
              id: 'chat_history',
              name: 'History',
              role: 'system',
              content: '',
            ),
          ],
        ),
        history: const [
          ChatMessage(id: 'u1', role: 'user', content: 'What about the map?'),
        ],
        apiConfig: const ApiConfig(
          id: 'api',
          name: 'API',
          contextSize: 10000,
          maxTokens: 100,
        ),
        memorySelection: selection,
        memoryInjectionTarget: 'hard_block',
      ),
    );

    final memoryMessage = result.messages.firstWhere(
      (message) => message.blockId == 'memory',
    );
    expect(memoryMessage.content, contains('Memory: Bridge memory'));
    expect(memoryMessage.content, contains('ritual map'));
    expect(
      memoryMessage.content,
      contains('Excerpted from a larger Memory Book entry'),
    );

    final diagnostics = result.memoryCoverage['diagnostics'] as Map;
    final candidates = diagnostics['candidates'] as List;
    final candidate = candidates.single as Map;
    expect(candidate['injectionType'], 'excerpt');
    expect(
      candidate['originalTokenCost'] as int,
      greaterThan(candidate['tokenCost'] as int),
    );
  });

  test('deferred memory macro placement receives final excerpts', () {
    final content = [
      'The bridge scene opened with rain and silence.',
      'Sable promised Ren she would hide the ritual map until the debt was paid.',
      'They argued about lanterns and horses for several minutes.',
    ].join('\n\n');
    final entry = MemoryEntry(
      id: 'm1',
      title: 'Bridge memory',
      content: content,
      keys: const ['ritual map', 'debt'],
      status: 'active',
    );
    final selection = MemorySelector.select(
      MemorySelectionInput(
        entries: [entry],
        keywordMatchedTerms: const {
          'm1': ['ritual map', 'debt'],
        },
        maxInjectionTokens: 12,
        maxInjectedEntries: 1,
        vectorWeight: 0,
        recencyBoost: false,
        importanceBoost: false,
        diversityAware: false,
      ),
      tokenCounter: (entry) => entry.content.split(RegExp(r'\s+')).length,
    );

    final result = buildPrompt(
      PromptPayload(
        character: Character(id: 'c1', name: 'Alice'),
        preset: const Preset(
          id: 'p1',
          name: 'Prompt',
          blocks: [
            PresetBlock(
              id: 'memory_slot',
              name: 'Memory Slot',
              role: 'system',
              content: 'Selected memories:\n{{memory}}',
            ),
            PresetBlock(
              id: 'chat_history',
              name: 'History',
              role: 'system',
              content: '',
            ),
          ],
        ),
        history: const [
          ChatMessage(id: 'u1', role: 'user', content: 'What about the map?'),
        ],
        apiConfig: const ApiConfig(
          id: 'api',
          name: 'API',
          contextSize: 10000,
          maxTokens: 100,
        ),
        memorySelection: selection,
        memoryInjectionTarget: 'macro',
      ),
    );

    final memorySlot = result.messages.firstWhere(
      (message) => message.blockId == 'memory_slot',
    );
    expect(memorySlot.content, contains('Selected memories:'));
    expect(memorySlot.content, contains('ritual map'));
    expect(memorySlot.content, isNot(contains('GLAZE_DEFERRED')));
    expect(result.messages.where((m) => m.blockId == 'memory'), isEmpty);
    expect(result.breakdown.memoryTokens, greaterThan(0));
  });

  test('dedicated memory preset block receives deferred excerpts', () {
    final content = [
      'The bridge scene opened with rain and silence.',
      'Sable promised Ren she would hide the ritual map until the debt was paid.',
      'They argued about lanterns and horses for several minutes.',
    ].join('\n\n');
    final entry = MemoryEntry(
      id: 'm1',
      title: 'Bridge memory',
      content: content,
      keys: const ['ritual map', 'debt'],
      status: 'active',
    );
    final selection = MemorySelector.select(
      MemorySelectionInput(
        entries: [entry],
        keywordMatchedTerms: const {
          'm1': ['ritual map', 'debt'],
        },
        maxInjectionTokens: 12,
        maxInjectedEntries: 1,
        vectorWeight: 0,
        recencyBoost: false,
        importanceBoost: false,
        diversityAware: false,
      ),
      tokenCounter: (entry) => entry.content.split(RegExp(r'\s+')).length,
    );

    final result = buildPrompt(
      PromptPayload(
        character: Character(id: 'c1', name: 'Alice'),
        preset: const Preset(
          id: 'p1',
          name: 'Prompt',
          blocks: [
            // Dedicated Memory Book block — no {{memory}} macro anywhere.
            PresetBlock(
              id: 'memory',
              name: 'Memory Book',
              role: 'system',
              content: '',
              isStatic: true,
            ),
            PresetBlock(
              id: 'chat_history',
              name: 'History',
              role: 'system',
              content: '',
            ),
          ],
        ),
        history: const [
          ChatMessage(id: 'u1', role: 'user', content: 'What about the map?'),
        ],
        apiConfig: const ApiConfig(
          id: 'api',
          name: 'API',
          contextSize: 10000,
          maxTokens: 100,
        ),
        memorySelection: selection,
        // Even with macro target, the dedicated block is the sink.
        memoryInjectionTarget: 'macro',
      ),
    );

    final memoryMessage = result.messages.firstWhere(
      (message) => message.blockId == 'memory',
    );
    expect(memoryMessage.content, contains('Bridge memory'));
    expect(memoryMessage.content, contains('ritual map'));
    expect(memoryMessage.content, isNot(contains('GLAZE_DEFERRED')));
    // No silent-drop warning: memory landed in the block.
    expect(result.memoryCoverage['memoryMacroMissing'], isNot(isTrue));
    expect(result.breakdown.memoryTokens, greaterThan(0));
  });

  test(
    'macro target without {{memory}} placeholder flags memoryMacroMissing',
    () {
      final content = [
        'The bridge scene opened with rain and silence.',
        'Sable promised Ren she would hide the ritual map until the debt was paid.',
        'They argued about lanterns and horses for several minutes.',
      ].join('\n\n');
      final entry = MemoryEntry(
        id: 'm1',
        title: 'Bridge memory',
        content: content,
        keys: const ['ritual map', 'debt'],
        status: 'active',
      );
      final selection = MemorySelector.select(
        MemorySelectionInput(
          entries: [entry],
          keywordMatchedTerms: const {
            'm1': ['ritual map', 'debt'],
          },
          maxInjectionTokens: 12,
          maxInjectedEntries: 1,
          vectorWeight: 0,
          recencyBoost: false,
          importanceBoost: false,
          diversityAware: false,
        ),
        tokenCounter: (entry) => entry.content.split(RegExp(r'\s+')).length,
      );

      final result = buildPrompt(
        PromptPayload(
          character: Character(id: 'c1', name: 'Alice'),
          preset: const Preset(
            id: 'p1',
            name: 'Prompt',
            blocks: [
              // No {{memory}} anywhere — the macro target has nowhere to land.
              PresetBlock(
                id: 'system',
                name: 'System',
                role: 'system',
                content: 'You are Alice.',
              ),
              PresetBlock(
                id: 'chat_history',
                name: 'History',
                role: 'system',
                content: '',
              ),
            ],
          ),
          history: const [
            ChatMessage(id: 'u1', role: 'user', content: 'What about the map?'),
          ],
          apiConfig: const ApiConfig(
            id: 'api',
            name: 'API',
            contextSize: 10000,
            maxTokens: 100,
          ),
          memorySelection: selection,
          memoryInjectionTarget: 'macro',
        ),
      );

      // Memory is neither injected as a macro nor as a hard block.
      expect(result.messages.where((m) => m.blockId == 'memory'), isEmpty);
      for (final message in result.messages) {
        expect(message.content, isNot(contains('GLAZE_DEFERRED')));
      }
      // The warning flag is surfaced for the UI.
      expect(result.memoryCoverage['memoryMacroMissing'], isTrue);
      final diagnostics =
          result.memoryCoverage['diagnostics'] as Map<String, dynamic>;
      expect(diagnostics['memoryMacroMissing'], isTrue);
      // The last user message is preserved.
      expect(
        result.messages.any((m) => m.isHistory && m.role == 'user'),
        isTrue,
      );
    },
  );

  test(
    'deferred memory appendToLastMessage receives final excerpts in history',
    () {
      final content = [
        'The bridge scene opened with rain and silence.',
        'Sable promised Ren she would hide the ritual map until the debt was paid.',
        'They argued about lanterns and horses for several minutes.',
      ].join('\n\n');
      final entry = MemoryEntry(
        id: 'm1',
        title: 'Bridge memory',
        content: content,
        keys: const ['ritual map', 'debt'],
        status: 'active',
      );
      final selection = MemorySelector.select(
        MemorySelectionInput(
          entries: [entry],
          keywordMatchedTerms: const {
            'm1': ['ritual map', 'debt'],
          },
          maxInjectionTokens: 12,
          maxInjectedEntries: 1,
          vectorWeight: 0,
          recencyBoost: false,
          importanceBoost: false,
          diversityAware: false,
        ),
        tokenCounter: (entry) => entry.content.split(RegExp(r'\s+')).length,
      );

      final result = buildPrompt(
        PromptPayload(
          character: Character(id: 'c1', name: 'Alice'),
          preset: const Preset(
            id: 'p1',
            name: 'Prompt',
            blocks: [
              PresetBlock(
                id: 'inject_slot',
                name: 'Inject Slot',
                role: 'user',
                content:
                    '<lorebooks>\n{{lorebooks}}\n</lorebooks>\n<summary>\n{{memory}}\n</summary>',
                appendToLastMessage: true,
              ),
              PresetBlock(
                id: 'chat_history',
                name: 'History',
                role: 'system',
                content: '',
              ),
            ],
          ),
          history: const [
            ChatMessage(id: 'u1', role: 'user', content: 'What about the map?'),
          ],
          apiConfig: const ApiConfig(
            id: 'api',
            name: 'API',
            contextSize: 10000,
            maxTokens: 100,
          ),
          memorySelection: selection,
          memoryInjectionTarget: 'macro',
        ),
      );

      final lastUser = result.messages.lastWhere((m) => m.role == 'user');
      expect(lastUser.content, contains('<summary>'));
      expect(lastUser.content, contains('ritual map'));
      expect(lastUser.content, isNot(contains('GLAZE_DEFERRED')));
    },
  );

  test('deferred memory chunk-first never injects full entries', () {
    final content = [
      'setup filler words words words',
      'needle clue should be the only injected chunk',
      'tail filler words words words',
    ].join('\n\n');
    final entry = MemoryEntry(
      id: 'm1',
      title: 'Chunked memory',
      content: content,
      keys: const ['needle'],
      status: 'active',
    );
    final selection = MemorySelection(
      entries: [entry],
      allScores: [
        MemoryCandidateScore(
          entry: entry,
          score: 10,
          matchedKeys: const ['needle'],
        ),
      ],
      budgetTokens: 100,
      entryCap: 1,
    );

    final result = buildPrompt(
      PromptPayload(
        character: Character(id: 'c1', name: 'Alice'),
        preset: const Preset(
          id: 'p1',
          name: 'Prompt',
          blocks: [
            PresetBlock(
              id: 'chat_history',
              name: 'History',
              role: 'system',
              content: '',
            ),
          ],
        ),
        history: const [
          ChatMessage(id: 'u1', role: 'user', content: 'What about needle?'),
        ],
        apiConfig: const ApiConfig(
          id: 'api',
          name: 'API',
          contextSize: 10000,
          maxTokens: 100,
        ),
        memorySelection: selection,
        memoryInjectionTarget: 'hard_block',
        memoryPackingMode: 'chunk_first',
        memoryExcerptTokensPerChunk: 8,
        memoryExcerptChunksPerEntry: 1,
      ),
    );

    final memoryMessage = result.messages.firstWhere(
      (message) => message.blockId == 'memory',
    );
    expect(memoryMessage.content, contains('needle clue'));
    expect(memoryMessage.content, isNot(contains('setup filler')));
    expect(memoryMessage.content, isNot(contains('tail filler')));
    final diagnostics = result.memoryCoverage['diagnostics'] as Map;
    final candidate = (diagnostics['candidates'] as List).single as Map;
    expect(candidate['injectionType'], 'excerpt');
    expect(candidate['excerptChunkIndexes'], [1]);
  });

  test('lorebook badge includes keyword and vector macro injections', () {
    final keywordEntry = LorebookEntry(
      id: 'kw1',
      comment: 'Keyword Entry',
      keys: const ['Katelyn'],
      content: 'Keyword lore payload.',
      position: 'lorebooksMacro',
    );
    final vectorEntry = LorebookEntry(
      id: 'vec1',
      comment: 'Vector Entry',
      content: 'Vector lore payload.',
      position: 'lorebooksMacro',
      vectorSearch: true,
      useKeywordSearch: false,
    );

    final result = buildPrompt(
      PromptPayload(
        character: Character(id: 'c1', name: 'Alice'),
        preset: const Preset(
          id: 'p1',
          name: 'Prompt',
          blocks: [
            PresetBlock(
              id: 'lore_slot',
              name: 'Lore Slot',
              role: 'user',
              content: '<lorebooks>\n{{lorebooks}}\n</lorebooks>',
              appendToLastMessage: true,
            ),
            PresetBlock(
              id: 'chat_history',
              name: 'History',
              role: 'system',
              content: '',
            ),
          ],
        ),
        history: const [
          ChatMessage(
            id: 'u1',
            role: 'user',
            content: 'Tell me about Katelyn.',
          ),
        ],
        apiConfig: const ApiConfig(
          id: 'api',
          name: 'API',
          contextSize: 10000,
          maxTokens: 100,
        ),
        lorebooks: [
          Lorebook(
            id: 'lb1',
            name: 'Book',
            entries: [keywordEntry, vectorEntry],
          ),
        ],
        lorebookSettings: const LorebookGlobalSettings(
          searchType: 'both',
          injectionPosition: 'lorebooksMacro',
          maxInjectedEntries: 4,
        ),
        vectorEntries: [vectorEntry],
      ),
    );

    final lastUser = result.messages.lastWhere((m) => m.role == 'user');
    expect(lastUser.content, contains('Keyword lore payload.'));
    expect(lastUser.content, contains('Vector lore payload.'));
    expect(result.triggeredLorebooks.map((e) => e.name), [
      'Keyword Entry',
      'Vector Entry',
    ]);
    expect(result.triggeredLorebooks.map((e) => e.source), [
      'keyword',
      'vector',
    ]);
  });

  test('keyword source wins over vector when the same entry matches both', () {
    final keywordOnlyEntry = LorebookEntry(
      id: 'kw1',
      comment: 'Keyword Only',
      keys: const ['New York'],
      content: 'Keyword-only payload.',
      position: 'lorebooksMacro',
    );
    final duplicateEntry = LorebookEntry(
      id: 'dupe1',
      comment: 'Katelyn Brooks',
      keys: const ['Katelyn'],
      content: 'Katelyn payload.',
      position: 'lorebooksMacro',
      vectorSearch: true,
      useKeywordSearch: true,
    );

    final result = buildPrompt(
      PromptPayload(
        character: Character(id: 'c1', name: 'Alice'),
        preset: const Preset(
          id: 'p1',
          name: 'Prompt',
          blocks: [
            PresetBlock(
              id: 'lore_slot',
              name: 'Lore Slot',
              role: 'user',
              content: '<lorebooks>\n{{lorebooks}}\n</lorebooks>',
              appendToLastMessage: true,
            ),
            PresetBlock(
              id: 'chat_history',
              name: 'History',
              role: 'system',
              content: '',
            ),
          ],
        ),
        history: const [
          ChatMessage(
            id: 'u1',
            role: 'user',
            content: 'New York and Katelyn are both relevant.',
          ),
        ],
        apiConfig: const ApiConfig(
          id: 'api',
          name: 'API',
          contextSize: 10000,
          maxTokens: 100,
        ),
        lorebooks: [
          Lorebook(
            id: 'lb1',
            name: 'Book',
            entries: [keywordOnlyEntry, duplicateEntry],
          ),
        ],
        lorebookSettings: const LorebookGlobalSettings(
          searchType: 'both',
          injectionPosition: 'lorebooksMacro',
          maxInjectedEntries: 4,
          keywordVectorSplit: 50,
        ),
        vectorEntries: [duplicateEntry],
      ),
    );

    expect(
      result.triggeredLorebooks.where((e) => e.name == 'Katelyn Brooks'),
      hasLength(1),
    );
    expect(
      result.triggeredLorebooks
          .firstWhere((e) => e.name == 'Katelyn Brooks')
          .source,
      'keyword',
    );
  });

  test('keyword-matched overflow vector entries keep keyword badge source', () {
    final firstKeyword = LorebookEntry(
      id: 'kw1',
      comment: 'First Keyword',
      keys: const ['alpha'],
      content: 'First keyword payload.',
      position: 'lorebooksMacro',
      order: 10,
    );
    final duplicate = LorebookEntry(
      id: 'dupe1',
      comment: 'Duplicate Keyword Vector',
      keys: const ['beta'],
      content: 'Duplicate payload.',
      position: 'lorebooksMacro',
      order: 20,
      vectorSearch: true,
      useKeywordSearch: true,
    );
    final vectorOnly = LorebookEntry(
      id: 'vec1',
      comment: 'Vector Only',
      content: 'Vector-only payload.',
      position: 'lorebooksMacro',
      order: 30,
      vectorSearch: true,
      useKeywordSearch: false,
    );

    final result = buildPrompt(
      PromptPayload(
        character: Character(id: 'c1', name: 'Alice'),
        preset: const Preset(
          id: 'p1',
          name: 'Prompt',
          blocks: [
            PresetBlock(
              id: 'lore_slot',
              name: 'Lore Slot',
              role: 'user',
              content: '<lorebooks>\n{{lorebooks}}\n</lorebooks>',
              appendToLastMessage: true,
            ),
            PresetBlock(
              id: 'chat_history',
              name: 'History',
              role: 'system',
              content: '',
            ),
          ],
        ),
        history: const [
          ChatMessage(id: 'u1', role: 'user', content: 'alpha beta'),
        ],
        apiConfig: const ApiConfig(
          id: 'api',
          name: 'API',
          contextSize: 10000,
          maxTokens: 100,
        ),
        lorebooks: [
          Lorebook(
            id: 'lb1',
            name: 'Book',
            entries: [firstKeyword, duplicate, vectorOnly],
          ),
        ],
        lorebookSettings: const LorebookGlobalSettings(
          searchType: 'both',
          injectionPosition: 'lorebooksMacro',
          maxInjectedEntries: 2,
          keywordVectorSplit: 50,
        ),
        vectorEntries: [duplicate, vectorOnly],
      ),
    );

    final lastUser = result.messages.lastWhere((m) => m.role == 'user');
    expect(lastUser.content, contains('First keyword payload.'));
    expect(lastUser.content, contains('Duplicate payload.'));
    expect(lastUser.content, isNot(contains('Vector-only payload.')));
    expect(result.triggeredLorebooks.map((e) => e.name), [
      'First Keyword',
      'Duplicate Keyword Vector',
    ]);
    expect(result.triggeredLorebooks.map((e) => e.source), [
      'keyword',
      'keyword',
    ]);
  });

  test('chat-bound lorebook keyword source wins over vector badge', () {
    final entry = LorebookEntry(
      id: 'bound1',
      comment: 'Chat Bound Keyword',
      keys: const ['artifact'],
      content: 'Chat-bound keyword payload.',
      position: 'lorebooksMacro',
      vectorSearch: true,
      useKeywordSearch: true,
    );

    final result = buildPrompt(
      PromptPayload(
        character: Character(id: 'c1', name: 'Alice'),
        preset: const Preset(
          id: 'p1',
          name: 'Prompt',
          blocks: [
            PresetBlock(
              id: 'lore_slot',
              name: 'Lore Slot',
              role: 'user',
              content: '<lorebooks>\n{{lorebooks}}\n</lorebooks>',
              appendToLastMessage: true,
            ),
            PresetBlock(
              id: 'chat_history',
              name: 'History',
              role: 'system',
              content: '',
            ),
          ],
        ),
        history: const [
          ChatMessage(id: 'u1', role: 'user', content: 'Find the artifact.'),
        ],
        sessionId: 's1',
        apiConfig: const ApiConfig(
          id: 'api',
          name: 'API',
          contextSize: 10000,
          maxTokens: 100,
        ),
        lorebooks: [
          Lorebook(
            id: 'lb1',
            name: 'Chat Book',
            enabled: false,
            activationScope: 'chat',
            activationTargetId: 's1',
            entries: [entry],
          ),
        ],
        lorebookSettings: const LorebookGlobalSettings(
          searchType: 'both',
          injectionPosition: 'lorebooksMacro',
          maxInjectedEntries: 4,
        ),
        vectorEntries: [entry],
      ),
    );

    expect(result.triggeredLorebooks, hasLength(1));
    expect(result.triggeredLorebooks.single.name, 'Chat Bound Keyword');
    expect(result.triggeredLorebooks.single.lorebookName, 'Chat Book');
    expect(result.triggeredLorebooks.single.lorebookId, 'lb1');
    expect(result.triggeredLorebooks.single.source, 'keyword');
  });

  test('vector lore is injected with lorebook provenance', () {
    const vectorEntry = LorebookEntry(
      id: 'vector',
      comment: 'Vector Entry',
      content: 'Vector payload marker.',
      position: 'lorebooksMacro',
      vectorSearch: true,
      useKeywordSearch: false,
      lorebookId: 'lb1',
      lorebookName: 'Vector Book',
    );
    final result = buildPrompt(
      PromptPayload(
        character: Character(id: 'c1', name: 'Alice'),
        preset: const Preset(
          id: 'p1',
          name: 'Prompt',
          blocks: [
            PresetBlock(
              id: 'lore_slot',
              name: 'Lore Slot',
              role: 'system',
              content: '{{lorebooks}}',
            ),
            PresetBlock(
              id: 'chat_history',
              name: 'History',
              role: 'system',
              content: '',
            ),
          ],
        ),
        history: const [
          ChatMessage(id: 'u1', role: 'user', content: 'Current scene.'),
        ],
        apiConfig: const ApiConfig(
          id: 'api',
          name: 'API',
          contextSize: 10000,
          maxTokens: 100,
        ),
        lorebooks: const [
          Lorebook(id: 'lb1', name: 'Vector Book', entries: [vectorEntry]),
        ],
        lorebookSettings: const LorebookGlobalSettings(
          searchType: 'vector',
          injectionPosition: 'lorebooksMacro',
        ),
        vectorEntries: const [vectorEntry],
      ),
    );

    expect(
      result.messages.any((m) => m.content.contains('Vector payload marker.')),
      isTrue,
    );
    expect(result.triggeredLorebooks, hasLength(1));
    expect(result.triggeredLorebooks.single.lorebookId, 'lb1');
    expect(result.triggeredLorebooks.single.lorebookName, 'Vector Book');
    expect(result.triggeredLorebooks.single.source, 'vector');
  });
}
