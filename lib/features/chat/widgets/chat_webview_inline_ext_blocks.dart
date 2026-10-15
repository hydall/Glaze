import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../extensions/models/extension_preset.dart';
import '../../extensions/models/info_block.dart';
import '../../extensions/providers/extension_presets_provider.dart';
import '../../extensions/providers/extensions_settings_provider.dart';
import '../../extensions/providers/info_blocks_provider.dart';
import '../../extensions/services/ext_blocks_inline_display.dart';

/// The active ExtBlocks preset, or `null` when none is picked.
ExtensionPreset? activeExtBlocksPreset(WidgetRef ref) {
  final id = ref.read(extensionsSettingsProvider).activePresetId;
  if (id == null || id.isEmpty) return null;
  return ref.read(extensionPresetsProvider).firstWhereOrNull((p) => p.id == id);
}

/// What the bridge appends to a message of [sessionId] when it maps it for
/// display: its finished in-message ExtBlocks.
String Function(ChatMessage message) inlineExtBlocksReader(
  WidgetRef ref,
  String? sessionId,
) {
  return (message) {
    if (sessionId == null || sessionId.isEmpty) return '';
    return inlineExtBlocksText(
      preset: activeExtBlocksPreset(ref),
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
