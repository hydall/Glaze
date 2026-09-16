import '../../models/block_config.dart';
import '../../models/info_block.dart';
import 'block_context.dart';
import 'block_handler.dart';
import 'infoblock_handler.dart' show BlockErrorMarker;

/// Stands in for block types the editor can already describe but the runtime
/// cannot yet execute — rewrite and accumulation blocks imported from the
/// original extension.
///
/// Such blocks are kept out of the automatic chain by [BlockTypeRunnable], so
/// this handler is only reached when the user runs one by hand. It writes a
/// plain error into the panel rather than failing silently, because a block
/// that quietly produces nothing reads as a bug in the user's own prompt.
class UnsupportedBlockHandler implements BlockHandler {
  const UnsupportedBlockHandler({
    required this.markBlockError,
    required this.reason,
  });

  final BlockErrorMarker markBlockError;

  /// Shown to the user in place of the block's content.
  final String reason;

  @override
  Future<InfoBlock?> handle(BlockContext context) =>
      markBlockError(context: context, errorMessage: reason);
}
