import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../extensions/models/extension_preset.dart';
import '../../extensions/models/info_block.dart';
import '../../extensions/providers/info_blocks_provider.dart';
import '../../extensions/services/card_blocks.dart';
import '../../extensions/services/ext_blocks_inline_display.dart';

/// What runs in [charId]'s chat: the active ExtBlocks preset with the card's
/// blocks in it, or `null` when no preset is picked.
ExtensionPreset? activeExtBlocksPreset(WidgetRef ref, String? charId) =>
    effectiveExtBlocksPreset(ref.read, charId);

/// What the bridge appends to a message of [sessionId] when it maps it for
/// display: its finished in-message ExtBlocks.
String Function(ChatMessage message) inlineExtBlocksReader(
  WidgetRef ref,
  String? sessionId, {
  String? charId,
}) {
  return (message) {
    if (sessionId == null || sessionId.isEmpty) return '';
    return inlineExtBlocksText(
      preset: activeExtBlocksPreset(ref, charId),
      rows: ref.read(infoBlocksProvider(sessionId)),
      message: message,
    );
  };
}

/// The messages whose in-message ExtBlocks text differs between the block
/// rows [prev] and [next], which need their text shown again.
List<ChatMessage> messagesWithChangedInlineBlocks({
  required ExtensionPreset? preset,
  required List<ChatMessage> messages,
  required List<InfoBlock> prev,
  required List<InfoBlock> next,
}) {
  if (preset == null || !preset.blocks.any(showsInMessage)) return const [];
  final touched = {
    for (final row in prev) row.messageId,
    for (final row in next) row.messageId,
  };
  return [
    for (final message in messages)
      if (touched.contains(message.id) &&
          inlineExtBlocksText(preset: preset, rows: prev, message: message) !=
              inlineExtBlocksText(preset: preset, rows: next, message: message))
        message,
  ];
}

/// What of [preset] decides the in-message ExtBlocks text; a change to it
/// means every message has to be shown again.
String inlineExtBlocksSignature(ExtensionPreset? preset) {
  if (preset == null) return '';
  return [
    for (final b in preset.blocks)
      if (b.enabled && showsInMessage(b))
        '${b.id}|${b.name}|${b.template}|${b.order}',
  ].join('\n');
}
