import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/converters/no_assistant.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/openai_chat_transport.dart';
import 'package:glaze_flutter/core/models/api_config.dart';

PromptMessage _block(String role, String content) =>
    PromptMessage(role: role, content: content);

PromptMessage _history(String role, String content) =>
    PromptMessage(role: role, content: content, isHistory: true);

List<(String, String)> _shape(List<PromptMessage> messages) => [
  for (final m in messages) (m.role, m.content),
];

const _prefixed = NoAssistantOptions(
  userPrefix: 'User: ',
  charPrefix: 'Char: ',
);

void main() {
  group('applyNoAssistant', () {
    test('collapses history into one prefixed assistant message', () {
      final out = applyNoAssistant([
        _block('system', 'Main prompt'),
        _block('user', 'Card'),
        _history('assistant', 'Greeting'),
        _history('user', 'Hi'),
        _history('assistant', 'Hello'),
        _block('system', "Author's note"),
      ], _prefixed);

      expect(_shape(out), [
        ('system', 'Main prompt\nCard'),
        ('assistant', 'Char: Greeting\nUser: Hi\nChar: Hello'),
        ('system', "Author's note"),
      ]);
      expect(out[1].isHistory, isTrue);
      expect(out[1].blockId, noAssistantHistoryBlockId);
    });

    test('squashes consecutive messages of the squash role', () {
      final history = [
        _history('assistant', 'A1'),
        _history('assistant', 'A2'),
        _history('user', 'U1'),
        _history('user', 'U2'),
      ];

      expect(
        applyNoAssistant(history, _prefixed).single.content,
        'Char: A1\nA2\nUser: U1\nUser: U2',
      );
      expect(
        applyNoAssistant(
          history,
          const NoAssistantOptions(
            userPrefix: 'User: ',
            charPrefix: 'Char: ',
            squashRole: NoAssistantSquashRole.user,
          ),
        ).single.content,
        'Char: A1\nChar: A2\nUser: U1\nU2',
      );
      expect(
        applyNoAssistant(
          history,
          const NoAssistantOptions(
            userPrefix: 'User: ',
            charPrefix: 'Char: ',
            squashRole: NoAssistantSquashRole.none,
          ),
        ).single.content,
        'Char: A1\nChar: A2\nUser: U1\nUser: U2',
      );
    });

    test('keeps depth injections inline, unprefixed', () {
      final out = applyNoAssistant([
        _history('user', 'Hi'),
        const PromptMessage(
          role: 'system',
          content: '[Note]',
          isDepth: true,
          depth: 1,
        ),
        _history('assistant', 'Hello'),
      ], _prefixed);

      expect(_shape(out), [('assistant', 'User: Hi\n[Note]\nChar: Hello')]);
    });

    test('an injection breaks a squash run', () {
      final out = applyNoAssistant([
        _history('assistant', 'A1'),
        const PromptMessage(role: 'system', content: '[Note]', isDepth: true),
        _history('assistant', 'A2'),
      ], _prefixed);

      expect(out.single.content, 'Char: A1\n[Note]\nChar: A2');
    });

    test('assistant blocks stay separate and end a merge run', () {
      final out = applyNoAssistant([
        _block('system', 'S1'),
        _block('assistant', 'Example'),
        _block('user', 'S2'),
        _history('user', 'Hi'),
        _block('system', 'Post'),
        _block('assistant', 'Prefill'),
      ], _prefixed);

      expect(_shape(out), [
        ('system', 'S1'),
        ('assistant', 'Example'),
        ('system', 'S2'),
        ('assistant', 'User: Hi'),
        ('system', 'Post'),
        ('assistant', 'Prefill'),
      ]);
    });

    test('empty blocks never produce a message', () {
      final out = applyNoAssistant([
        _block('system', ''),
        _block('system', '  '),
        _history('user', 'Hi'),
      ], _prefixed);

      expect(_shape(out), [('assistant', 'User: Hi')]);
    });

    test('without history only the blocks are merged', () {
      final out = applyNoAssistant([
        _block('system', 'A'),
        _block('user', 'B'),
      ], _prefixed);

      expect(_shape(out), [('system', 'A\nB')]);
    });

    test('drops history attachments', () {
      final out = applyNoAssistant([
        const PromptMessage(
          role: 'user',
          content: 'Look',
          isHistory: true,
          imagePaths: ['/tmp/a.png'],
        ),
      ], _prefixed);

      expect(out.single.imagePaths, isEmpty);
    });

    test('does not mutate its input', () {
      final input = [_block('system', 'A'), _history('user', 'Hi')];
      final copy = _shape(input);
      applyNoAssistant(input, _prefixed);
      expect(_shape(input), copy);
    });
  });

  group('NoAssistantOptions.of', () {
    const custom = ApiConfig(
      id: 'c',
      protocol: LlmProtocol.customChatCompletion,
      noAssistant: true,
      noAssistantUserPrefix: 'U: ',
      noAssistantCharPrefix: 'C: ',
      noAssistantSquashRole: 'bogus',
      noAssistantStopString: 'U:',
    );

    test('is null when the mode is off', () {
      expect(
        NoAssistantOptions.of(custom.copyWith(noAssistant: false)),
        isNull,
      );
    });

    test('is null for every protocol but a custom endpoint', () {
      for (final protocol in [
        LlmProtocol.openai,
        LlmProtocol.openrouter,
        LlmProtocol.anthropic,
        LlmProtocol.gemini,
      ]) {
        expect(
          NoAssistantOptions.of(custom.copyWith(protocol: protocol)),
          isNull,
          reason: protocol,
        );
      }
    });

    test('reads the connection and normalizes the squash role', () {
      final options = NoAssistantOptions.of(custom)!;
      expect(options.userPrefix, 'U: ');
      expect(options.charPrefix, 'C: ');
      expect(options.squashRole, NoAssistantSquashRole.assistant);
      expect(options.stopString, 'U:');
    });
  });

  group('buildApiMessages', () {
    test('applies NoAssistant before building the provider list', () {
      final out = buildApiMessages([
        _block('system', 'Prompt'),
        _history('user', 'Hi'),
      ], noAssistant: _prefixed);

      expect(out, [
        {'role': 'system', 'content': 'Prompt'},
        {'role': 'assistant', 'content': 'User: Hi'},
      ]);
    });
  });

  group('stop string', () {
    const config = ApiConfig(
      id: 'c',
      protocol: LlmProtocol.customChatCompletion,
      noAssistant: true,
      noAssistantStopString: 'User:',
    );

    Map<String, dynamic> bodyFor(ApiConfig config) =>
        OpenAiChatTransport.buildBody(
          ChatTransportRequest.fromApiConfig(config, messages: const []),
          protocol: LlmProtocol.customChatCompletion,
        );

    test('goes out as the stop parameter', () {
      expect(bodyFor(config)['stop'], ['User:']);
    });

    test('is omitted when empty or when the mode is off', () {
      expect(
        bodyFor(config.copyWith(noAssistantStopString: '')),
        isNot(contains('stop')),
      );
      expect(
        bodyFor(config.copyWith(noAssistant: false)),
        isNot(contains('stop')),
      );
    });

    test('survives a message rewrite', () {
      final request = ChatTransportRequest.fromApiConfig(
        config,
        messages: const [],
      ).withMessages(const []);
      expect(request.stop, ['User:']);
    });
  });
}
