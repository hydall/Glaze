/// What a script block written for the original extension finds in scope.
///
/// The original runs a script with `eval` inside its own module, so the code
/// sees the extension's variables (`messageId`, `isUser`, `allBlocks`, …) and
/// SillyTavern's `context`. Glaze runs scripts in a sandbox, so the same
/// values are handed over as data under `context.extBlocks`; the sandbox's
/// compatibility layer (`assets/chat_webview/extblocks_compat.js`) turns them
/// back into those names.
library;

import '../../../../core/models/character.dart';
import '../../../../core/models/chat_message.dart';
import '../../../../core/models/persona.dart';
import '../../models/block_config.dart';
import '../../models/block_run_status.dart';
import '../../models/extension_preset.dart';
import '../../models/info_block.dart';
import '../block_content_extractor.dart';
import '../upstream_block_codec.dart';
import '../upstream_preset_codec.dart';

/// The `context.extBlocks` payload for a script run on [messageId].
///
/// - `messageId` is the message's index in `chat`, as in the original.
/// - `chat` holds every message in SillyTavern's shape (`mes`, `is_user`,
///   `name`), with the stored block states in `extra.extblocks`.
/// - Blocks are in the original's format: `blocks` holds every block of the
///   preset and the card, `allBlocks` the enabled ones, `triggeredBlocks` the
///   enabled ones that answer to this message's side.
Map<String, dynamic> extBlocksScriptScope({
  required ExtensionPreset? preset,
  required List<ChatMessage> messages,
  required String? messageId,
  required List<InfoBlock> rows,
  required Character? character,
  required Persona? persona,
  Map<String, String> additionalMacro = const {},
}) {
  final blocks = (preset?.blocks.toList() ?? <BlockConfig>[])
    ..sort((a, b) => a.order.compareTo(b.order));
  final byId = {for (final b in blocks) b.id: b};
  final index = messageId == null
      ? messages.length - 1
      : messages.indexWhere((m) => m.id == messageId);
  final anchor = index < 0 ? null : messages[index];
  final isUser = anchor?.role == 'user';
  final enabled = blocks.where((b) => b.enabled).toList();

  return {
    'messageId': index < 0 ? messages.length - 1 : index,
    'isUser': isUser,
    'is_separate': false,
    'blocks': blocks.map(encodeUpstreamBlock).toList(),
    'allBlocks': enabled.map(encodeUpstreamBlock).toList(),
    'triggeredBlocks': [
      for (final b in enabled)
        if (isUser ? b.triggerOnUser : b.triggerOnChar) encodeUpstreamBlock(b),
    ],
    'additionalMacro': additionalMacro,
    'currentSet': preset == null ? null : encodeUpstreamPreset(preset),
    'name1': persona?.name ?? 'User',
    'name2': character?.name ?? '',
    'characterId': character?.id,
    'chat': [
      for (final m in messages)
        {
          'name': m.role == 'user'
              ? persona?.name ?? 'User'
              : character?.name ?? '',
          'is_user': m.role == 'user',
          'is_system': m.role == 'system',
          'mes': m.content,
          'swipe_id': m.swipeId,
          'extra': {'extblocks': _storedBlocks(m, rows, byId)},
        },
    ],
  };
}

/// [message]'s finished block states on the swipe it shows, each in its tag
/// and in block order, as the original keeps them in `extra.extblocks`.
String _storedBlocks(
  ChatMessage message,
  List<InfoBlock> rows,
  Map<String, BlockConfig> byId,
) {
  final own =
      rows
          .where(
            (r) =>
                r.messageId == message.id &&
                r.swipeId == message.swipeId &&
                r.status == BlockRunStatus.done &&
                r.content.trim().isNotEmpty,
          )
          .toList()
        ..sort(
          (a, b) => (byId[a.blockId]?.order ?? a.order).compareTo(
            byId[b.blockId]?.order ?? b.order,
          ),
        );
  final seen = <String>{};
  return [
    for (final row in own)
      if (seen.add(row.blockId))
        switch (byId[row.blockId]) {
          final block? => wrapInBlockTag(block, row.content),
          null => row.content.trim(),
        },
  ].join('\n');
}
