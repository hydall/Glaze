import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/block_context_item.dart';
import 'package:glaze_flutter/features/extensions/models/block_injection.dart';
import 'package:glaze_flutter/features/extensions/models/block_modes.dart';
import 'package:glaze_flutter/features/extensions/models/connection_profiles.dart';
import 'package:glaze_flutter/features/extensions/services/upstream_block_codec.dart';

/// A real block exported by the original ExtBlocks extension. The prompt and
/// template bodies are shortened — the codec never looks inside them — but
/// every key, type and value is exactly as the original wrote them, including
/// the absent `apply_regex` that an older export leaves out.
Map<String, dynamic> upstreamImageLiteExport() => {
  'id': '21ff7fb6-aec7-418d-8bad-41a6e7ba1766',
  'name': 'image_lite',
  'block_type': 'generated',
  'disabled': true,
  'user_message': false,
  'char_message': true,
  'template': '<image_lite> \n...\n</image_lite>\n',
  'prompt': 'Rules:\n- Output ONLY the exact <image_lite> template structure.',
  'generation_pause': false,
  'period': 1,
  'keyword': '',
  'keyword_is_regex': false,
  'hide_display': false,
  'inject_block': true,
  'injection_role': 0,
  'injection_position': 1,
  'injection_depth': 1,
  'generation_order': 'before',
  'background': false,
  'context': [
    {
      'id': '0d4cedf7-ab92-4fe1-9b6b-6aeb1fd3ec52',
      'name': 'chat',
      'role': 'user',
      'type': 'last_messages',
      'disabled': false,
      'messages_count': 5,
      'messages_offset': 0,
      'messages_separator': 'double_newline',
      'user_prefix': '',
      'user_suffix': '',
      'char_prefix': '',
      'char_suffix': '',
    },
    {
      'id': '52478b01-2f24-458f-94ff-c4b0b71edb79',
      'name': 'block',
      'role': 'system',
      'type': 'previous_block',
      'disabled': false,
      'block_name': '',
      'block_count': 1,
    },
    {
      'id': 'c6b49830-fd88-466a-bc0d-dc13c93fbb71',
      'name': '{{user}}',
      'role': 'user',
      'type': 'text',
      'disabled': false,
      'text': 'Внешность {{user}}: \n{{persona}}',
    },
    {
      'id': 'd25e5642-2f8c-478c-b554-16e65dcd434d',
      'name': '{{char}}',
      'role': 'user',
      'type': 'text',
      'disabled': false,
      'text': '{{char}} внешность: {{description}}',
    },
  ],
  'api_preset': 'big',
};

void main() {
  group('decodeUpstreamBlock — real export', () {
    late BlockConfig block;

    setUp(() => block = decodeUpstreamBlock(upstreamImageLiteExport()));

    test('keeps identity and maps the type tag', () {
      expect(block.id, '21ff7fb6-aec7-418d-8bad-41a6e7ba1766');
      expect(block.name, 'image_lite');
      expect(block.type, BlockType.infoblock);
    });

    test('inverts disabled into enabled', () {
      expect(block.enabled, isFalse);
    });

    test('carries both trigger flags independently', () {
      expect(block.triggerOnUser, isFalse);
      expect(block.triggerOnChar, isTrue);
      // A char-triggered block has to land on the chain our pipeline runs.
      expect(block.trigger, BlockTrigger.afterAssistant);
    });

    test('reads periodicity and keyword settings', () {
      expect(block.period, 1);
      expect(block.keyword, isEmpty);
      expect(block.keywordIsRegex, isFalse);
      expect(block.generationPause, isFalse);
    });

    test('maps numeric injection settings onto their enums', () {
      expect(block.inject, isTrue);
      expect(block.injectionRole, InjectionRole.system);
      expect(block.injectionPosition, InjectionPosition.inChat);
      expect(block.injectionDepth, 1);
      expect(block.hideDisplay, isFalse);
    });

    test('reads ordering, background and the API preset', () {
      expect(block.generationOrder, BlockRunOrder.before);
      expect(block.background, isFalse);
      expect(block.apiPreset, ConnectionProfile.big);
    });

    test('defaults apply_regex when the export predates it', () {
      expect(block.applyRegex, isFalse);
    });

    test('keeps the prompt and template verbatim', () {
      expect(block.template, '<image_lite> \n...\n</image_lite>\n');
      expect(block.prompt, startsWith('Rules:'));
    });
  });

  group('decodeUpstreamBlock — context items', () {
    late List<BlockContextItem> context;

    setUp(() => context = decodeUpstreamBlock(upstreamImageLiteExport()).context);

    test('keeps every item in the original order', () {
      expect(context, hasLength(4));
      expect(
        context.map((item) => item.name),
        ['chat', 'block', '{{user}}', '{{char}}'],
      );
    });

    test('reads a last_messages item', () {
      final item = context[0];
      expect(item.type, ContextItemType.lastMessages);
      expect(item.role, ContextItemRole.user);
      expect(item.messagesCount, 5);
      expect(item.messagesOffset, 0);
      expect(item.messagesSeparator, MessagesSeparator.doubleNewline);
      expect(item.disabled, isFalse);
    });

    test('reads a previous_block item', () {
      final item = context[1];
      expect(item.type, ContextItemType.previousBlock);
      expect(item.role, ContextItemRole.system);
      expect(item.blockCount, 1);
      expect(item.blockName, isEmpty);
      // A previous_block item has no message count in the original format.
      expect(item.messagesCount, isNull);
    });

    test('reads a text item including macros and non-ASCII text', () {
      final item = context[2];
      expect(item.type, ContextItemType.text);
      expect(item.text, 'Внешность {{user}}: \n{{persona}}');
    });
  });

  group('encodeUpstreamBlock', () {
    test('round-trips every key the original export carries', () {
      final source = upstreamImageLiteExport();
      final encoded = encodeUpstreamBlock(decodeUpstreamBlock(source));

      for (final key in source.keys) {
        expect(
          encoded[key],
          source[key],
          reason: 'key "$key" changed across a decode/encode round trip',
        );
      }
    });

    test('adds only the key the source export was missing', () {
      final source = upstreamImageLiteExport();
      final encoded = encodeUpstreamBlock(decodeUpstreamBlock(source));

      expect(
        encoded.keys.toSet().difference(source.keys.toSet()),
        {'apply_regex'},
      );
    });

    test('writes context items with their own type keys only', () {
      final encoded = encodeUpstreamBlock(
        decodeUpstreamBlock(upstreamImageLiteExport()),
      );
      final context = encoded['context'] as List;

      expect((context[0] as Map).keys, isNot(contains('block_count')));
      expect((context[1] as Map).keys, isNot(contains('messages_separator')));
      expect((context[2] as Map).keys, isNot(contains('block_name')));
    });

    test('a script block carries no injection settings', () {
      final encoded = encodeUpstreamBlock(
        decodeUpstreamBlock({
          'name': 'ticker',
          'block_type': 'script',
          'script_type': 'js',
          'script': 'return 1;',
          'swipe': true,
          'execution_order': 'after',
        }),
      );

      expect(encoded['block_type'], 'script');
      expect(encoded['script_type'], 'js');
      expect(encoded['swipe'], isTrue);
      expect(encoded['execution_order'], 'after');
      expect(encoded.keys, isNot(contains('injection_role')));
      expect(encoded.keys, isNot(contains('context')));
    });

    test('an accumulation block carries its updater and injection keys', () {
      final encoded = encodeUpstreamBlock(
        decodeUpstreamBlock({
          'name': 'state',
          'block_type': 'accumulation',
          'updater_name': 'state_update',
          'injection_position': 2,
        }),
      );

      expect(encoded['updater_name'], 'state_update');
      expect(encoded['injection_position'], 2);
      expect(encoded.keys, isNot(contains('prompt')));
      expect(encoded.keys, isNot(contains('period')));
    });

    test('a rewrite block carries its mode', () {
      final encoded = encodeUpstreamBlock(
        decodeUpstreamBlock({
          'name': 'polish',
          'block_type': 'rewrite',
          'rewrite_mode': 'search_replace',
          'generation_order': 'after',
        }),
      );

      expect(encoded['rewrite_mode'], 'search_replace');
      expect(encoded['generation_order'], 'after');
    });
  });

  group('decodeUpstreamBlock — tolerance', () {
    test('accepts numbers written as strings', () {
      final block = decodeUpstreamBlock({
        'name': 'x',
        'block_type': 'generated',
        'period': '3',
        'injection_depth': '-2',
        'injection_role': '2',
        'injection_position': '1',
      });

      expect(block.period, 3);
      expect(block.injectionDepth, -2);
      expect(block.injectionRole, InjectionRole.assistant);
      expect(block.injectionPosition, InjectionPosition.inChat);
    });

    test('falls back to the original defaults when keys are missing', () {
      final block = decodeUpstreamBlock({'name': 'bare'});

      expect(block.type, BlockType.infoblock);
      expect(block.enabled, isTrue);
      expect(block.period, 2);
      expect(block.injectionDepth, 4);
      expect(block.injectionRole, InjectionRole.system);
      expect(block.injectionPosition, InjectionPosition.afterMainPrompt);
      expect(block.apiPreset, ConnectionProfile.big);
      expect(block.context, isEmpty);
    });

    test('never leaves period at zero, which the trigger check divides by', () {
      expect(decodeUpstreamBlock({'name': 'x', 'period': 0}).period, 2);
    });

    test('mints an id when the export has none', () {
      expect(decodeUpstreamBlock({'name': 'x'}).id, isNotEmpty);
    });

    test('ignores a context entry that is not an object', () {
      final block = decodeUpstreamBlock({
        'name': 'x',
        'context': ['nonsense', 42],
      });
      expect(block.context, isEmpty);
    });
  });

  group('looksLikeUpstreamBlock', () {
    test('recognises an export from the original extension', () {
      expect(looksLikeUpstreamBlock(upstreamImageLiteExport()), isTrue);
    });

    test('does not claim one of our own blocks', () {
      expect(
        looksLikeUpstreamBlock(
          const BlockConfig(id: 'a', name: 'ours').toJson(),
        ),
        isFalse,
      );
    });
  });
}
