import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';

void main() {
  late AppDatabase db;
  late EmbeddingRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = EmbeddingRepo(db);
  });

  tearDown(() => db.close());

  test('getBySource applies source type and source id predicates', () async {
    for (final row in [
      ('chat-s1', 'chat_message', 's1'),
      ('chat-s2', 'chat_message', 's2'),
      ('memory-s1', 'memory_entry', 's1'),
    ]) {
      await repo.putEmbeddingVector(
        entryId: row.$1,
        sourceType: row.$2,
        sourceId: row.$3,
        vectors: const [
          [1, 0],
        ],
        textHash: row.$1,
      );
    }

    final rows = await repo.getBySource('chat_message', 's1');

    expect(rows.map((row) => row.entryId), ['chat-s1']);
  });

  test('getBySourceIds applies source type and source id predicates', () async {
    for (final row in [
      ('one_shared', 'lorebook_entry', 'one'),
      ('two_shared', 'lorebook_entry', 'two'),
      ('three_shared', 'lorebook_entry', 'three'),
      ('memory-one', 'memory_entry', 'one'),
    ]) {
      await repo.putEmbeddingVector(
        entryId: row.$1,
        sourceType: row.$2,
        sourceId: row.$3,
        vectors: const [
          [1, 0],
        ],
        textHash: row.$1,
      );
    }

    final rows = await repo.getBySourceIds('lorebook_entry', ['one', 'two']);

    expect(rows.map((row) => row.entryId).toSet(), {
      'one_shared',
      'two_shared',
    });
    expect(await repo.getBySourceIds('lorebook_entry', const []), isEmpty);
  });

  test('bulk entry deletion is scoped to source type and source id', () async {
    for (final row in [
      ('chat-s1-stale', 'chat_message', 's1'),
      ('chat-s1-keep', 'chat_message', 's1'),
      ('chat-s2-stale', 'chat_message', 's2'),
      ('memory-s1-stale', 'memory_entry', 's1'),
    ]) {
      await repo.putEmbeddingVector(
        entryId: row.$1,
        sourceType: row.$2,
        sourceId: row.$3,
        vectors: const [
          [1, 0],
        ],
        textHash: row.$1,
      );
    }

    await repo.deleteBySourceAndEntryIds('chat_message', 's1', [
      'chat-s1-stale',
      'chat-s2-stale',
      'memory-s1-stale',
    ]);

    expect(await repo.getByEntryId('chat-s1-stale'), isNull);
    expect(await repo.getByEntryId('chat-s1-keep'), isNotNull);
    expect(await repo.getByEntryId('chat-s2-stale'), isNotNull);
    expect(await repo.getByEntryId('memory-s1-stale'), isNotNull);
  });

  test('composite source query uses the composite index', () async {
    final plan = await db
        .customSelect(
          'EXPLAIN QUERY PLAN SELECT * FROM embeddings '
          'WHERE source_type = ? AND source_id = ?',
          variables: [
            Variable.withString('chat_message'),
            Variable.withString('s1'),
          ],
        )
        .get();

    expect(
      plan.map((row) => row.read<String>('detail')).join('\n'),
      contains('idx_embeddings_source_type_id'),
    );
  });
}
