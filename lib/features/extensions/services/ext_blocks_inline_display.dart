import '../../../core/models/chat_message.dart';
import '../../image_gen/services/image_tag_markup.dart';
import '../models/block_config.dart';
import '../models/block_modes.dart';
import '../models/block_run_status.dart';
import '../models/extension_preset.dart';
import '../models/info_block.dart';
import 'block_content_extractor.dart';

/// Whether [block]'s finished result is shown inside the message text rather
/// than in the panel under it. In the original that is every generated block
/// and every accumulation state; a script shows nothing of its own.
bool showsInMessage(BlockConfig block) =>
    rendersInMessage(block.type) &&
    block.render == BlockRender.message &&
    !block.hideDisplay;

/// Whether a block of [type] can be shown inside the message at all.
bool rendersInMessage(BlockType type) =>
    type == BlockType.generated || type == BlockType.accumulation;

/// The blocks shown inside [message], in the order they are appended: every
/// finished [BlockRender.message] block stored under it, in preset order,
/// with content.
///
/// [rows] may hold any blocks of the session; the ones of the swipe the
/// message shows are picked here, as the panel picks them.
List<InlineExtBlock> inlineExtBlocks({
  required ExtensionPreset? preset,
  required Iterable<InfoBlock> rows,
  required ChatMessage message,
}) {
  if (preset == null) return const [];
  final configs = preset.blocks.where((b) => b.enabled && showsInMessage(b));
  if (configs.isEmpty) return const [];

  final ofSwipe = rows
      .where((r) => r.messageId == message.id && r.swipeId == message.swipeId)
      .toList();
  var ofSub = ofSwipe.where((r) => r.agentSwipeId == message.agentSwipeId);
  if (ofSub.isEmpty) ofSub = ofSwipe.where((r) => r.agentSwipeId == -1);
  final byBlockId = {for (final r in ofSub) r.blockId: r};

  final sorted = configs.toList()..sort((a, b) => a.order.compareTo(b.order));
  return [
    for (final config in sorted)
      if (byBlockId[config.id] case final row?
          when row.status == BlockRunStatus.done &&
              row.content.trim().isNotEmpty)
        (config: config, row: row),
  ];
}

/// One block shown inside a message: its settings and its stored result.
typedef InlineExtBlock = ({BlockConfig config, InfoBlock row});

/// The text the original extension appends to a message for display: the
/// [inlineExtBlocks] of [message], each in its tag, joined by newlines. `''`
/// when there is none.
String inlineExtBlocksText({
  required ExtensionPreset? preset,
  required Iterable<InfoBlock> rows,
  required ChatMessage message,
}) => inlineExtBlocks(
  preset: preset,
  rows: rows,
  message: message,
).map((b) => wrapInBlockTag(b.config, b.row.content.trim())).join('\n');

/// The block shown inside [message] that holds the [imageIndex]-th image of
/// the message as displayed, and the image's position inside that block; null
/// when the image is the message's own.
///
/// The chat numbers the images of the text it shows — the message, then its
/// inline blocks — so an image action on a block's picture arrives with an
/// index past the message's own images. sillyimages numbers them the same
/// way (`mes` first, then `extra.extblocks`) and redraws the tag where it
/// lives.
({InlineExtBlock block, int index})? inlineExtBlockImageAt({
  required ExtensionPreset? preset,
  required Iterable<InfoBlock> rows,
  required ChatMessage message,
  required int imageIndex,
}) {
  var at = imageIndex - ImageTagMarkup.scanImageBlocks(message.content).length;
  if (at < 0) return null;
  for (final block in inlineExtBlocks(
    preset: preset,
    rows: rows,
    message: message,
  )) {
    final count = ImageTagMarkup.scanImageBlocks(block.row.content).length;
    if (at < count) return (block: block, index: at);
    at -= count;
  }
  return null;
}

/// Appends [inline] to a message's [text] the way the original builds
/// `display_text`: `mes + "\n" + blocks`.
String withInlineExtBlocks(String text, String inline) =>
    inline.isEmpty ? text : '$text\n$inline';
