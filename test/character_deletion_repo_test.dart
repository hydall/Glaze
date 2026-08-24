import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_deletion_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_deletion_repo.dart';

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
  ('reconciliation_successful_runs', 'session_id'),
  ('ledger_reconciliation_effects', 'session_id'),
  ('reconciliation_run_invalidations', 'session_id'),
  ('ledger_reconciliation_cursors', 'session_id'),
  ('character_knowledge_fact_rows', 'chat_session_id'),
  ('applied_canon_transition_rows', 'chat_session_id'),
  ('rewrite_jobs', 'chat_session_id'),
  ('rewrite_operations', 'chat_session_id'),
  ('character_session_baseline_rows', 'chat_session_id'),
  ('studio_config_rows', 'session_id'),
  ('chat_summaries', 'session_id'),
  ('info_blocks', 'session_id'),
  ('ledger_debug_runs', 'session_id'),
  ('card_evolution_debug_runs', 'session_id'),
  ('llm_request_capture_rows', 'session_id'),
  ('llm_call_event_rows', 'session_id'),
  ('card_evolution_claims', 'session_id'),
  ('card_evolution_writer_calls', 'session_id'),
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

  test('deleting the group representative preserves a shared lorebook', () async {
    await db.customStatement(
      "INSERT INTO characters (char_id, name, variant_group_id, variant_order) VALUES ('cover', 'cover', 'cover', 0)",
    );
    await db.customStatement(
      "INSERT INTO characters (char_id, name, variant_group_id, variant_order) VALUES ('variant', 'variant', 'cover', 1)",
    );
    await db.customStatement(
      "INSERT INTO lorebooks (lorebook_id, name, activation_scope, activation_target_id, entries_json) VALUES ('shared', 'Shared', 'character', 'cover', '[]')",
    );

    final result = await repo.deleteCharacters({'cover'});

    expect(result.lorebookIds, isEmpty);
    expect(
      await (db.select(
        db.lorebooks,
      )..where((row) => row.lorebookId.equals('shared'))).getSingleOrNull(),
      isNot(equals(null)),
    );
  });

  test(
    'session deletion retains global transitions until character deletion',
    () async {
      await _seedCharacter(db, 'target', sessionId: 'target-session');
      await db.customStatement('''
      INSERT INTO applied_canon_transition_rows
      (id, chat_session_id, character_id, rewrite_operation_id, revision,
       revision_hash, semantic_scope_key, canonical_claim,
       promotion_destination, affected_tracker_keys_json, transition_json)
      VALUES ('global-transition', NULL, 'target', 'global-operation', 2,
              'global-hash', 'scope', 'claim', 'destination', '["tracker"]', '{}')
    ''');

      await SessionDeletionRepo(db).deleteSession('target-session');

      var count = await db
          .customSelect(
            "SELECT COUNT(*) AS count FROM applied_canon_transition_rows WHERE id = 'global-transition'",
          )
          .getSingle();
      expect(count.read<int>('count'), 1);

      await repo.deleteCharacters({'target'});

      count = await db
          .customSelect(
            "SELECT COUNT(*) AS count FROM applied_canon_transition_rows WHERE id = 'global-transition'",
          )
          .getSingle();
      expect(count.read<int>('count'), 0);
    },
  );
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
    "INSERT INTO reconciliation_successful_runs (id, session_id, ordinal, start_message_id, start_swipe_id, start_agent_swipe_id, end_message_id, end_swipe_id, end_agent_swipe_id, anchors_json, range_hash, accepted_manifest_refs_json, effective_canon_stamp, effective_canon_revision, effective_canon_hash, canonical_result_json, content_hash, predecessor_chain_hash, chain_hash, contract_version, ops_applied_json, created_at) VALUES ('run_$id', '$sessionId', 1, 'message', 0, 0, 'message', 0, 0, '[{\"agentSwipeId\":0,\"contentHash\":\"content\",\"messageId\":\"message\",\"role\":\"assistant\",\"swipeId\":0}]', 'range', '[]', 'stamp', 1, 'canon', '{}', 'content', '', 'chain', 1, '[]', 1)",
    "INSERT INTO ledger_reconciliation_effects (run_id, session_id, before_ledger_json, after_ledger_json, before_knowledge_json, after_knowledge_json, actual_effects_json, before_state_hash, after_state_hash, effects_hash, created_at) VALUES ('run_$id', '$sessionId', '[]', '[]', '[]', '[]', '{}', 'before', 'after', 'effects', 1)",
    "INSERT INTO reconciliation_run_invalidations (session_id, run_id, cause_message_id, reason, created_at) VALUES ('$sessionId', 'run_$id', 'message', 'deleted', 1)",
    "INSERT INTO ledger_reconciliation_cursors (session_id, sequence, predecessor_hash, through_run_id, through_run_ordinal, through_run_chain_hash, cursor_hash, created_at) VALUES ('$sessionId', 1, '', 'run_$id', 1, 'chain', 'cursor', 1)",
    "INSERT INTO character_knowledge_fact_rows (id, chat_session_id, knower_key, subject_key, fact_class, predicate, object, epistemic_state) VALUES ('fact_$id', '$sessionId', 'knower', 'subject', 'fact', 'predicate', 'object', 'known')",
    "INSERT INTO character_revision_rows (character_id, revision, revision_hash, snapshot_json) VALUES ('$characterId', '1', 'hash_$id', '{}')",
    "INSERT INTO applied_canon_transition_rows (id, chat_session_id, character_id, transition_json) VALUES ('transition_$id', '$sessionId', '$characterId', '{}')",
    "INSERT INTO canon_transition_fact_refs (applied_canon_transition_id, character_knowledge_fact_id) VALUES ('transition_$id', 'fact_$id')",
    "INSERT INTO rewrite_jobs (id, chat_session_id, character_id) VALUES ('job_$id', '$sessionId', '$characterId')",
    "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id) VALUES ('operation_$id', 'job_$id', '$sessionId')",
    "INSERT INTO rewrite_operation_revisions (rewrite_operation_id, revision, snapshot_json) VALUES ('operation_$id', '1', '{}')",
    "INSERT INTO rewrite_evidence_rows (id, rewrite_operation_id, evidence_json) VALUES ('evidence_$id', 'operation_$id', '{}')",
    "INSERT INTO character_session_baseline_rows (chat_session_id, character_id, baseline_card_json, baseline_hash) VALUES ('$sessionId', '$characterId', '{}', 'hash')",
    "INSERT INTO studio_config_rows (session_id) VALUES ('$sessionId')",
    "INSERT INTO chat_summaries (session_id, content) VALUES ('$sessionId', 'summary')",
    "INSERT INTO info_blocks (id, session_id, message_id, block_id, block_name, block_type, content) VALUES ('block_$id', '$sessionId', 'message', 'block', 'Block', 'info', 'content')",
    "INSERT INTO ledger_debug_runs (id, session_id, kind, status, created_at) VALUES ('ledger_debug_$id', '$sessionId', 'normal', 'ok', 1)",
    "INSERT INTO card_evolution_debug_runs (session_id, stage, status, model, output, attempts_json, updated_at) VALUES ('$sessionId', 'card', 'ok', 'model', 'output', '[]', 1)",
    "INSERT INTO card_evolution_claims (id, session_id, character_id, owner_id, status, lease_expires_at, first_run_id, second_run_id, predecessor_cursor_hash, predecessor_run_ordinal, input_hash, selected_input_json, created_at) VALUES ('claim_$id', '$sessionId', '$characterId', 'owner', 'claimed', 100, 'history', 'canon', 'cursor', 1, 'input', '{}', 1)",
    "INSERT INTO card_evolution_writer_calls (id, claim_id, session_id, ordinal, stage, stage_ordinal, status, prompt, prompt_hash, created_at, updated_at) VALUES ('writer_call_$id', 'claim_$id', '$sessionId', 1, 'card_writer', 1, 'prepared', 'prompt', 'hash', 1, 1)",
    "INSERT INTO llm_request_capture_rows (sequence, created_at_ms, session_id, stage, truncated, event_json) VALUES (1, 1, '$sessionId', 'studio.final', 0, '{}')",
    "INSERT INTO llm_call_event_rows (id, created_at_ms, session_id, pipeline_run_id, call_id, stage, kind) VALUES ('event-$sessionId', 1, '$sessionId', 'pipeline-$sessionId', 'call-$sessionId', 'studio.final', 'transport_succeeded')",
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
    ('character_revision_rows', 'character_id', characterId),
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

  final provenanceChildren = [
    (
      'rewrite_operation_revisions',
      'rewrite_operation_id',
      'operation_${characterId.replaceAll('-', '_')}',
    ),
    (
      'rewrite_evidence_rows',
      'rewrite_operation_id',
      'operation_${characterId.replaceAll('-', '_')}',
    ),
    (
      'canon_transition_fact_refs',
      'applied_canon_transition_id',
      'transition_${characterId.replaceAll('-', '_')}',
    ),
  ];
  for (final (table, column, value) in provenanceChildren) {
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
