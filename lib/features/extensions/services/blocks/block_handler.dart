import '../../models/block_config.dart';
import '../../models/info_block.dart';
import 'block_context.dart';

abstract class BlockHandler {
  Future<InfoBlock?> handle(BlockContext context);
}

/// Writes [errorMessage] into the block's row and panel entry.
typedef BlockErrorMarker =
    Future<InfoBlock> Function({
      required BlockContext context,
      required String errorMessage,
    });

/// Re-renders the ext-blocks panel hanging under one message.
typedef PanelRefresher =
    void Function(
      String charId,
      String sessionId,
      String messageId,
      int swipeId,
      int agentSwipeId,
    );

/// Builds the incremental-output callback for a block, or null when the block
/// does not stream into the panel.
typedef StreamHandlerFactory =
    void Function(String)? Function({
      required BlockConfig blockConfig,
      required String charId,
      required String sessionId,
      required String messageId,
      required InfoBlock placeholder,
    });

/// Pushes a block's current content into the panel without finishing it.
typedef StreamingBlockPublisher =
    void Function({
      required String charId,
      required String sessionId,
      required String messageId,
      required InfoBlock placeholder,
      required String content,
      bool force,
    });
