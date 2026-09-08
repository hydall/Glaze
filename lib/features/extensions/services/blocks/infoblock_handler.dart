import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/db/repositories/info_blocks_repository.dart';
import '../../models/block_config.dart';
import '../../models/block_run_status.dart';
import '../../models/info_block.dart';
import '../../providers/info_blocks_provider.dart';
import '../info_block_service.dart';
import 'block_context.dart';
import 'block_handler.dart';

typedef BlockErrorMarker =
    Future<InfoBlock> Function({
      required BlockContext context,
      required String errorMessage,
    });

typedef PanelRefresher =
    void Function(
      String charId,
      String sessionId,
      String messageId,
      int swipeId,
      int agentSwipeId,
    );

typedef StreamHandlerFactory =
    void Function(String)? Function({
      required BlockConfig blockConfig,
      required String charId,
      required String sessionId,
      required String messageId,
      required InfoBlock placeholder,
    });

class InfoblockHandler implements BlockHandler {
  const InfoblockHandler({
    required this.ref,
    required this.repo,
    required this.markBlockError,
    required this.refreshPanelForMessage,
    required this.makeStreamHandler,
  });

  final Ref ref;
  final InfoBlocksRepository repo;
  final BlockErrorMarker markBlockError;
  final PanelRefresher refreshPanelForMessage;
  final StreamHandlerFactory makeStreamHandler;

  @override
  Future<InfoBlock?> handle(BlockContext context) async {
    final blockConfig = context.blockConfig;
    final infoBlockService = ref.read(infoBlockServiceProvider);
    final generated = await infoBlockService.generateSingleBlockContent(
      sessionId: context.sessionId,
      messageId: context.messageId,
      messages: context.messages,
      blockConfig: blockConfig,
      character: context.character,
      persona: context.persona?.name,
      previousOutput: context.previousOutput,
      contextPolicy: blockConfig.contextPolicy,
      mainModelContextSnapshot: context.mainModelContextSnapshot,
      personaModel: context.persona,
      swipeId: context.swipeId,
      cancelToken: context.cancelToken,
      onStreamUpdate: makeStreamHandler(
        blockConfig: blockConfig,
        charId: context.charId,
        sessionId: context.sessionId,
        messageId: context.messageId,
        placeholder: context.placeholder,
      ),
    );
    if (context.cancelToken.isCancelled) {
      await repo.updateStatus(context.placeholderId, BlockRunStatus.stopped);
      final stopped = InfoBlock(
        id: context.placeholderId,
        sessionId: context.sessionId,
        messageId: context.messageId,
        swipeId: context.swipeId,
        agentSwipeId: context.agentSwipeId,
        blockId: blockConfig.id,
        blockName: blockConfig.name,
        blockType: blockConfig.type.name,
        content: '',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        order: blockConfig.order,
        status: BlockRunStatus.stopped,
      );
      ref
          .read(infoBlocksProvider(context.sessionId).notifier)
          .addOrReplace(stopped);
      refreshPanelForMessage(
        context.charId,
        context.sessionId,
        context.messageId,
        context.swipeId,
        context.agentSwipeId,
      );
      return stopped;
    }

    if (generated.error != null) {
      return markBlockError(context: context, errorMessage: generated.error!);
    }

    final content = generated.content;
    if (content == null || content.isEmpty) {
      return markBlockError(
        context: context,
        errorMessage: 'Generation produced empty content',
      );
    }

    await repo.updateContent(context.placeholderId, content);
    await repo.updateStatus(context.placeholderId, BlockRunStatus.done);

    final done = InfoBlock(
      id: context.placeholderId,
      sessionId: context.sessionId,
      messageId: context.messageId,
      swipeId: context.swipeId,
      agentSwipeId: context.agentSwipeId,
      blockId: blockConfig.id,
      blockName: blockConfig.name,
      blockType: blockConfig.type.name,
      content: content,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      order: blockConfig.order,
      status: BlockRunStatus.done,
    );
    ref.read(infoBlocksProvider(context.sessionId).notifier).addOrReplace(done);
    refreshPanelForMessage(
      context.charId,
      context.sessionId,
      context.messageId,
      context.swipeId,
      context.agentSwipeId,
    );
    return done;
  }
}
