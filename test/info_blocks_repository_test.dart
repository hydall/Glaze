import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/info_blocks_repository.dart';
import 'package:glaze_flutter/features/extensions/models/info_block.dart';

AppDatabase _testDb() => AppDatabase.forTesting(NativeDatabase.memory());

InfoBlock _block({
  required String id,
  required String messageId,
  required String name,
  required int createdAt,
  String content = 'content',
  int swipeId = 0,
}) {
  return InfoBlock(
    id: id,
    sessionId: 's1',
    messageId: messageId,
    swipeId: swipeId,
    blockId: 'cfg-$name',
    blockName: name,
    blockType: 'infoblock',
    content: content,
    createdAt: createdAt,
  );
}

void main() {
  late AppDatabase db;
  late InfoBlocksRepository repo;

  setUp(() {
    db = _testDb();
    repo = InfoBlocksRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('InfoBlocksRepository.getRecentBlocks', () {
    test('returns newest-first, filtered by block id, limited to count', () async {
      await repo.insert(_block(id: 'a', messageId: 'm1', name: 'Status', createdAt: 100));
      await repo.insert(_block(id: 'b', messageId: 'm2', name: 'Status', createdAt: 200));
      await repo.insert(_block(id: 'c', messageId: 'm3', name: 'Status', createdAt: 300));
      // Different block id — must be excluded.
      await repo.insert(_block(id: 'x', messageId: 'm2', name: 'Other', createdAt: 250));

      final recent = await repo.getRecentBlocks('s1', 'cfg-Status', 2);

      expect(recent.map((b) => b.id).toList(), ['c', 'b']);
    });

    test('returns all matching when count exceeds available', () async {
      await repo.insert(_block(id: 'a', messageId: 'm1', name: 'Status', createdAt: 100));
      await repo.insert(_block(id: 'b', messageId: 'm2', name: 'Status', createdAt: 200));

      final recent = await repo.getRecentBlocks('s1', 'cfg-Status', 10);

      expect(recent.map((b) => b.id).toList(), ['b', 'a']);
    });

    test('does not mix blocks that share a name but differ by id', () async {
      await repo.insert(_block(id: 'a', messageId: 'm1', name: 'Same', createdAt: 100));
      await repo.insert(
        InfoBlock(
          id: 'b',
          sessionId: 's1',
          messageId: 'm2',
          blockId: 'cfg-other',
          blockName: 'Same',
          blockType: 'infoblock',
          content: 'other',
          createdAt: 200,
        ),
      );

      final recent = await repo.getRecentBlocks('s1', 'cfg-Same', 10);

      expect(recent.map((b) => b.id).toList(), ['a']);
    });

    test('returns empty when no block matches the id', () async {
      await repo.insert(_block(id: 'a', messageId: 'm1', name: 'Status', createdAt: 100));

      final recent = await repo.getRecentBlocks('s1', 'cfg-Missing', 5);

      expect(recent, isEmpty);
    });
  });
}
