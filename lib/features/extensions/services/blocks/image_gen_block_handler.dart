import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/db/repositories/info_blocks_repository.dart';
import '../../models/block_run_status.dart';
import '../../models/info_block.dart';
import '../info_block_service.dart';
import 'block_context.dart';
import 'block_handler.dart';
import 'infoblock_handler.dart';

typedef StreamingBlockPublisher =
    void Function({
      required String charId,
      required String sessionId,
      required String messageId,
      required InfoBlock placeholder,
      required String content,
      bool force,
    });

typedef ImagePixelRenderFn =
    Future<InfoBlock?> Function({
      required BlockContext context,
      required String sourceContent,
    });

class ImageGenBlockHandler implements BlockHandler {
  const ImageGenBlockHandler({
    required this.ref,
    required this.repo,
    required this.markBlockError,
    required this.makeStreamHandler,
    required this.publishStreamingBlockContent,
    required this.renderImagePixels,
  });

  final Ref ref;
  final InfoBlocksRepository repo;
  final BlockErrorMarker markBlockError;
  final StreamHandlerFactory makeStreamHandler;
  final StreamingBlockPublisher publishStreamingBlockContent;
  final ImagePixelRenderFn renderImagePixels;

  @override
  Future<InfoBlock?> handle(BlockContext context) async {
    final blockConfig = context.blockConfig;
    final placeholder = context.placeholder;
    debugPrint('[ExtPostGen] _runImageGen START: name="${blockConfig.name}"');

    // Step 1: LLM image agent (U+A+previous block -> HTML with [IMG:GEN]).
    final infoBlockService = ref.read(infoBlockServiceProvider);
    final generated = await infoBlockService.generateSingleBlockContent(
      sessionId: context.sessionId,
      messageId: context.messageId,
      messages: context.messages,
      blockConfig: blockConfig,
      character: context.character,
      persona: context.persona?.name,
      personaPrompt: context.persona?.prompt,
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
        placeholder: placeholder,
      ),
    );

    if (context.cancelToken.isCancelled) {
      await repo.updateStatus(context.placeholderId, BlockRunStatus.stopped);
      return placeholder.copyWith(status: BlockRunStatus.stopped);
    }

    if (generated.error != null || generated.content == null) {
      return markBlockError(
        context: context,
        errorMessage: generated.error ?? 'Image agent returned empty response',
      );
    }

    final agentHtml = generated.content!;
    publishStreamingBlockContent(
      charId: context.charId,
      sessionId: context.sessionId,
      messageId: context.messageId,
      placeholder: placeholder,
      content: agentHtml,
      force: true,
    );

    return renderImagePixels(context: context, sourceContent: agentHtml);
  }
}
