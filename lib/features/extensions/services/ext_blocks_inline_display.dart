import '../../../core/models/chat_message.dart';
import '../models/block_config.dart';
import '../models/block_modes.dart';
import '../models/block_run_status.dart';
import '../models/extension_preset.dart';
import '../models/info_block.dart';
import 'block_content_extractor.dart';

/// Whether [block]'s finished result is shown inside the message text rather
/// than in the panel under it.
bool showsInMessage(BlockConfig block) =>
    block.type == BlockType.generated &&
    block.render == BlockRender.message &&
    !block.hideDisplay;

/// The text the original extension appends to a message for display: every
/// finished [BlockRender.message] block stored under [message], in preset
/// order, each in its tag, joined by newlines. `''` when there is none.
///
/// [rows] may hold any blocks of the session; the ones of the swipe the
/// message shows are picked here, as the panel picks them.
String inlineExtBlocksText({
  required ExtensionPreset? preset,
  required Iterable<InfoBlock> rows,
  required ChatMessage message,
}) {
  if (preset == null) return '';
  final configs = preset.blocks.where((b) => b.enabled && showsInMessage(b));
  if (configs.isEmpty) return '';

  final ofSwipe = rows
      .where((r) => r.messageId == message.id && r.swipeId == message.swipeId)
      .toList();
  var ofSub = ofSwipe.where((r) => r.agentSwipeId == message.agentSwipeId);
  if (ofSub.isEmpty) ofSub = ofSwipe.where((r) => r.agentSwipeId == -1);
  final byBlockId = {for (final r in ofSub) r.blockId: r};

  final sorted = configs.toList()..sort((a, b) => a.order.compareTo(b.order));
  final parts = <String>[];
  for (final config in sorted) {
    final row = byBlockId[config.id];
    if (row == null || row.status != BlockRunStatus.done) continue;
    final content = row.content.trim();
    if (content.isEmpty) continue;
    final tag = blockTagName(
      config,
      config.template.replaceAll('{{name}}', config.name),
    );
    parts.add(
      content.contains('<$tag') ? content : '<$tag>\n$content\n</$tag>',
    );
  }
  return parts.join('\n');
}

/// Appends [inline] to a message's [text] the way the original builds
/// `display_text`: `mes + "\n" + blocks`.
String withInlineExtBlocks(String text, String inline) =>
    inline.isEmpty ? text : '$text\n$inline';
