import 'package:drift/drift.dart';

import '../app_db.dart';
import '../tables.dart';
import '../../../core/utils/sync_deletion_tracker.dart';
import '../../../features/extensions/models/block_run_status.dart';
import '../../../features/extensions/models/info_block.dart';

part 'info_blocks_repository.g.dart';

@DriftAccessor(tables: [InfoBlocks])
class InfoBlocksRepository extends DatabaseAccessor<AppDatabase>
    with _$InfoBlocksRepositoryMixin {
  InfoBlocksRepository(super.db);

  Future<void> insert(InfoBlock block) async {
    await into(infoBlocks).insert(
      InfoBlocksCompanion.insert(
        id: block.id,
        sessionId: block.sessionId,
        messageId: block.messageId,
        swipeId: Value(block.swipeId),
        agentSwipeId: Value(block.agentSwipeId),
        blockId: block.blockId,
        blockType: block.blockType,
        blockName: block.blockName,
        content: block.content,
        createdAt: Value(block.createdAt),
        order_: Value(block.order),
        status: Value(block.status.name),
      ),
    );
  }

  Future<void> updateStatus(String id, BlockRunStatus status) async {
    await (update(infoBlocks)..where((t) => t.id.equals(id))).write(
      InfoBlocksCompanion(status: Value(status.name)),
    );
  }

  Future<void> updateRunningBefore(
    String sessionId,
    int createdBefore,
    BlockRunStatus status,
  ) async {
    await (update(infoBlocks)..where(
          (t) =>
              t.sessionId.equals(sessionId) &
              t.status.equals(BlockRunStatus.running.name) &
              t.createdAt.isSmallerThanValue(createdBefore),
        ))
        .write(InfoBlocksCompanion(status: Value(status.name)));
  }

  Future<void> updateContent(String id, String content) async {
    await (update(infoBlocks)..where((t) => t.id.equals(id))).write(
      InfoBlocksCompanion(content: Value(content)),
    );
  }

  Future<List<InfoBlock>> getBySessionId(String sessionId) async {
    final rows =
        await (select(infoBlocks)
              ..where((tbl) => tbl.sessionId.equals(sessionId))
              ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
            .get();

    return rows.map(_rowToModel).toList();
  }

  Future<List<InfoBlock>> getByMessageId(
    String sessionId,
    String messageId, {
    int swipeId = 0,
    int? agentSwipeId,
  }) async {
    final rows =
        await (select(infoBlocks)
              ..where((tbl) {
                final base =
                    tbl.sessionId.equals(sessionId) &
                    tbl.messageId.equals(messageId) &
                    tbl.swipeId.equals(swipeId);
                if (agentSwipeId == null) return base;
                return base & tbl.agentSwipeId.equals(agentSwipeId);
              })
              ..orderBy([(t) => OrderingTerm.asc(t.order_)]))
            .get();

    return rows.map(_rowToModel).toList();
  }

  Future<List<InfoBlock>> getRecentBlocks(
    String sessionId,
    String blockName,
    int count,
  ) async {
    final rows =
        await (select(infoBlocks)
              ..where(
                (tbl) =>
                    tbl.sessionId.equals(sessionId) &
                    tbl.blockName.equals(blockName),
              )
              ..orderBy([
                (t) => OrderingTerm.desc(t.createdAt),
                (t) => OrderingTerm.asc(t.order_),
              ])
              ..limit(count))
            .get();

    return rows.map(_rowToModel).toList();
  }

  /// Returns all distinct sessionIds that have at least one info block.
  Future<List<String>> getAllSessionIds() async {
    final rows = await customSelect(
      'SELECT DISTINCT session_id FROM info_blocks',
      readsFrom: {infoBlocks},
    ).get();
    return rows.map((r) => r.read<String>('session_id')).toList();
  }

  Future<void> deleteBySessionId(String sessionId) async {
    await (delete(
      infoBlocks,
    )..where((tbl) => tbl.sessionId.equals(sessionId))).go();
    await SyncDeletionTracker.record('info_block', sessionId);
  }

  Future<void> copyForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
    required Set<String> messageIds,
  }) async {
    if (messageIds.isEmpty) return;
    final rows =
        await (select(infoBlocks)
              ..where((row) => row.sessionId.equals(fromSessionId))
              ..where((row) => row.messageId.isIn(messageIds))
              ..where((row) => row.status.equals(BlockRunStatus.done.name)))
            .get();
    await batch((batch) {
      for (final row in rows) {
        batch.insert(
          infoBlocks,
          InfoBlocksCompanion.insert(
            id: '${row.id}@$toSessionId',
            sessionId: toSessionId,
            messageId: row.messageId,
            swipeId: Value(row.swipeId),
            agentSwipeId: Value(row.agentSwipeId),
            blockId: row.blockId,
            blockType: row.blockType,
            blockName: row.blockName,
            content: row.content,
            createdAt: Value(row.createdAt),
            order_: Value(row.order_),
            status: Value(row.status),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<void> deleteInfoBlock(String id) async {
    await (delete(infoBlocks)..where((tbl) => tbl.id.equals(id))).go();
  }

  Future<void> deleteByMessageId(
    String sessionId,
    String messageId, {
    int? swipeId,
    int? agentSwipeId,
  }) async {
    await (delete(infoBlocks)..where((tbl) {
          var base =
              tbl.sessionId.equals(sessionId) & tbl.messageId.equals(messageId);
          if (swipeId != null) base = base & tbl.swipeId.equals(swipeId);
          if (agentSwipeId != null) {
            base = base & tbl.agentSwipeId.equals(agentSwipeId);
          }
          return base;
        }))
        .go();
  }

  Future<void> deleteSwipeAndShift({
    required String sessionId,
    required String messageId,
    required int removedSwipeId,
  }) async {
    await deleteByMessageId(sessionId, messageId, swipeId: removedSwipeId);
    final rows =
        await (select(infoBlocks)
              ..where((t) => t.sessionId.equals(sessionId))
              ..where((t) => t.messageId.equals(messageId))
              ..where((t) => t.swipeId.isBiggerThanValue(removedSwipeId)))
            .get();
    for (final row in rows) {
      await (update(infoBlocks)..where((t) => t.id.equals(row.id))).write(
        InfoBlocksCompanion(swipeId: Value(row.swipeId - 1)),
      );
    }
  }

  Future<void> deleteAgentSwipeAndShift({
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int removedAgentSwipeId,
  }) async {
    await deleteByMessageId(
      sessionId,
      messageId,
      swipeId: swipeId,
      agentSwipeId: removedAgentSwipeId,
    );
    final rows =
        await (select(infoBlocks)
              ..where((t) => t.sessionId.equals(sessionId))
              ..where((t) => t.messageId.equals(messageId))
              ..where((t) => t.swipeId.equals(swipeId))
              ..where(
                (t) => t.agentSwipeId.isBiggerThanValue(removedAgentSwipeId),
              ))
            .get();
    for (final row in rows) {
      await (update(infoBlocks)..where((t) => t.id.equals(row.id))).write(
        InfoBlocksCompanion(agentSwipeId: Value(row.agentSwipeId - 1)),
      );
    }
  }

  InfoBlock _rowToModel(InfoBlockRow row) {
    return InfoBlock(
      id: row.id,
      sessionId: row.sessionId,
      messageId: row.messageId,
      swipeId: row.swipeId,
      agentSwipeId: row.agentSwipeId,
      blockId: row.blockId,
      blockName: row.blockName,
      blockType: row.blockType,
      content: row.content,
      createdAt: row.createdAt,
      order: row.order_,
      status: BlockRunStatus.values.byName(row.status),
    );
  }
}
