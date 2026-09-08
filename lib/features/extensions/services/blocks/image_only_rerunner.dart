import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/db/repositories/info_blocks_repository.dart';
import '../../../../core/models/character.dart';
import '../../../../core/models/persona.dart';
import '../../../image_gen/services/image_tag_markup.dart';
import '../../models/block_config.dart';
import '../../models/block_run_status.dart';
import '../../models/info_block.dart';
import '../../providers/info_blocks_provider.dart';
import 'infoblock_handler.dart';

class ImageOnlyRerunner {
  const ImageOnlyRerunner({
    required this.ref,
    required this.repo,
    required this.refreshPanelForMessage,
    required this.renderImagePixels,
  });

  final Ref ref;
  final InfoBlocksRepository repo;
  final PanelRefresher refreshPanelForMessage;
  final ImagePixelRerenderFn renderImagePixels;

  Future<void> rerun({
    required String blockId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required String sessionId,
    required String charId,
    required Character character,
    required Persona? persona,
    required List<BlockConfig> blocks,
    required CancelToken cancelToken,
  }) async {
    final blockConfig = blocks.where((b) => b.id == blockId).firstOrNull;
    if (blockConfig == null || blockConfig.type != BlockType.imageGen) return;

    final rows = await repo.getByMessageId(
      sessionId,
      messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
    final existing = rows.where((b) => b.blockId == blockId).firstOrNull;
    if (existing == null || existing.content.isEmpty) return;

    if (ImageTagMarkup
        .extractInstructionsFromImageContent(existing.content)
        .isEmpty) {
      return;
    }

    await repo.updateStatus(existing.id, BlockRunStatus.running);
    ref
        .read(infoBlocksProvider(sessionId).notifier)
        .addOrReplace(existing.copyWith(status: BlockRunStatus.running));
    refreshPanelForMessage(charId, sessionId, messageId, swipeId, agentSwipeId);

    await renderImagePixels(
      charId: charId,
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
      blockConfig: blockConfig,
      character: character,
      persona: persona,
      sourceContent: existing.content,
      placeholderId: existing.id,
      placeholder: existing,
      cancelToken: cancelToken,
    );
  }
}

typedef ImagePixelRerenderFn =
    Future<InfoBlock?> Function({
      required String charId,
      required String sessionId,
      required String messageId,
      required int swipeId,
      required int agentSwipeId,
      required BlockConfig blockConfig,
      required Character character,
      required Persona? persona,
      required String sourceContent,
      required String placeholderId,
      required InfoBlock placeholder,
      required CancelToken cancelToken,
    });
