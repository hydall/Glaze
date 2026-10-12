import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/converters/no_assistant.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/openai_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/anthropic_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/gemini_chat_transport.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/preset.dart';

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
    const preset = Preset(
      id: 'p',
      name: 'P',
      noAssistant: true,
      userPrefix: '{{user}}: ',
      charPrefix: '{{char}}: ',
      squashRole: 'bogus',
      mergeRole: 'bogus',
      stopString: '\n{{user}}:',
    );

    NoAssistantOptions? of(Preset? preset) =>
        NoAssistantOptions.of(preset, charName: 'Alice', userName: 'Bob');

    test('is null when the mode is off or there is no preset', () {
      expect(of(preset.copyWith(noAssistant: false)), isNull);
      expect(of(null), isNull);
    });

    test('expands macros in the prefixes and the stop string', () {
      final options = of(preset)!;
      expect(options.userPrefix, 'Bob: ');
      expect(options.charPrefix, 'Alice: ');
      expect(options.stopString, '\nBob:');
      expect(options.stop, ['\nBob:']);
    });

    test('normalizes the roles', () {
      final options = of(preset)!;
      expect(options.squashRole, NoAssistantSquashRole.assistant);
      expect(options.mergeRole, 'system');
      // Vue offered `system`, which squashed nothing.
      expect(
        of(preset.copyWith(squashRole: 'system'))!.squashRole,
        NoAssistantSquashRole.none,
      );
    });

    test('an empty stop string sends no stop', () {
      expect(of(preset.copyWith(stopString: ''))!.stop, isEmpty);
    });
  });

  group('merge role', () {
    test('merged preset blocks take the preset merge role', () {
      final out = applyNoAssistant([
        _block('system', 'Main'),
        _block('user', 'Card'),
        _history('user', 'Hi'),
      ], const NoAssistantOptions(mergeRole: 'user'));
      expect(_shape(out), [('user', 'Main\nCard'), ('assistant', 'Hi')]);
    });
  });

  group('Preset JSON', () {
    test('reads the Vue keys and their defaults', () {
      final preset = Preset.fromJson({
        'id': 'p',
        'name': 'P',
        'noAssistant': true,
        'stopString': 'User:',
        'userPrefix': 'User: ',
        'charPrefix': 'Char: ',
        'squashRole': '',
        'mergeRole': '',
      });
      expect(preset.noAssistant, isTrue);
      expect(preset.stopString, 'User:');
      expect(preset.userPrefix, 'User: ');
      expect(preset.charPrefix, 'Char: ');
      expect(preset.squashRole, 'assistant');
      expect(preset.mergeRole, 'system');
      expect(Preset.fromJson(preset.toJson()), preset);
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
    const options = NoAssistantOptions(stopString: 'Bob:');

    ChatTransportRequest request() => ChatTransportRequest.fromApiConfig(
      const ApiConfig(id: 'c', protocol: LlmProtocol.customChatCompletion),
      messages: const [],
      stop: options.stop,
    );

    test('goes out as the stop parameter of every protocol that has one', () {
      expect(
        OpenAiChatTransport.buildBody(
          request(),
          protocol: LlmProtocol.customChatCompletion,
        )['stop'],
        ['Bob:'],
      );
      expect(
        AnthropicChatTransport.buildRequest(request()).body['stop_sequences'],
        ['Bob:'],
      );
      expect(
        (GeminiChatTransport.buildRequest(request()).body['generationConfig']
            as Map)['stopSequences'],
        ['Bob:'],
      );
    });

    test('is omitted when empty', () {
      final body = OpenAiChatTransport.buildBody(
        ChatTransportRequest.fromApiConfig(
          const ApiConfig(id: 'c'),
          messages: const [],
        ),
        protocol: LlmProtocol.customChatCompletion,
      );
      expect(body, isNot(contains('stop')));
    });

    test('survives a message rewrite', () {
      expect(request().withMessages(const []).stop, ['Bob:']);
    });
  });
}
