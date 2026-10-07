import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/block_context_item.dart';
import 'package:glaze_flutter/features/extensions/models/info_block.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/context_item_builder.dart';
import 'package:glaze_flutter/features/extensions/services/upstream_block_codec.dart';

const _character = Character(id: 'c1', name: 'Alice');

ChatMessage _msg(String id, String role, String content, {int swipeId = 0}) =>
    ChatMessage(id: id, role: role, content: content, swipeId: swipeId);

BlockConfig _block(List<BlockContextItem> context) =>
    BlockConfig(id: 'b1', name: 'fandom_guide_state', context: context);

InfoBlock _infoBlock(
  String messageId,
  String blockName,
  String content, {
  int swipeId = 0,
}) => InfoBlock(
  id: '$messageId-$blockName',
  sessionId: 's1',
  messageId: messageId,
  blockId: 'bid-$blockName',
  blockName: blockName,
  blockType: 'generated',
  content: content,
  createdAt: 0,
  swipeId: swipeId,
);

List<Map<String, dynamic>> _build({
  required BlockConfig blockConfig,
  required List<ChatMessage> messages,
  String anchorMessageId = '',
  Map<String, String> sessionVars = const {},
  Map<String, String> globalVars = const {},
  List<PresetRegex> promptRegexes = const [],
  Map<String, List<InfoBlock>> blocksByMessageId = const {},
  Character? character = _character,
  Persona? persona,
}) => buildContextItemMessages(
  blockConfig: blockConfig,
  messages: messages,
  anchorMessageId: anchorMessageId,
  character: character,
  persona: persona,
  sessionVars: sessionVars,
  globalVars: globalVars,
  promptRegexes: promptRegexes,
  blocksByMessageId: blocksByMessageId,
);

void main() {
  group('text items', () {
    test('expands macros and uses the item role', () {
      final out = _build(
        blockConfig: _block([
          const BlockContextItem(
            id: '1',
            type: ContextItemType.text,
            role: ContextItemRole.system,
            text: 'You are {{char}}.',
          ),
        ]),
        messages: const [],
      );

      expect(out, [
        {'role': 'system', 'content': 'You are Alice.'},
      ]);
    });

    test('disabled items are skipped', () {
      final out = _build(
        blockConfig: _block([
          const BlockContextItem(
            id: '1',
            type: ContextItemType.text,
            text: 'dropped',
            disabled: true,
          ),
          const BlockContextItem(id: '2', type: ContextItemType.text, text: 'kept'),
        ]),
        messages: const [],
      );

      expect(out, [
        {'role': 'user', 'content': 'kept'},
      ]);
    });
  });

  group('last_messages items', () {
    test('takes the last N up to the anchor with prefixes and separator', () {
      final messages = [
        _msg('u1', 'user', 'hello'),
        _msg('a1', 'assistant', 'hi there'),
        _msg('u2', 'user', 'bye'),
      ];
      final out = _build(
        blockConfig: _block([
          const BlockContextItem(
            id: '1',
            type: ContextItemType.lastMessages,
            messagesCount: 2,
            userPrefix: 'PLAYER: ',
          ),
        ]),
        messages: messages,
        anchorMessageId: 'u2',
      );

      expect(out, [
        {
          'role': 'user',
          'content': 'hi there\n\nPLAYER: bye',
        },
      ]);
    });

    test('respects a positive offset', () {
      final messages = [
        _msg('u1', 'user', 'one'),
        _msg('a1', 'assistant', 'two'),
        _msg('u2', 'user', 'three'),
      ];
      final out = _build(
        blockConfig: _block([
          const BlockContextItem(
            id: '1',
            type: ContextItemType.lastMessages,
            messagesCount: 3,
            messagesOffset: 1,
            messagesSeparator: MessagesSeparator.newline,
          ),
        ]),
        messages: messages,
        anchorMessageId: 'u2',
      );

      expect(out.single['content'], 'one\ntwo');
    });

    test('a keyword stopper derives its own count', () {
      final messages = [
        _msg('a0', 'assistant', 'old exchange'),
        _msg('u1', 'user', 'ignored'),
        _msg('a1', 'assistant', 'START here'),
        _msg('u2', 'user', 'tail'),
      ];
      final out = _build(
        blockConfig: _block([
          const BlockContextItem(
            id: '1',
            type: ContextItemType.lastMessagesKeyword,
            keywordStopper: 'START',
            messagesSeparator: MessagesSeparator.space,
          ),
        ]),
        messages: messages,
        anchorMessageId: 'u2',
      );

      expect(out.single['content'], 'START here tail');
    });
  });

  group('role grouping', () {
    test('merges consecutive same-role items and splits on role change', () {
      final out = _build(
        blockConfig: _block([
          const BlockContextItem(id: '1', type: ContextItemType.text, text: 'a'),
          const BlockContextItem(id: '2', type: ContextItemType.text, text: 'b'),
          const BlockContextItem(
            id: '3',
            type: ContextItemType.text,
            role: ContextItemRole.system,
            text: 'c',
          ),
        ]),
        messages: const [],
      );

      expect(out, [
        {'role': 'user', 'content': 'a\nb'},
        {'role': 'system', 'content': 'c'},
      ]);
    });
  });

  group('previous_block items', () {
    test('pulls earlier states newest-last and wraps them in the tag', () {
      final messages = [
        _msg('m0', 'assistant', ''),
        _msg('m1', 'assistant', ''),
        _msg('m2', 'assistant', ''),
      ];
      final out = _build(
        blockConfig: _block([
          const BlockContextItem(
            id: '1',
            type: ContextItemType.previousBlock,
            blockName: 'state',
            blockCount: 2,
          ),
        ]),
        messages: messages,
        anchorMessageId: 'm2',
        blocksByMessageId: {
          'm0': [_infoBlock('m0', 'state', 'A')],
          'm1': [_infoBlock('m1', 'state', 'B')],
        },
      );

      expect(out.single['content'], '<state>\nA\n</state>\n\n<state>\nB\n</state>');
    });

    test('an empty block name produces nothing', () {
      final out = _build(
        blockConfig: _block([
          const BlockContextItem(id: '1', type: ContextItemType.previousBlock),
        ]),
        messages: [_msg('m0', 'assistant', 'x')],
        anchorMessageId: 'm0',
      );

      expect(out, isEmpty);
    });
  });

  group('last_messages_by_block items', () {
    test('starts at the last message carrying the named block', () {
      final messages = [
        _msg('m0', 'assistant', 'with note'),
        _msg('m1', 'user', 'later'),
        _msg('m2', 'assistant', 'now'),
      ];
      final out = _build(
        blockConfig: _block([
          const BlockContextItem(
            id: '1',
            type: ContextItemType.lastMessagesByBlock,
            blockName: 'note',
            messagesSeparator: MessagesSeparator.space,
          ),
        ]),
        messages: messages,
        anchorMessageId: 'm2',
        blocksByMessageId: {
          'm0': [_infoBlock('m0', 'note', 'content')],
        },
      );

      expect(out.single['content'], 'with note later now');
    });
  });

  group('prompt regexes', () {
    test('the prompt pass runs per message', () {
      final out = _build(
        blockConfig: _block([
          const BlockContextItem(
            id: '1',
            type: ContextItemType.lastMessages,
            messagesCount: 1,
          ),
        ]),
        messages: [_msg('u1', 'user', 'bye')],
        anchorMessageId: 'u1',
        promptRegexes: const [
          PresetRegex(id: 'r1', name: 'bye', regex: 'bye', replacement: 'BYE'),
        ],
      );

      expect(out.single['content'], 'BYE');
    });

    test('a promptOnly script still runs in the prompt pass', () {
      final out = _build(
        blockConfig: _block([
          const BlockContextItem(
            id: '1',
            type: ContextItemType.lastMessages,
            messagesCount: 1,
          ),
        ]),
        messages: [_msg('u1', 'user', 'bye')],
        anchorMessageId: 'u1',
        promptRegexes: const [
          PresetRegex(
            id: 'r1',
            name: 'bye',
            regex: 'bye',
            replacement: 'BYE',
            promptOnly: true,
          ),
        ],
      );

      expect(out.single['content'], 'BYE');
    });
  });

  group('image blocks', () {
    const instruction = '{"prompt":"a red door"}';
    const finished =
        '[IMG:RESULT:generated/a.png;;*generated/b.png|$instruction]';

    test('chat messages carry the instruction, not the stored files', () {
      final out = _build(
        blockConfig: _block([
          const BlockContextItem(
            id: '1',
            type: ContextItemType.lastMessages,
            messagesCount: 1,
          ),
        ]),
        messages: [_msg('a1', 'assistant', 'She opens it. $finished')],
        anchorMessageId: 'a1',
      );

      expect(out.single['content'], 'She opens it. [IMG:GEN:$instruction]');
    });

    test('a previous block carries the instruction, not the stored files', () {
      final out = _build(
        blockConfig: _block([
          const BlockContextItem(
            id: '1',
            type: ContextItemType.previousBlock,
            blockName: 'naicom',
          ),
        ]),
        messages: [
          _msg('a1', 'assistant', 'one'),
          _msg('a2', 'assistant', 'two'),
        ],
        anchorMessageId: 'a2',
        blocksByMessageId: {
          'a1': [_infoBlock('a1', 'naicom', finished)],
        },
      );

      expect(
        out.single['content'],
        '<naicom>\n[IMG:GEN:$instruction]\n</naicom>',
      );
    });
  });

  // The context list of the naicom block (an image-prompt writer for NovelAI)
  // as exported by the original extension: appearance reaches the model only
  // through {{persona}} and {{description}} in its text items.
  test('an imported image-prompt block gets both appearances', () {
    final config = decodeUpstreamBlock({
      'id': 'naicom',
      'name': 'naicom',
      'block_type': 'generated',
      'prompt': 'Create a prompt for ONE comic page.',
      'template': '<naicom>\n...\n</naicom>\n',
      'context': [
        {
          'id': '1',
          'name': 'chat',
          'role': 'user',
          'type': 'last_messages',
          'messages_count': 2,
          'messages_offset': 0,
          'messages_separator': 'double_newline',
        },
        {
          'id': '2',
          'name': 'block',
          'role': 'system',
          'type': 'previous_block',
          'block_name': '',
          'block_count': 1,
        },
        {
          'id': '3',
          'name': '{{user}}',
          'role': 'user',
          'type': 'text',
          'text': 'Appearance of {{user}}:\n{{persona}}',
        },
        {
          'id': '4',
          'name': '{{char}}',
          'role': 'user',
          'type': 'text',
          'text': 'Appearance of {{char}}:\n{{description}}',
        },
      ],
    });

    final out = _build(
      blockConfig: config,
      messages: [
        _msg('u1', 'user', 'Hi.'),
        _msg('a1', 'assistant', 'Hello.'),
      ],
      anchorMessageId: 'a1',
      character: const Character(
        id: 'c1',
        name: 'Rhea',
        description: 'red hair, green eyes',
      ),
      persona: const Persona(id: 'p1', name: 'Alex', prompt: 'tall, glasses'),
    );

    expect(out, hasLength(1));
    final content = out.single['content'] as String;
    expect(content, contains('Appearance of Alex:\ntall, glasses'));
    expect(content, contains('Appearance of Rhea:\nred hair, green eyes'));
    expect(content, isNot(contains('{{')));
  });
}
