import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/block_run_status.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/info_block.dart';
import 'package:glaze_flutter/features/extensions/models/preset_permissions.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/ext_blocks_script_scope.dart';
import 'package:glaze_flutter/features/extensions/services/ext_blocks_script_api.dart';
import 'package:glaze_flutter/features/extensions/services/js_bridge_service.dart';

import '../helpers/js_bridge_test_support.dart';

InfoBlock _row(
  String messageId,
  String blockId,
  String content, {
  int swipe = 0,
}) => InfoBlock(
  id: '$messageId-$blockId-$swipe',
  sessionId: 's',
  messageId: messageId,
  swipeId: swipe,
  blockId: blockId,
  blockName: blockId,
  blockType: 'generated',
  content: content,
  createdAt: 1,
);

void main() {
  test(
    'a script sees the chat, its message and the blocks as the original',
    () {
      const preset = ExtensionPreset(
        id: 'p',
        name: 'Set',
        blocks: [
          BlockConfig(id: 'stats', name: 'stats', order: 0),
          BlockConfig(
            id: 'mood',
            name: 'mood',
            order: 1,
            triggerOnUser: true,
            triggerOnChar: false,
          ),
          BlockConfig(id: 'off', name: 'off', order: 2, enabled: false),
        ],
      );
      final scope = extBlocksScriptScope(
        preset: preset,
        messages: const [
          ChatMessage(id: 'm0', role: 'user', content: 'Hi'),
          ChatMessage(
            id: 'm1',
            role: 'assistant',
            content: 'Hello',
            swipeId: 1,
          ),
        ],
        messageId: 'm1',
        rows: [
          _row('m1', 'mood', 'calm', swipe: 1),
          _row('m1', 'stats', '<stats>\nhp 3\n</stats>', swipe: 1),
          _row('m1', 'stats', 'old swipe'),
          _row('m1', 'off', 'never').copyWith(status: BlockRunStatus.error),
        ],
        character: const Character(id: 'c', name: 'Mira'),
        persona: const Persona(id: 'u', name: 'Ann'),
        additionalMacro: const {'fruit': 'apple'},
      );

      expect(scope['messageId'], 1);
      expect(scope['isUser'], isFalse);
      expect((scope['blocks'] as List).map((b) => b['name']), [
        'stats',
        'mood',
        'off',
      ]);
      expect((scope['allBlocks'] as List).map((b) => b['name']), [
        'stats',
        'mood',
      ]);
      expect((scope['triggeredBlocks'] as List).map((b) => b['name']), [
        'stats',
      ]);
      expect(scope['additionalMacro'], {'fruit': 'apple'});
      expect(scope['name1'], 'Ann');
      expect(scope['name2'], 'Mira');

      final chat = scope['chat'] as List;
      expect(chat[0], containsPair('is_user', true));
      expect(chat[0], containsPair('name', 'Ann'));
      expect(chat[1], containsPair('mes', 'Hello'));
      expect(chat[1], containsPair('name', 'Mira'));
      // Only the swipe the message shows, finished, in block order, in tags.
      expect(
        (chat[1]['extra'] as Map)['extblocks'],
        '<stats>\nhp 3\n</stats>\n<mood>\ncalm\n</mood>',
      );
      expect((chat[0]['extra'] as Map)['extblocks'], '');
    },
  );

  test('without a message the script runs on the last one', () {
    final scope = extBlocksScriptScope(
      preset: null,
      messages: const [
        ChatMessage(id: 'a', role: 'assistant', content: 'x'),
        ChatMessage(id: 'b', role: 'user', content: 'y'),
      ],
      messageId: null,
      rows: const [],
      character: null,
      persona: null,
    );
    expect(scope['messageId'], 1);
    expect(scope['isUser'], isTrue);
    expect(scope['blocks'], isEmpty);
  });

  group('bridge', () {
    test('every script-API method needs the run-blocks permission', () async {
      expect(const PresetPermissions().runBlocks, isFalse);
      for (final method in ExtBlocksScriptMethods.all) {
        expect(
          JsBridgeMethodRegistry.lookup(method)?.capabilityFor(const {}),
          'run_blocks',
          reason: method,
        );
      }

      final calls = <String>[];
      Future<Object?> handler(
        String method,
        Map<String, dynamic> params,
        Map<String, dynamic> context,
      ) async {
        calls.add('$method ${params['blocks']} ${context['sessionId']}');
        return 'ok';
      }

      final denied = await TestJsBridge.create(extBlocks: handler).dispatch({
        'method': 'extBlocksRun',
        'params': {
          'blocks': ['stats'],
        },
      });
      expect(denied['ok'], isFalse);
      expect(calls, isEmpty);

      final granted =
          await TestJsBridge.create(
            permissionCheck: (id) => id == 'run_blocks',
            extBlocks: handler,
          ).dispatch({
            'method': 'extBlocksRun',
            'params': {
              'blocks': ['stats'],
            },
            'context': {'sessionId': 's1'},
          });
      expect(granted, {'ok': true, 'result': 'ok'});
      expect(calls, ['extBlocksRun [stats] s1']);
    });

    test('a host without the script API says so', () async {
      final response = await TestJsBridge.create(
        permissionCheck: (_) => true,
      ).dispatch({'method': 'extBlocksAbort'});
      expect(response['ok'], isFalse);
      expect((response['error'] as Map)['code'], 'unsupported_method');
    });
  });
}
