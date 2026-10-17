import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_message_mapper.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_webview_inline_ext_blocks.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/block_modes.dart';
import 'package:glaze_flutter/features/extensions/models/block_run_status.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/info_block.dart';
import 'package:glaze_flutter/features/extensions/services/ext_blocks_inline_display.dart';
import 'package:glaze_flutter/features/extensions/services/upstream_block_codec.dart';

InfoBlock _row(
  String blockId,
  String content, {
  String messageId = 'm',
  int swipeId = 0,
  int agentSwipeId = -1,
  BlockRunStatus status = BlockRunStatus.done,
}) => InfoBlock(
  id: '$blockId-$messageId-$swipeId-$agentSwipeId',
  sessionId: 's',
  messageId: messageId,
  swipeId: swipeId,
  agentSwipeId: agentSwipeId,
  blockId: blockId,
  blockName: blockId,
  blockType: 'generated',
  content: content,
  createdAt: 0,
  status: status,
);

void main() {
  const inline = BlockConfig(
    id: 'info',
    name: 'info',
    render: BlockRender.message,
    order: 1,
  );
  final preset = ExtensionPreset(
    id: 'p',
    name: 'p',
    blocks: [
      inline,
      inline.copyWith(id: 'first', name: 'first', order: 0),
      inline.copyWith(id: 'hidden', name: 'hidden', hideDisplay: true),
      const BlockConfig(id: 'card', name: 'card'),
    ],
  );
  const message = ChatMessage(id: 'm', role: 'assistant', content: 'Reply');

  test('finished in-message blocks in preset order, each in its tag', () {
    final text = inlineExtBlocksText(
      preset: preset,
      rows: [
        _row('info', 'Mood: calm'),
        _row('first', '<first>kept</first>'),
        _row('hidden', 'secret'),
        _row('card', 'in the panel'),
        _row('info', 'other message', messageId: 'x'),
      ],
      message: message,
    );
    expect(text, '<first>kept</first>\n<info>\nMood: calm\n</info>');
  });

  test('skips unfinished rows and other swipes', () {
    expect(
      inlineExtBlocksText(
        preset: preset,
        rows: [
          _row('info', 'running', status: BlockRunStatus.running),
          _row('first', 'other swipe', swipeId: 1),
        ],
        message: message,
      ),
      '',
    );
  });

  test('prefers the sub-swipe the message shows, else the plain one', () {
    final cleaned = message.copyWith(agentSwipeId: 2);
    final rows = [
      _row('info', 'plain'),
      _row('info', 'cleaned', agentSwipeId: 2),
    ];
    expect(
      inlineExtBlocksText(preset: preset, rows: rows, message: cleaned),
      contains('cleaned'),
    );
    expect(
      inlineExtBlocksText(
        preset: preset,
        rows: [_row('info', 'plain')],
        message: cleaned,
      ),
      contains('plain'),
    );
  });

  test('the mapper shows the blocks after the text but keeps the source', () {
    final map = ChatMessageMapper.toMap(
      message,
      const ChatMessageMapperContext(isGenerating: false),
      inlineExtBlocks: '<info>\nx\n</info>',
    );
    expect(map['text'], 'Reply\n<info>\nx\n</info>');
    expect(map['sourceText'], 'Reply');
  });

  test('only messages whose in-message text changed are shown again', () {
    final changed = messagesWithChangedInlineBlocks(
      preset: preset,
      messages: [
        message,
        message.copyWith(id: 'x'),
      ],
      prev: [_row('card', 'a')],
      next: [_row('card', 'b'), _row('info', 'new')],
    );
    expect(changed.map((m) => m.id), ['m']);
    expect(
      inlineExtBlocksSignature(preset),
      isNot(inlineExtBlocksSignature(preset.copyWith(blocks: const []))),
    );
  });

  test('a block imported from the original is shown in the message', () {
    final block = decodeUpstreamBlock({
      'name': 'info',
      'block_type': 'generated',
    });
    expect(block.render, BlockRender.message);
    expect(showsInMessage(block), isTrue);
    expect(showsInMessage(block.copyWith(hideDisplay: true)), isFalse);
  });

  test('accumulation state goes in the message; a script never does', () {
    final accumulation = decodeUpstreamBlock({
      'name': 'stats',
      'block_type': 'accumulation',
      'updater_name': 'stats_update',
    });
    final script = decodeUpstreamBlock({
      'name': 'js',
      'block_type': 'script',
      'script_type': 'js',
      'script': 'return 1',
    });
    expect(showsInMessage(accumulation), isTrue);
    expect(script.render, BlockRender.card);
    expect(
      showsInMessage(script.copyWith(render: BlockRender.message)),
      isFalse,
    );

    final text = inlineExtBlocksText(
      preset: ExtensionPreset(id: 'p', name: 'p', blocks: [accumulation]),
      rows: [_row(accumulation.id, 'gold: 3')],
      message: message,
    );
    expect(text, '<stats>\ngold: 3\n</stats>');
  });
}
