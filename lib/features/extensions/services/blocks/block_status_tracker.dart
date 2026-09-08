import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/db/repositories/info_blocks_repository.dart';
import '../../../../core/utils/id_generator.dart';
import '../../models/block_config.dart';
import '../../models/block_run_status.dart';
import '../../models/info_block.dart';
import '../../providers/info_blocks_provider.dart';
import 'block_context.dart';

typedef BlockPanelRefresh =
    void Function(
      String charId,
      String sessionId,
      String messageId,
      int swipeId,
      int agentSwipeId,
    );

class PreparedBlockRun {
  const PreparedBlockRun({
    required this.placeholderId,
    required this.placeholder,
  });

  final String placeholderId;
  final InfoBlock placeholder;
}

class BlockStatusTracker {
  const BlockStatusTracker({
    required this.ref,
    required this.repo,
    required this.refreshPanelForMessage,
  });

  final Ref ref;
  final InfoBlocksRepository repo;
  final BlockPanelRefresh refreshPanelForMessage;

  Future<PreparedBlockRun> prepare({
    required String charId,
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required BlockConfig blockConfig,
    String? reuseBlockId,
  }) async {
    if (reuseBlockId != null) {
      return _prepareReuse(
        charId: charId,
        sessionId: sessionId,
        messageId: messageId,
        swipeId: swipeId,
        agentSwipeId: agentSwipeId,
        blockConfig: blockConfig,
        reuseBlockId: reuseBlockId,
      );
    }
    return _prepareNew(
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
      blockConfig: blockConfig,
    );
  }

  Future<InfoBlock> markError({
    required BlockContext context,
    required String errorMessage,
  }) async {
    return markErrorForPlaceholder(
      charId: context.charId,
      sessionId: context.sessionId,
      messageId: context.messageId,
      placeholderId: context.placeholderId,
      placeholder: context.placeholder,
      errorMessage: errorMessage,
    );
  }

  Future<InfoBlock> markErrorForPlaceholder({
    required String charId,
    required String sessionId,
    required String messageId,
    required String placeholderId,
    required InfoBlock placeholder,
    required String errorMessage,
  }) async {
    final content = _formatBlockErrorContent(errorMessage);
    await repo.updateContent(placeholderId, content);
    await repo.updateStatus(placeholderId, BlockRunStatus.error);
    final errored = placeholder.copyWith(
      content: content,
      status: BlockRunStatus.error,
    );
    ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(errored);
    refreshPanelForMessage(
      charId,
      sessionId,
      messageId,
      placeholder.swipeId,
      placeholder.agentSwipeId,
    );
    return errored;
  }

  Future<InfoBlock> markStoppedForPlaceholder({
    required String charId,
    required String sessionId,
    required String messageId,
    required String placeholderId,
    required InfoBlock placeholder,
  }) async {
    await repo.updateStatus(placeholderId, BlockRunStatus.stopped);
    final stopped = placeholder.copyWith(status: BlockRunStatus.stopped);
    ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(stopped);
    refreshPanelForMessage(
      charId,
      sessionId,
      messageId,
      placeholder.swipeId,
      placeholder.agentSwipeId,
    );
    return stopped;
  }

  Future<String?> dedupeForConfig({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required String blockId,
  }) async {
    final existing = await repo.getByMessageId(
      sessionId,
      messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
    final matching = existing.where((b) => b.blockId == blockId).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (matching.isEmpty) return null;
    final keep = matching.first;
    for (final dup in matching.skip(1)) {
      await repo.deleteInfoBlock(dup.id);
      await ref.read(infoBlocksProvider(sessionId).notifier).delete(dup.id);
    }
    return keep.id;
  }

  Future<PreparedBlockRun> _prepareReuse({
    required String charId,
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required BlockConfig blockConfig,
    required String reuseBlockId,
  }) async {
    final existing = await repo.getByMessageId(
      sessionId,
      messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
    final row = existing.where((b) => b.id == reuseBlockId).firstOrNull;
    final placeholder =
        (row ??
                InfoBlock(
                  id: reuseBlockId,
                  sessionId: sessionId,
                  messageId: messageId,
                  swipeId: swipeId,
                  agentSwipeId: agentSwipeId,
                  blockId: blockConfig.id,
                  blockName: blockConfig.name,
                  blockType: blockConfig.type.name,
                  content: '',
                  createdAt: DateTime.now().millisecondsSinceEpoch,
                  order: blockConfig.order,
                  status: BlockRunStatus.running,
                ))
            .copyWith(content: '', status: BlockRunStatus.running);
    await repo.updateContent(reuseBlockId, '');
    await repo.updateStatus(reuseBlockId, BlockRunStatus.running);
    ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(placeholder);
    refreshPanelForMessage(
      charId,
      sessionId,
      messageId,
      placeholder.swipeId,
      placeholder.agentSwipeId,
    );
    return PreparedBlockRun(
      placeholderId: reuseBlockId,
      placeholder: placeholder,
    );
  }

  Future<PreparedBlockRun> _prepareNew({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required BlockConfig blockConfig,
  }) async {
    final placeholderId = generateId();
    final placeholder = InfoBlock(
      id: placeholderId,
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
      blockId: blockConfig.id,
      blockName: blockConfig.name,
      blockType: blockConfig.type.name,
      content: '',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      order: blockConfig.order,
      status: BlockRunStatus.running,
    );
    await repo.insert(placeholder);
    ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(placeholder);
    return PreparedBlockRun(
      placeholderId: placeholderId,
      placeholder: placeholder,
    );
  }

  String _formatBlockErrorContent(String message) {
    final escaped = message
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    return '<p class="ext-block-error"><strong>Ошибка:</strong> $escaped</p>';
  }
}
