import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/info_block.dart';
import 'package:glaze_flutter/features/extensions/services/info_block_injector.dart';

class _FakeInfoBlockReader implements InfoBlockReader {
  _FakeInfoBlockReader(this._byMessageId);

  final Map<String, List<InfoBlock>> _byMessageId;

  @override
  Future<List<InfoBlock>> getByMessageId(
    String sessionId,
    String messageId, {
    int swipeId = 0,
  }) async {
    return _byMessageId[messageId] ?? const [];
  }
}

InfoBlock _block({
  required String id,
  required String messageId,
  required String content,
}) {
  return InfoBlock(
    id: id,
    sessionId: 'sess1',
    messageId: messageId,
    blockId: 'cfg1',
    blockType: 'llm',
    blockName: 'loomledger',
    content: content,
    createdAt: 0,
    order: 0,
  );
}

void main() {
  group('InfoBlockInjector', () {
    test('appends each block only to its own assistant message', () async {
      const sessionId = 'sess1';
      final messages = [
        ChatMessage(id: 'u1', role: 'user', content: 'hi'),
        ChatMessage(id: 'a1', role: 'assistant', content: 'reply 1'),
        ChatMessage(id: 'u2', role: 'user', content: 'again'),
        ChatMessage(id: 'a2', role: 'assistant', content: 'reply 2'),
        ChatMessage(id: 'u3', role: 'user', content: 'third'),
        ChatMessage(id: 'a3', role: 'assistant', content: 'reply 3'),
      ];

      final repo = _FakeInfoBlockReader({
        'a1': [_block(id: 'b1', messageId: 'a1', content: 'ledger-1')],
        'a2': [_block(id: 'b2', messageId: 'a2', content: 'ledger-2')],
        'a3': [_block(id: 'b3', messageId: 'a3', content: 'ledger-3')],
      });

      final preset = ExtensionPreset(
        id: 'p1',
        name: 'test',
        createdAt: 0,
        blocks: [
          BlockConfig(
            id: 'cfg1',
            name: 'loomledger',
            enabled: true,
            inject: true,
            injectLastN: 3,
            template: '<loomledger>{{content}}</loomledger>',
          ),
        ],
      );

      final injector = InfoBlockInjector(repo);
      final result = await injector.injectBlocks(
        messages: messages,
        sessionId: sessionId,
        preset: preset,
      );

      expect(result[1].content, contains('reply 1'));
      expect(result[1].content, contains('ledger-1'));
      expect(result[1].content, isNot(contains('ledger-2')));
      expect(result[1].content, isNot(contains('ledger-3')));

      expect(result[3].content, contains('ledger-2'));
      expect(result[3].content, isNot(contains('ledger-1')));
      expect(result[3].content, isNot(contains('ledger-3')));

      expect(result[5].content, contains('ledger-3'));
      expect(result[5].content, isNot(contains('ledger-1')));
      expect(result[5].content, isNot(contains('ledger-2')));
    });

    test(
      'injectLastN limits how many assistant messages receive blocks',
      () async {
        const sessionId = 'sess1';
        final messages = [
          ChatMessage(id: 'a1', role: 'assistant', content: 'one'),
          ChatMessage(id: 'a2', role: 'assistant', content: 'two'),
          ChatMessage(id: 'a3', role: 'assistant', content: 'three'),
        ];

        final repo = _FakeInfoBlockReader({
          for (final id in ['a1', 'a2', 'a3'])
            id: [_block(id: 'b-$id', messageId: id, content: 'L-$id')],
        });

        const preset = ExtensionPreset(
          id: 'p1',
          name: 'test',
          createdAt: 0,
          blocks: [
            BlockConfig(
              id: 'cfg1',
              name: 'loomledger',
              enabled: true,
              inject: true,
              injectLastN: 2,
            ),
          ],
        );

        final injector = InfoBlockInjector(repo);
        final result = await injector.injectBlocks(
          messages: messages,
          sessionId: sessionId,
          preset: preset,
        );

        expect(result[0].content, 'one');
        expect(result[1].content, contains('L-a2'));
        expect(result[2].content, contains('L-a3'));
      },
    );

    test('injectPrefix is inserted between blank line and block', () async {
      const sessionId = 'sess1';
      const prefix =
          'This is block from agent. You do not need to generate the same; info only.';
      final messages = [
        ChatMessage(id: 'a1', role: 'assistant', content: 'reply'),
      ];

      final repo = _FakeInfoBlockReader({
        'a1': [_block(id: 'b1', messageId: 'a1', content: 'ledger-1')],
      });

      final preset = ExtensionPreset(
        id: 'p1',
        name: 'test',
        createdAt: 0,
        blocks: [
          BlockConfig(
            id: 'cfg1',
            name: 'loomledger',
            enabled: true,
            inject: true,
            injectLastN: 1,
            injectPrefix: prefix,
          ),
        ],
      );

      final injector = InfoBlockInjector(repo);
      final result = await injector.injectBlocks(
        messages: messages,
        sessionId: sessionId,
        preset: preset,
      );

      expect(
        result[0].content,
        'reply\n\n$prefix\n<loomledger>\nledger-1\n</loomledger>',
      );
    });

    test(
      'injectPrefix follows injectLastN and is not added to older messages',
      () async {
        const sessionId = 'sess1';
        const prefix = 'Reference block only.';
        final messages = [
          ChatMessage(id: 'a1', role: 'assistant', content: 'one'),
          ChatMessage(id: 'a2', role: 'assistant', content: 'two'),
          ChatMessage(id: 'a3', role: 'assistant', content: 'three'),
        ];

        final repo = _FakeInfoBlockReader({
          for (final id in ['a1', 'a2', 'a3'])
            id: [_block(id: 'b-$id', messageId: id, content: 'L-$id')],
        });

        const preset = ExtensionPreset(
          id: 'p1',
          name: 'test',
          createdAt: 0,
          blocks: [
            BlockConfig(
              id: 'cfg1',
              name: 'loomledger',
              enabled: true,
              inject: true,
              injectLastN: 1,
              injectPrefix: prefix,
            ),
          ],
        );

        final injector = InfoBlockInjector(repo);
        final result = await injector.injectBlocks(
          messages: messages,
          sessionId: sessionId,
          preset: preset,
        );

        expect(result[0].content, 'one');
        expect(result[1].content, 'two');
        expect(result[2].content, contains(prefix));
        expect(result[2].content, contains('L-a3'));
      },
    );

    test('injectPrefix is not injected when injectLastN is zero', () async {
      const sessionId = 'sess1';
      const prefix = 'Reference block only.';
      final messages = [
        ChatMessage(id: 'a1', role: 'assistant', content: 'one'),
      ];

      final repo = _FakeInfoBlockReader({
        'a1': [_block(id: 'b-a1', messageId: 'a1', content: 'L-a1')],
      });

      const preset = ExtensionPreset(
        id: 'p1',
        name: 'test',
        createdAt: 0,
        blocks: [
          BlockConfig(
            id: 'cfg1',
            name: 'loomledger',
            enabled: true,
            inject: true,
            injectLastN: 0,
            injectPrefix: prefix,
          ),
        ],
      );

      final injector = InfoBlockInjector(repo);
      final result = await injector.injectBlocks(
        messages: messages,
        sessionId: sessionId,
        preset: preset,
      );

      expect(result[0].content, 'one');
    });
  });
}
