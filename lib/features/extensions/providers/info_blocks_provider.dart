import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/db/repositories/info_blocks_repository.dart';
import '../../../core/state/db_provider.dart';
import '../models/block_run_status.dart';
import '../models/info_block.dart';

final _providerBootMillis = DateTime.now().millisecondsSinceEpoch;

extension InfoBlockBridgeMap on InfoBlock {
  /// Converts an InfoBlock to a plain map suitable for sending to the WebView
  /// bridge (showExtBlocksPanel / updateExtBlocksPanel).
  Map<String, dynamic> toMap() => {
    'id': id,
    'blockId': blockId,
    'swipeId': swipeId,
    'agentSwipeId': agentSwipeId,
    'blockName': blockName,
    'name': blockName,
    'type': blockType,
    'status': status.name,
    'content': content,
    'order': order,
  };
}

final infoBlocksProvider =
    StateNotifierProvider.family<InfoBlocksNotifier, List<InfoBlock>, String>(
      (ref, sessionId) => InfoBlocksNotifier(ref, sessionId),
    );

class InfoBlocksNotifier extends StateNotifier<List<InfoBlock>> {
  InfoBlocksNotifier(this._ref, this.sessionId) : super([]) {
    _load(stopStaleRunning: true);
  }

  final Ref _ref;
  final String sessionId;

  InfoBlocksRepository get _repo =>
      InfoBlocksRepository(_ref.read(appDbProvider));

  Future<void> _load({bool stopStaleRunning = false}) async {
    var blocks = await _repo.getBySessionId(sessionId);
    if (!mounted) return;
    if (stopStaleRunning) {
      final hasStaleRunning = blocks.any(
        (b) =>
            b.status == BlockRunStatus.running &&
            b.createdAt < _providerBootMillis,
      );
      if (hasStaleRunning) {
        await _repo.updateRunningBefore(
          sessionId,
          _providerBootMillis,
          BlockRunStatus.stopped,
        );
        if (!mounted) return;
        blocks = blocks
            .map(
              (b) => b.status == BlockRunStatus.running &&
                      b.createdAt < _providerBootMillis
                  ? b.copyWith(status: BlockRunStatus.stopped)
                  : b,
            )
            .toList();
      }
    }
    state = blocks;
  }

  /// Inserts or replaces a block in state (matched by id).
  /// Does NOT write to DB — caller is responsible for DB persistence.
  void addOrReplace(InfoBlock block) {
    final idx = state.indexWhere((b) => b.id == block.id);
    if (idx >= 0) {
      final updated = List<InfoBlock>.from(state);
      updated[idx] = block;
      state = updated;
    } else {
      state = [block, ...state];
    }
  }

  /// Removes all blocks for [messageId] + [blockId] from in-memory state.
  /// Does NOT delete from DB — caller handles that.
  void removeByBlockId({
    required String messageId,
    required String blockId,
    int? swipeId,
    int? agentSwipeId,
  }) {
    state = state
        .where((b) =>
            !(b.messageId == messageId &&
                b.blockId == blockId &&
                (swipeId == null || b.swipeId == swipeId) &&
                (agentSwipeId == null || b.agentSwipeId == agentSwipeId)))
        .toList();
  }

  /// Updates the status of a block in state.
  void updateStatus(String id, BlockRunStatus status) {
    final idx = state.indexWhere((b) => b.id == id);
    if (idx < 0) return;
    final updated = List<InfoBlock>.from(state);
    updated[idx] = updated[idx].copyWith(status: status);
    state = updated;
  }

  /// Updates the content of a block in state and in the DB.
  Future<void> updateContent(String id, String content) async {
    final idx = state.indexWhere((b) => b.id == id);
    if (idx < 0) return;
    await _repo.updateContent(id, content);
    final updated = List<InfoBlock>.from(state);
    updated[idx] = updated[idx].copyWith(content: content);
    state = updated;
  }

  /// Removes all blocks for [messageId] from in-memory state.
  void removeByMessageId(String messageId, {int? swipeId, int? agentSwipeId}) {
    state = state
        .where((b) =>
            !(b.messageId == messageId &&
                (swipeId == null || b.swipeId == swipeId) &&
                (agentSwipeId == null || b.agentSwipeId == agentSwipeId)))
        .toList();
  }

  /// Deletes all blocks for [messageId] from DB and state.
  Future<void> deleteByMessageId(
    String messageId, {
    int? swipeId,
    int? agentSwipeId,
  }) async {
    await _repo.deleteByMessageId(
      sessionId,
      messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
    );
    removeByMessageId(messageId, swipeId: swipeId, agentSwipeId: agentSwipeId);
  }

  Future<void> delete(String id) async {
    await _repo.deleteInfoBlock(id);
    state = state.where((b) => b.id != id).toList();
  }

  Future<void> clear() async {
    await _repo.deleteBySessionId(sessionId);
    state = [];
  }

  Future<void> refresh() async {
    await _load();
  }

  /// Returns all blocks for a specific message, sorted by order.
  /// When duplicates exist for the same preset block, keeps the newest row.
  ///
  /// Fallback: if no blocks match the exact [agentSwipeId], retries with
  /// `agentSwipeId = -1` (legacy binding from the no-cleaner path). This
  /// prevents blocks from disappearing after app restart when the message's
  /// `agentSwipeId` (default 0 from freezed) doesn't match the block's
  /// `agentSwipeId` (-1, set when post-cleaner was disabled/skipped).
  List<InfoBlock> getByMessageId(String messageId, {int swipeId = 0, int agentSwipeId = -1}) {
    var blocks = state
        .where((b) =>
            b.messageId == messageId &&
            b.swipeId == swipeId &&
            b.agentSwipeId == agentSwipeId)
        .toList();
    if (blocks.isEmpty && agentSwipeId != -1) {
      blocks = state
          .where((b) =>
              b.messageId == messageId &&
              b.swipeId == swipeId &&
              b.agentSwipeId == -1)
          .toList();
    }
    final byBlockId = <String, InfoBlock>{};
    for (final block in blocks) {
      final existing = byBlockId[block.blockId];
      if (existing == null || block.createdAt >= existing.createdAt) {
        byBlockId[block.blockId] = block;
      }
    }
    return byBlockId.values.toList()
      ..sort((a, b) => a.order.compareTo(b.order));
  }

  /// Aggregated status for a message:
  /// - 'running' if any block is running
  /// - 'error' if any block errored (and none running)
  /// - 'done' if all blocks done/stopped
  /// - null if no blocks
  String? aggregatedStatus(String messageId, {int swipeId = 0, int agentSwipeId = -1}) {
    final blocks = getByMessageId(messageId, swipeId: swipeId, agentSwipeId: agentSwipeId);
    if (blocks.isEmpty) return null;
    if (blocks.any((b) => b.status == BlockRunStatus.running)) return 'running';
    if (blocks.any((b) => b.status == BlockRunStatus.error)) return 'error';
    return 'done';
  }
}
