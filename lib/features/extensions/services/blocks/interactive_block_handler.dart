import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/db/repositories/info_blocks_repository.dart';
import '../../models/block_run_status.dart';
import '../../models/info_block.dart';
import '../../providers/info_blocks_provider.dart';
import '../info_block_service.dart';
import '../panel_host_service.dart';
import 'block_context.dart';
import 'block_handler.dart';
import 'image_gen_block_handler.dart';
import 'infoblock_handler.dart';

class InteractiveBlockHandler implements BlockHandler {
  const InteractiveBlockHandler({
    required this.ref,
    required this.repo,
    required this.markBlockError,
    required this.refreshPanelForMessage,
    required this.publishStreamingBlockContent,
  });

  final Ref ref;
  final InfoBlocksRepository repo;
  final BlockErrorMarker markBlockError;
  final PanelRefresher refreshPanelForMessage;
  final StreamingBlockPublisher publishStreamingBlockContent;

  @override
  Future<InfoBlock?> handle(BlockContext context) async {
    final blockConfig = context.blockConfig;
    final placeholder = context.placeholder;
    if (context.cancelToken.isCancelled) {
      await repo.updateStatus(context.placeholderId, BlockRunStatus.stopped);
      return placeholder.copyWith(status: BlockRunStatus.stopped);
    }

    final prompt = blockConfig.prompt.trim();
    final staticHtml = blockConfig.script.trim();

    String html;
    if (prompt.isEmpty && staticHtml.isNotEmpty) {
      html = staticHtml;
    } else if (prompt.isEmpty) {
      debugPrint(
        '[ExtPostGen] interactive "${blockConfig.name}" - prompt is empty',
      );
      await repo.updateStatus(context.placeholderId, BlockRunStatus.done);
      refreshPanelForMessage(
        context.charId,
        context.sessionId,
        context.messageId,
        context.swipeId,
        context.agentSwipeId,
      );
      return placeholder.copyWith(status: BlockRunStatus.done);
    } else {
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
      );

      if (context.cancelToken.isCancelled) {
        await repo.updateStatus(context.placeholderId, BlockRunStatus.stopped);
        return placeholder.copyWith(status: BlockRunStatus.stopped);
      }

      if (generated.error != null || generated.content == null) {
        return markBlockError(
          context: context,
          errorMessage:
              generated.error ?? 'Interactive agent returned empty response',
        );
      }

      html = _stripHtmlFence(generated.content!);
      publishStreamingBlockContent(
        charId: context.charId,
        sessionId: context.sessionId,
        messageId: context.messageId,
        placeholder: placeholder,
        content: html,
        force: true,
      );
    }

    final panelService = ref.read(panelHostServiceProvider);
    final opened = await panelService.openPanel(
      charId: context.charId,
      messageId: context.messageId,
      html: html,
      options: {'title': blockConfig.name, 'minHeight': 120},
    );
    if (opened == null) {
      return markBlockError(
        context: context,
        errorMessage:
            'Interactive panel host did not open a panel (no chat bridge?)',
      );
    }

    await repo.updateContent(context.placeholderId, html);
    await repo.updateStatus(context.placeholderId, BlockRunStatus.done);

    final done = placeholder.copyWith(
      content: html,
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

  String _stripHtmlFence(String raw) {
    var s = raw.trim();
    if (s.startsWith('```')) {
      final firstNewline = s.indexOf('\n');
      if (firstNewline != -1) s = s.substring(firstNewline + 1);
      if (s.endsWith('```')) s = s.substring(0, s.length - 3);
    }
    return s.trim();
  }
}
