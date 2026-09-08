import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/services/extension_context_assembler.dart';
import 'package:glaze_flutter/features/extensions/services/info_block_service.dart';

void main() {
  test('old JSON keeps legacy wire shape with injected block history', () {
    final preset = ExtensionPreset.fromJson({
      'id': 'old',
      'name': 'Old preset',
      'blocks': [
        {'id': 'block', 'name': 'ledger', 'contextMessageCount': 2},
      ],
    });
    final block = preset.blocks.single;
    final history = [
      const ChatMessage(id: 'u1', role: 'user', content: 'hello'),
      const ChatMessage(
        id: 'a1',
        role: 'assistant',
        content: 'reply\n\n<ledger>injected state</ledger>',
      ),
    ];
    final userContent = InfoBlockService.buildLegacyUserMessage(
      blockConfig: block,
      character: const Character(
        id: 'c1',
        name: 'Alice',
        description: 'Card text',
      ),
      persona: 'Bob',
      personaPrompt: 'Persona text',
      contextMessages: history,
      previousOutput: null,
    );
    final request = const ExtensionContextAssembler().assemble(
      policy: block.contextPolicy,
      blockConfig: block,
      chatMessages: history,
      anchorMessageId: 'a1',
      character: null,
      persona: null,
      systemInstruction: 'legacy system',
      supplementalInstruction: '',
      legacyUserContent: userContent,
    );

    expect(request.messages, hasLength(2));
    expect(request.messages.first, {
      'role': 'system',
      'content': 'legacy system',
    });
    expect(request.messages.last['role'], 'user');
    expect(request.messages.last['content'], contains('Character: Alice'));
    expect(request.messages.last['content'], contains('User Persona: Bob'));
    expect(
      request.messages.last['content'],
      contains('ASSISTANT: reply\n\n<ledger>injected state</ledger>'),
    );
  });
}
