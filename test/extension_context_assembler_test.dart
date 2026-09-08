import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/context_calculator.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/prompt/main_model_context_snapshot.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/extension_context_policy.dart';
import 'package:glaze_flutter/features/extensions/services/extension_context_assembler.dart';

const _character = Character(id: 'c1', name: 'Alice', description: 'Card');
const _api = ApiConfig(id: 'api');
const _block = BlockConfig(id: 'b1', name: 'State', contextMessageCount: 1);

ChatMessage _chat(String id, String role, String content) =>
    ChatMessage(id: id, role: role, content: content, timestamp: 1);

MainModelContextSnapshot _snapshot(List<PromptMessage> promptMessages) {
  final result = PromptResult(
    messages: promptMessages,
    breakdown: const TokenBreakdown(
      sourceTokens: {},
      staticTotal: 0,
      historyBudget: 0,
      historyTokens: 0,
      totalTokens: 0,
      cutoffIndex: 0,
      trimmedHistory: [],
    ),
    sessionVars: const {},
    globalVars: const {},
  );
  final payload = PromptPayload(
    character: _character,
    history: const [],
    apiConfig: _api,
  );
  return MainModelContextSnapshot(
    providerMessages: promptMessages
        .map((message) => message.toApiMap())
        .toList(),
    promptResult: result,
    promptPayload: payload,
    isStudioFinalWriter: false,
  );
}

MainModelContextSnapshot _studioSnapshot(List<PromptMessage> baseMessages) {
  final snapshot = _snapshot(baseMessages);
  return MainModelContextSnapshot(
    providerMessages: const [
      {'role': 'system', 'content': 'studio final only'},
    ],
    promptResult: snapshot.promptResult,
    promptPayload: snapshot.promptPayload,
    source: MainModelContextSource.studioFinalWriter,
  );
}

void main() {
  const assembler = ExtensionContextAssembler();

  test('same-main keeps exact provider context and appends canonical once', () {
    final snapshot = _snapshot(const [
      PromptMessage(role: 'system', content: 'exact main instruction'),
      PromptMessage(role: 'user', content: 'turn'),
    ]);
    final assembly = assembler.assemble(
      policy: const ExtensionContextPolicy(useMainModelContext: true),
      blockConfig: _block,
      chatMessages: [
        _chat('u1', 'user', 'turn'),
        _chat('a1', 'assistant', 'clean'),
      ],
      anchorMessageId: 'a1',
      character: _character,
      persona: null,
      systemInstruction: 'block instruction',
      supplementalInstruction: '',
      mainContextSnapshot: snapshot,
    );

    expect(assembly.reconstructed, isFalse);
    expect(assembly.messages.first['content'], 'exact main instruction');
    expect(
      assembly.messages
          .where((message) => message['role'] == 'assistant')
          .map((message) => message['content']),
      ['clean'],
    );
    expect(assembly.messages.last['content'], 'block instruction');
  });

  test('custom filtering honors categories and block message count', () {
    final snapshot = _snapshot(const [
      PromptMessage(role: 'system', content: 'card', blockId: 'char_card'),
      PromptMessage(
        role: 'system',
        content: 'lore',
        blockId: 'worldInfoBefore',
        isLorebook: true,
      ),
      PromptMessage(role: 'system', content: 'memory', blockId: 'memory'),
      PromptMessage(
        role: 'system',
        content: 'ledger',
        blockId: 'studio_session_state',
      ),
      PromptMessage(
        role: 'user',
        content: 'old',
        isHistory: true,
        sourceMessageId: 'u1',
      ),
      PromptMessage(
        role: 'user',
        content: 'latest',
        isHistory: true,
        sourceMessageId: 'u2',
      ),
    ]);
    final assembly = assembler.assemble(
      policy: const ExtensionContextPolicy(
        includeCharacterCard: false,
        includeLorebooks: true,
        includeMemoryBooks: false,
        includeStudioState: true,
      ),
      blockConfig: _block,
      chatMessages: [
        _chat('u2', 'user', 'latest'),
        _chat('a1', 'assistant', 'reply'),
      ],
      anchorMessageId: 'a1',
      character: _character,
      persona: null,
      systemInstruction: 'instruction',
      supplementalInstruction: '',
      mainContextSnapshot: snapshot,
    );
    final text = assembly.messages
        .map((message) => message['content'])
        .join('\n');
    expect(text, contains('lore'));
    expect(text, contains('ledger'));
    expect(text, contains('latest'));
    expect(text, isNot(contains('card')));
    expect(text, isNot(contains('memory')));
    expect(text, isNot(contains('old')));
  });

  test('custom filtering preserves interleaved depth order', () {
    final snapshot = _snapshot(const [
      PromptMessage(role: 'system', content: 'preset-before', blockId: 'main'),
      PromptMessage(
        role: 'user',
        content: 'old',
        isHistory: true,
        sourceMessageId: 'u1',
      ),
      PromptMessage(
        role: 'system',
        content: 'runtime-depth',
        blockId: 'runtime_prompt:r1',
        isDepth: true,
        depth: 1,
      ),
      PromptMessage(
        role: 'user',
        content: 'latest',
        isHistory: true,
        sourceMessageId: 'u2',
      ),
      PromptMessage(
        role: 'system',
        content: 'preset-after',
        blockId: 'main_after',
      ),
    ]);
    final assembly = assembler.assemble(
      policy: const ExtensionContextPolicy(
        includeMainPresetInstructions: true,
        includeRuntimePrompts: true,
      ),
      blockConfig: _block,
      chatMessages: [_chat('u2', 'user', 'latest')],
      anchorMessageId: 'u2',
      character: null,
      persona: null,
      systemInstruction: 'block',
      supplementalInstruction: '',
      mainContextSnapshot: snapshot,
    );

    expect(assembly.messages.map((message) => message['content']).toList(), [
      'preset-before',
      'runtime-depth',
      'latest',
      'preset-after',
      'block',
    ]);
  });

  test(
    'Studio custom policy reconstructs instead of filtering base prompt',
    () {
      final assembly = assembler.assemble(
        policy: const ExtensionContextPolicy(
          includeMainPresetInstructions: true,
        ),
        blockConfig: _block,
        chatMessages: [_chat('u1', 'user', 'actual chat')],
        anchorMessageId: 'u1',
        character: null,
        persona: null,
        systemInstruction: 'block',
        supplementalInstruction: '',
        mainContextSnapshot: _studioSnapshot(const [
          PromptMessage(role: 'system', content: 'base prompt, not final'),
        ]),
      );

      expect(assembly.reconstructed, isTrue);
      expect(
        assembly.messages.map((message) => message['content']),
        isNot(contains('base prompt, not final')),
      );
      expect(
        assembly.messages.map((message) => message['content']),
        contains('actual chat'),
      );
    },
  );

  test('reconstructed runtime prompts keep depth placement when enabled', () {
    final assembly = assembler.assemble(
      policy: const ExtensionContextPolicy(
        includeCharacterCard: false,
        includePersona: false,
        includeRuntimePrompts: true,
      ),
      blockConfig: _block.copyWith(contextMessageCount: -1),
      chatMessages: [
        _chat('u1', 'user', 'one'),
        _chat('a1', 'assistant', 'two'),
      ],
      anchorMessageId: 'a1',
      character: null,
      persona: null,
      systemInstruction: 'block',
      supplementalInstruction: '',
      runtimePromptMessages: const [
        PromptMessage(
          role: 'system',
          content: 'runtime',
          blockId: 'runtime_prompt:r1',
          depth: 1,
          isDepth: true,
        ),
      ],
    );

    expect(assembly.messages.map((message) => message['content']).toList(), [
      'one',
      'runtime',
      'two',
      'block',
    ]);
  });

  test(
    'legacy wire request keeps injected history in old two-message shape',
    () {
      final assembly = assembler.assemble(
        policy: const ExtensionContextPolicy(legacyPromptSemantics: true),
        blockConfig: _block,
        chatMessages: [
          _chat('u1', 'user', 'hello'),
          _chat(
            'a1',
            'assistant',
            'reply\n\n<loomledger>injected block</loomledger>',
          ),
        ],
        anchorMessageId: 'a1',
        character: _character,
        persona: null,
        systemInstruction: 'legacy system',
        supplementalInstruction: '',
        legacyUserContent:
            'Character: Alice\n\nRecent conversation:\n'
            'ASSISTANT: reply\n\n<loomledger>injected block</loomledger>',
      );

      expect(assembly.messages, hasLength(2));
      expect(assembly.messages.first, {
        'role': 'system',
        'content': 'legacy system',
      });
      expect(
        assembly.messages.last['content'],
        contains('<loomledger>injected block</loomledger>'),
      );
    },
  );

  test('missing same-main snapshot reconstructs without throwing', () {
    final assembly = assembler.assemble(
      policy: const ExtensionContextPolicy(useMainModelContext: true),
      blockConfig: _block,
      chatMessages: [
        _chat('u1', 'user', 'old'),
        _chat('a1', 'assistant', 'reply'),
      ],
      anchorMessageId: 'a1',
      character: _character,
      persona: null,
      systemInstruction: 'instruction',
      supplementalInstruction: '',
    );
    expect(assembly.reconstructed, isTrue);
    expect(assembly.messages.last['content'], 'instruction');
  });

  test('block history count limits reconstructed history', () {
    final assembly = assembler.assemble(
      policy: const ExtensionContextPolicy(),
      blockConfig: _block,
      chatMessages: [
        _chat('u1', 'user', 'old'),
        _chat('a1', 'assistant', 'reply'),
      ],
      anchorMessageId: 'a1',
      character: null,
      persona: null,
      systemInstruction: 'instruction',
      supplementalInstruction: '',
    );
    final text = assembly.messages
        .map((message) => message['content'])
        .join('\n');
    expect(text, contains('reply'));
    expect(text, isNot(contains('old')));
  });
}
