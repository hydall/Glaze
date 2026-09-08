import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_deletion_repo.dart';

const _sessionTables = <(String, String)>[
  ('chat_sessions', 'session_id'),
  ('memory_book_rows', 'session_id'),
  ('memory_catalog_rows', 'chat_session_id'),
  ('memory_entity_rows', 'chat_session_id'),
  ('memory_salience_rows', 'chat_session_id'),
  ('memory_cadence_rows', 'chat_session_id'),
  ('memory_consolidation_rows', 'chat_session_id'),
  ('tracker_rows', 'session_id'),
  ('tracker_snapshots', 'session_id'),
  ('ledger_reconciliation_checkpoints', 'session_id'),
  ('ledger_reconciliation_cleanup_journals', 'session_id'),
  ('character_knowledge_fact_rows', 'chat_session_id'),
  ('character_session_baseline_rows', 'chat_session_id'),
  ('studio_config_rows', 'session_id'),
  ('chat_summaries', 'session_id'),
  ('info_blocks', 'session_id'),
];

void main() {
  late AppDatabase db;
  late CharacterDeletionRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = CharacterDeletionRepo(db);
  });

  tearDown(() => db.close());

  test('atomically deletes all DB-owned character and session rows', () async {
    await _seedCharacter(db, 'target', sessionId: 'target-session');
    await _seedCharacter(db, 'control', sessionId: 'control-session');

    final result = await repo.deleteCharacters({'target'});

    expect(result.characterIds, {'target'});
    expect(result.sessionIds, {'target-session'});
    expect(result.studioConfigSessionIds, {'target-session'});
    expect(result.lorebookIds, {'target-lorebook'});
    await _expectCharacterCount(db, 'target', 'target-session', 0);
    await _expectCharacterCount(db, 'control', 'control-session', 1);
  });

  test(
    'rolls back character, lorebook, and complete session cascade',
    () async {
      await _seedCharacter(db, 'target', sessionId: 'target-session');
      await db.customStatement('''
      CREATE TRIGGER fail_character_delete
      BEFORE DELETE ON tracker_rows
      WHEN OLD.session_id = 'target-session'
      BEGIN
        SELECT RAISE(ABORT, 'test delete failure');
      END
    ''');

      await expectLater(repo.deleteCharacters({'target'}), throwsA(anything));

      await _expectCharacterCount(db, 'target', 'target-session', 1);
    },
  );

  test('bulk deletion promotes the lowest remaining variation once', () async {
    for (final (id, order) in [('cover', 0), ('second', 1), ('control', 2)]) {
      await db.customStatement(
        "INSERT INTO characters (char_id, name, variant_group_id, variant_order) VALUES ('$id', '$id', 'group', $order)",
      );
    }

    await repo.deleteCharacters({'cover', 'second'});

    final remaining = await (db.select(
      db.characters,
    )..where((row) => row.charId.equals('control'))).getSingle();
    expect(remaining.variantOrder, 0);
  });
}

Future<void> _seedCharacter(
  AppDatabase db,
  String characterId, {
  required String sessionId,
}) async {
  final id = characterId.replaceAll('-', '_');
  final lorebookId = '$characterId-lorebook';
  final statements = <String>[
    "INSERT INTO characters (char_id, name, variant_group_id) VALUES ('$characterId', '$characterId', '$characterId')",
    "INSERT INTO character_folders (folder_id, name) VALUES ('folder_$id', 'Folder')",
    "INSERT INTO character_folder_members (folder_id, char_id) VALUES ('folder_$id', '$characterId')",
    "INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) VALUES ('$sessionId', '$characterId', 0, '[]')",
    "INSERT INTO memory_book_rows (session_id) VALUES ('$sessionId')",
    "INSERT INTO memory_catalog_rows (id, chat_session_id, memory_entry_id) VALUES ('catalog_$id', '$sessionId', 'entry_$id')",
    "INSERT INTO memory_entity_rows (id, chat_session_id, memory_entry_id, name) VALUES ('entity_$id', '$sessionId', 'entry_$id', 'name')",
    "INSERT INTO memory_salience_rows (id, chat_session_id, memory_entry_id) VALUES ('salience_$id', '$sessionId', 'entry_$id')",
    "INSERT INTO memory_cadence_rows (chat_session_id) VALUES ('$sessionId')",
    "INSERT INTO memory_consolidation_rows (id, chat_session_id) VALUES ('consolidation_$id', '$sessionId')",
    "INSERT INTO tracker_rows (session_id, name) VALUES ('$sessionId', 'tracker')",
    "INSERT INTO tracker_snapshots (session_id, message_id) VALUES ('$sessionId', 'message')",
    "INSERT INTO ledger_reconciliation_checkpoints (session_id, start_message_id, end_message_id) VALUES ('$sessionId', 'start', 'end')",
    "INSERT INTO ledger_reconciliation_cleanup_journals (session_id, endpoint_message_id) VALUES ('$sessionId', 'end')",
    "INSERT INTO character_knowledge_fact_rows (id, chat_session_id, knower_key, subject_key, fact_class, predicate, object, epistemic_state) VALUES ('fact_$id', '$sessionId', 'knower', 'subject', 'fact', 'predicate', 'object', 'known')",
    "INSERT INTO character_session_baseline_rows (chat_session_id, character_id, baseline_card_json, baseline_hash) VALUES ('$sessionId', '$characterId', '{}', 'hash')",
    "INSERT INTO studio_config_rows (session_id) VALUES ('$sessionId')",
    "INSERT INTO chat_summaries (session_id, content) VALUES ('$sessionId', 'summary')",
    "INSERT INTO info_blocks (id, session_id, message_id, block_id, block_name, block_type, content) VALUES ('block_$id', '$sessionId', 'message', 'block', 'Block', 'info', 'content')",
    "INSERT INTO embeddings (entry_id, source_type, source_id) VALUES ('chat_embedding_$id', 'chat_message', '$sessionId')",
    "INSERT INTO lorebooks (lorebook_id, name, activation_scope, activation_target_id, entries_json) VALUES ('$lorebookId', 'Lorebook', 'character', '$characterId', '[]')",
    "INSERT INTO embeddings (entry_id, source_type, source_id) VALUES ('character_embedding_$id', 'lorebook_entry', '$lorebookId')",
    "INSERT INTO lorebooks (lorebook_id, name, activation_scope, activation_target_id, entries_json) VALUES ('chat_lorebook_$id', 'Chat Lorebook', 'chat', '$sessionId', '[]')",
    "INSERT INTO embeddings (entry_id, source_type, source_id) VALUES ('chat_lorebook_embedding_$id', 'lorebook_entry', 'chat_lorebook_$id')",
  ];
  for (final statement in statements) {
    await db.customStatement(statement);
  }
}

Future<void> _expectCharacterCount(
  AppDatabase db,
  String characterId,
  String sessionId,
  int expected,
) async {
  for (final (table, column, value) in [
    ('characters', 'char_id', characterId),
    ('character_folder_members', 'char_id', characterId),
    ..._sessionTables.map((item) => (item.$1, item.$2, sessionId)),
  ]) {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS count FROM $table WHERE $column = ?',
          variables: [Variable.withString(value)],
        )
        .getSingle();
    expect(row.read<int>('count'), expected, reason: table);
  }

  for (final (table, predicate, value) in [
    (
      'lorebooks',
      "activation_scope = 'character' AND activation_target_id = ?",
      characterId,
    ),
    (
      'lorebooks',
      "activation_scope = 'chat' AND activation_target_id = ?",
      sessionId,
    ),
    ('embeddings', "source_type = 'chat_message' AND source_id = ?", sessionId),
    (
      'embeddings',
      "source_type = 'lorebook_entry' AND source_id = ?",
      '$characterId-lorebook',
    ),
    (
      'embeddings',
      "source_type = 'lorebook_entry' AND source_id = ?",
      'chat_lorebook_${characterId.replaceAll('-', '_')}',
    ),
  ]) {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS count FROM $table WHERE $predicate',
          variables: [Variable.withString(value)],
        )
        .getSingle();
    expect(row.read<int>('count'), expected, reason: '$table: $value');
  }
}
