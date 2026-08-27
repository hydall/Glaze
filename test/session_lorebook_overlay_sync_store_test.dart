import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_lorebook_evolution_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/features/cloud_sync/adapters/ext_blocks_sync_stores.dart';

void main() {
  const sessionId = 'session-1';
  const sourceText = 'The district is dangerous.';
  const evolvedText = 'The district is dangerous but lively.';
  const lorebook = Lorebook(
    id: 'book',
    name: 'Book',
    entries: [LorebookEntry(id: 'district', content: sourceText)],
  );

  late AppDatabase db;
  late SessionLorebookOverlaySyncStore store;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = SessionLorebookOverlaySyncStore(db);
    await ChatRepo(db).put(
      const ChatSession(
        id: sessionId,
        characterId: 'character',
        sessionIndex: 0,
      ),
    );
    await LorebookRepo(db).put(lorebook);
  });

  tearDown(() => db.close());

  SessionLorebookEvolutionRow overlay({
    String content = evolvedText,
    int createdAt = 10,
    int updatedAt = 20,
  }) => SessionLorebookEvolutionRow(
    chatSessionId: sessionId,
    lorebookId: lorebook.id,
    entryId: lorebook.entries.single.id,
    baseContent: sourceText,
    baseContentHash: CardCanonicalizer.scalarSha256(sourceText),
    content: content,
    contentHash: CardCanonicalizer.scalarSha256(content),
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  Future<void> insertOverlay(SessionLorebookEvolutionRow row) =>
      db.into(db.sessionLorebookEvolutionRows).insert(row);

  test('round-trips effective lore without changing the global book', () async {
    await insertOverlay(overlay());
    final payload = await store.getBySessionId(sessionId);

    await (db.delete(
      db.sessionLorebookEvolutionRows,
    )..where((row) => row.chatSessionId.equals(sessionId))).go();
    await store.applyBySessionId(sessionId, payload!);

    final effective = await SessionLorebookEvolutionRepo(
      db,
    ).applyOverlays(sessionId: sessionId, lorebooks: const [lorebook]);
    expect(effective.single.entries.single.content, evolvedText);
    expect(
      (await LorebookRepo(db).getById(lorebook.id))!.entries.single.content,
      sourceText,
    );
    expect(await store.getBySessionId(sessionId), payload);
  });

  test('identical projection preserves local canon provenance', () async {
    await insertOverlay(overlay(createdAt: 99, updatedAt: 100));
    await db.customStatement(
      '''INSERT INTO session_canon_checkpoint_rows
      (id, chat_session_id, sequence, character_id, character_revision,
       character_revision_hash, created_at)
      VALUES (?, ?, 0, ?, 1, ?, 1)''',
      ['checkpoint', sessionId, 'character', 'revision-hash'],
    );
    await db.customStatement(
      '''INSERT INTO session_canon_checkpoint_rows
      (id, chat_session_id, sequence, parent_checkpoint_id, character_id,
       character_revision, character_revision_hash, anchor_message_id,
       created_at)
      VALUES (?, ?, 1, ?, ?, 1, ?, ?, 2)''',
      [
        'checkpoint-2',
        sessionId,
        'checkpoint',
        'character',
        'revision-hash',
        'message-1',
      ],
    );
    await db.customStatement(
      '''INSERT INTO session_lorebook_revision_rows
      (checkpoint_id, chat_session_id, lorebook_id, entry_id,
       base_content_hash, previous_content_hash, content, content_hash,
       rewrite_operation_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)''',
      [
        'checkpoint',
        sessionId,
        'book',
        'district',
        CardCanonicalizer.scalarSha256(sourceText),
        CardCanonicalizer.scalarSha256(sourceText),
        evolvedText,
        CardCanonicalizer.scalarSha256(evolvedText),
        'operation',
      ],
    );

    final payload = await store.getBySessionId(sessionId);
    await store.applyBySessionId(sessionId, payload!);

    expect(await db.select(db.sessionCanonCheckpointRows).get(), hasLength(2));
    expect(await db.select(db.sessionLorebookRevisionRows).get(), hasLength(1));
    expect(await db.select(db.sessionLorebookEmbeddingJobRows).get(), isEmpty);
  });

  test('divergent projection resets lore history and queues reindex', () async {
    await insertOverlay(overlay(content: 'Old local content'));
    await db.customStatement(
      '''INSERT INTO session_canon_checkpoint_rows
      (id, chat_session_id, sequence, character_id, character_revision,
       character_revision_hash, created_at)
      VALUES (?, ?, 0, ?, 1, ?, 1)''',
      ['checkpoint', sessionId, 'character', 'revision-hash'],
    );
    await db.customStatement(
      '''INSERT INTO session_canon_checkpoint_rows
      (id, chat_session_id, sequence, parent_checkpoint_id, character_id,
       character_revision, character_revision_hash, anchor_message_id,
       created_at)
      VALUES (?, ?, 1, ?, ?, 1, ?, ?, 2)''',
      [
        'checkpoint-2',
        sessionId,
        'checkpoint',
        'character',
        'revision-hash',
        'message-1',
      ],
    );
    await db.customStatement(
      '''INSERT INTO session_lorebook_revision_rows
      (checkpoint_id, chat_session_id, lorebook_id, entry_id,
       base_content_hash, previous_content_hash, content, content_hash,
       rewrite_operation_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)''',
      [
        'checkpoint',
        sessionId,
        'book',
        'district',
        CardCanonicalizer.scalarSha256(sourceText),
        CardCanonicalizer.scalarSha256(sourceText),
        'Old local content',
        CardCanonicalizer.scalarSha256('Old local content'),
        'operation',
      ],
    );

    final incoming = {
      '__sessionLorebookOverlays': true,
      'schemaVersion': 1,
      'sessionId': sessionId,
      'overlays': [
        overlay().toJson()
          ..remove('createdAt')
          ..remove('updatedAt'),
      ],
    };
    await store.applyBySessionId(sessionId, incoming);

    expect(await db.select(db.sessionCanonCheckpointRows).get(), hasLength(2));
    final revisions = await db.select(db.sessionLorebookRevisionRows).get();
    expect(revisions, hasLength(1));
    expect(revisions.single.content, evolvedText);
    expect(revisions.single.checkpointId, 'checkpoint');
    expect(revisions.single.rewriteOperationId, startsWith('cloud-overlay@'));
    final jobs = await db.select(db.sessionLorebookEmbeddingJobRows).get();
    expect(jobs, hasLength(1));
    expect(jobs.single.operation, 'reindex');
    expect((await store.getBySessionId(sessionId))!['overlays'], hasLength(1));
  });

  test(
    'rejects malformed aggregate without changing local projection',
    () async {
      await insertOverlay(overlay(content: 'Local content'));
      final before = await store.getBySessionId(sessionId);
      final incoming = {
        '__sessionLorebookOverlays': true,
        'schemaVersion': 1,
        'sessionId': sessionId,
        'overlays': [
          {...overlay().toJson(), 'contentHash': 'tampered'},
        ],
      };

      await expectLater(
        store.applyBySessionId(sessionId, incoming),
        throwsA(isA<FormatException>()),
      );
      expect(await store.getBySessionId(sessionId), before);
    },
  );

  test('accepts a historical base after the global entry changes', () async {
    await LorebookRepo(db).put(
      lorebook.copyWith(
        entries: const [
          LorebookEntry(id: 'district', content: 'A newer global source.'),
        ],
      ),
    );
    final payload = {
      '__sessionLorebookOverlays': true,
      'schemaVersion': 1,
      'sessionId': sessionId,
      'overlays': [
        {
          'chatSessionId': sessionId,
          'lorebookId': 'book',
          'entryId': 'district',
          'baseContent': sourceText,
          'baseContentHash': CardCanonicalizer.scalarSha256(sourceText),
          'content': evolvedText,
          'contentHash': CardCanonicalizer.scalarSha256(evolvedText),
        },
      ],
    };

    await store.applyBySessionId(sessionId, payload);

    expect((await store.getBySessionId(sessionId))!['overlays'], hasLength(1));
    expect(
      (await LorebookRepo(db).getById('book'))!.entries.single.content,
      'A newer global source.',
    );
  });

  test('explicit empty aggregate clears only session-local state', () async {
    await insertOverlay(overlay());

    await store.applyBySessionId(sessionId, {
      '__sessionLorebookOverlays': true,
      'schemaVersion': 1,
      'sessionId': sessionId,
      'overlays': <dynamic>[],
    });

    expect(await store.getBySessionId(sessionId), isNull);
    expect(await db.select(db.sessionLorebookEmbeddingJobRows).get(), isEmpty);
    expect(
      (await LorebookRepo(db).getById('book'))!.entries.single.content,
      sourceText,
    );
  });

  test('rejects a missing source target atomically', () async {
    await insertOverlay(overlay(content: 'Local content'));
    final before = await store.getBySessionId(sessionId);
    final payload = {
      '__sessionLorebookOverlays': true,
      'schemaVersion': 1,
      'sessionId': sessionId,
      'overlays': [
        {
          'chatSessionId': sessionId,
          'lorebookId': 'missing-book',
          'entryId': 'entry',
          'baseContent': sourceText,
          'baseContentHash': CardCanonicalizer.scalarSha256(sourceText),
          'content': evolvedText,
          'contentHash': CardCanonicalizer.scalarSha256(evolvedText),
        },
      ],
    };

    await expectLater(
      store.applyBySessionId(sessionId, payload),
      throwsA(isA<FormatException>()),
    );
    expect(await store.getBySessionId(sessionId), before);
  });
}
