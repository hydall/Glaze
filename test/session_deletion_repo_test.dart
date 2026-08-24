import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/session_deletion_repo.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_use_manifest_repo.dart';
import 'package:glaze_flutter/core/llm/prompt/exact_lorebook_manifest.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';

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
  ('character_session_baseline_rows', 'chat_session_id'),
  ('session_lorebook_evolution_rows', 'chat_session_id'),
  ('session_canon_checkpoint_rows', 'chat_session_id'),
  ('session_lorebook_revision_rows', 'chat_session_id'),
  ('session_lorebook_embedding_job_rows', 'chat_session_id'),
  ('studio_config_rows', 'session_id'),
  ('chat_summaries', 'session_id'),
  ('info_blocks', 'session_id'),
  ('ledger_debug_runs', 'session_id'),
  ('card_evolution_debug_runs', 'session_id'),
  ('llm_request_capture_rows', 'session_id'),
  ('llm_call_event_rows', 'session_id'),
];

void main() {
  late AppDatabase db;
  late SessionDeletionRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = SessionDeletionRepo(db);
  });

  tearDown(() => db.close());

  test(
    'deletes every session-owned row and preserves another session',
    () async {
      await _seedSession(db, 'target');
      await _seedSession(db, 'control');
      await _seedLorebookUse(db, 'target');
      await _seedLorebookUse(db, 'control');

      await repo.deleteSession('target');

      await _expectSessionCount(db, 'target', 0);
      await _expectSessionCount(db, 'control', 1);
      expect(
        await _count(db, 'lorebook_use_manifests', 'session_id = ?', 'target'),
        0,
      );
      expect(
        await _count(
          db,
          'lorebook_use_manifest_entries',
          'session_id = ?',
          'target',
        ),
        0,
      );
      expect(
        await _count(
          db,
          'lorebook_use_acceptance_records',
          'session_id = ?',
          'target',
        ),
        0,
      );
      expect(
        await _count(db, 'lorebook_use_manifests', 'session_id = ?', 'control'),
        1,
      );

      await repo.deleteSession('target');
      await _expectSessionCount(db, 'target', 0);
      await _expectSessionCount(db, 'control', 1);
    },
  );

  test('rolls back the complete cascade when a delete fails', () async {
    await _seedSession(db, 'target');
    await db.customStatement('''
      CREATE TRIGGER fail_session_delete
      BEFORE DELETE ON tracker_rows
      WHEN OLD.session_id = 'target'
      BEGIN
        SELECT RAISE(ABORT, 'test delete failure');
      END
    ''');

    await expectLater(repo.deleteSession('target'), throwsA(anything));

    await _expectSessionCount(db, 'target', 1);
  });

  test('clear preserves session configuration and explicit greeting', () async {
    await _seedSession(db, 'target');
    await _seedSession(db, 'control');
    await db.customStatement(
      '''
      UPDATE chat_sessions
      SET messages_json = ?, session_vars_json = ?, authors_note_json = ?,
          draft = 'draft', last_scroll_anchor_json = '{"messageId":"old"}'
      WHERE session_id = 'target'
      ''',
      [
        jsonEncode([
          const ChatMessage(
            id: 'old',
            role: 'user',
            content: 'Old message',
          ).toJson(),
        ]),
        jsonEncode({
          'sessionName': 'Configured chat',
          'branchedAt': '123',
          ChatSessionX.deletedMessagesVarKey: '4',
          'chatConfig': 'keep',
        }),
        jsonEncode(const AuthorsNote(content: 'Keep note').toJson()),
      ],
    );
    await db.customStatement('''
      UPDATE memory_book_rows
      SET entries_json = '[{"id":"entry","title":"title","keys":[],"content":"memory"}]',
          pending_drafts_json = '[{"id":"draft","title":"draft","content":"memory"}]',
          settings_json = '{"enabled":false,"memoryMode":"manual"}',
          last_processed_message_count = 9
      WHERE session_id = 'target'
      ''');
    const greeting = ChatMessage(
      id: 'greeting',
      role: 'assistant',
      content: 'Fresh greeting',
    );

    final cleared = await repo.clearSession(
      sessionId: 'target',
      replacementMessages: const [greeting],
      resetBranchStamp: true,
      countDeletedMessages: true,
    );

    expect(cleared != null, isTrue);
    expect(cleared!.id, 'target');
    expect(cleared.characterId, 'char_target');
    expect(cleared.sessionIndex, 0);
    expect(cleared.messages, const [greeting]);
    expect(cleared.sessionVars['sessionName'], 'Configured chat');
    expect(cleared.sessionVars['chatConfig'], 'keep');
    expect(cleared.sessionVars.containsKey('branchedAt'), isFalse);
    expect(cleared.deletedMessageCount, 5);
    expect(cleared.authorsNote?.content, 'Keep note');
    expect(cleared.draft, 'draft');
    expect(cleared.lastScrollAnchor, {'messageId': 'old'});

    await _expectClearGroups(db, 'target');
    await _expectSessionCount(db, 'control', 1);
  });

  test(
    'clear supports the history empty-message behavior and rolls back',
    () async {
      await _seedSession(db, 'target');
      await db.customStatement(
        "UPDATE chat_sessions SET messages_json = '[{\"id\":\"old\",\"role\":\"user\",\"content\":\"Old\"}]' WHERE session_id = 'target'",
      );
      await db.customStatement('''
      CREATE TRIGGER fail_clear
      BEFORE DELETE ON tracker_rows
      WHEN OLD.session_id = 'target'
      BEGIN
        SELECT RAISE(ABORT, 'test clear failure');
      END
    ''');

      await expectLater(
        repo.clearSession(sessionId: 'target', replacementMessages: const []),
        throwsA(anything),
      );

      final session = await db
          .customSelect(
            "SELECT messages_json FROM chat_sessions WHERE session_id = 'target'",
          )
          .getSingle();
      expect(session.read<String>('messages_json'), contains('old'));
      await _expectSessionCount(db, 'target', 1);
    },
  );
}

Future<void> _seedSession(AppDatabase db, String sessionId) async {
  final id = sessionId.replaceAll('-', '_');
  final statements = <String>[
    "INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) VALUES ('$sessionId', 'char_$id', 0, '[]')",
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
    "INSERT INTO applied_canon_transition_rows (id, chat_session_id, character_id, transition_json) VALUES ('transition_$id', '$sessionId', 'char_$id', '{}')",
    "INSERT INTO canon_transition_fact_refs (applied_canon_transition_id, character_knowledge_fact_id) VALUES ('transition_$id', 'fact_$id')",
    "INSERT INTO rewrite_jobs (id, chat_session_id, character_id) VALUES ('job_$id', '$sessionId', 'char_$id')",
    "INSERT INTO rewrite_operations (id, rewrite_job_id, chat_session_id) VALUES ('operation_$id', 'job_$id', '$sessionId')",
    "INSERT INTO rewrite_operation_revisions (rewrite_operation_id, revision, snapshot_json) VALUES ('operation_$id', '1', '{}')",
    "INSERT INTO rewrite_evidence_rows (id, rewrite_operation_id, evidence_json) VALUES ('evidence_$id', 'operation_$id', '{}')",
    "INSERT INTO character_session_baseline_rows (chat_session_id, character_id, baseline_card_json, baseline_hash) VALUES ('$sessionId', 'char_$id', '{}', 'hash')",
    "INSERT INTO session_lorebook_evolution_rows (chat_session_id, lorebook_id, entry_id, base_content, base_content_hash, content, content_hash, created_at, updated_at) VALUES ('$sessionId', 'source_book_$id', 'entry_$id', 'base', 'base_hash', 'evolved', 'evolved_hash', 1, 1)",
    "INSERT INTO session_canon_checkpoint_rows (id, chat_session_id, sequence, character_id, character_revision, character_revision_hash, created_at) VALUES ('checkpoint_$id', '$sessionId', 0, 'char_$id', 1, 'card_hash', 1)",
    "INSERT INTO session_lorebook_revision_rows (checkpoint_id, chat_session_id, lorebook_id, entry_id, base_content_hash, previous_content_hash, content, content_hash, rewrite_operation_id, created_at) VALUES ('checkpoint_$id', '$sessionId', 'source_book_$id', 'entry_$id', 'base_hash', 'base_hash', 'evolved', 'evolved_hash', 'operation_$id', 1)",
    "INSERT INTO session_lorebook_embedding_job_rows (id, chat_session_id, checkpoint_id, lorebook_id, entry_id, expected_content_hash, operation, created_at, updated_at) VALUES ('embedding_job_$id', '$sessionId', 'checkpoint_$id', 'source_book_$id', 'entry_$id', 'evolved_hash', 'reindex', 1, 1)",
    "INSERT INTO studio_config_rows (session_id) VALUES ('$sessionId')",
    "INSERT INTO chat_summaries (session_id, content) VALUES ('$sessionId', 'summary')",
    "INSERT INTO info_blocks (id, session_id, message_id, block_id, block_name, block_type, content) VALUES ('block_$id', '$sessionId', 'message', 'block', 'Block', 'info', 'content')",
    "INSERT INTO ledger_debug_runs (id, session_id, kind, status, created_at) VALUES ('ledger_debug_$id', '$sessionId', 'normal', 'ok', 1)",
    "INSERT INTO card_evolution_debug_runs (session_id, stage, status, model, output, attempts_json, updated_at) VALUES ('$sessionId', 'card', 'ok', 'model', 'output', '[]', 1)",
    "INSERT INTO llm_request_capture_rows (sequence, created_at_ms, session_id, stage, truncated, event_json) VALUES (1, 1, '$sessionId', 'studio.final', 0, '{}')",
    "INSERT INTO llm_call_event_rows (id, created_at_ms, session_id, pipeline_run_id, call_id, stage, kind) VALUES ('event-$sessionId', 1, '$sessionId', 'pipeline-$sessionId', 'call-$sessionId', 'studio.final', 'transport_succeeded')",
    "INSERT INTO embeddings (entry_id, source_type, source_id) VALUES ('embedding_$id', 'chat_message', '$sessionId')",
    "INSERT INTO embeddings (entry_id, source_type, source_id) VALUES ('memory_embedding_$id', 'memory_entry', 'memorybook_char_${id}_$sessionId')",
    "INSERT INTO embeddings (entry_id, source_type, source_id) VALUES ('lorebook_embedding_$id', 'lorebook_entry', 'lorebook_$id')",
    "INSERT INTO embeddings (entry_id, source_type, source_id) VALUES ('session_lorebook_embedding_$id', 'session_lorebook_entry', '$sessionId')",
    "INSERT INTO lorebooks (lorebook_id, name, activation_scope, activation_target_id, entries_json) VALUES ('lorebook_$id', 'Lorebook', 'chat', '$sessionId', '[]')",
  ];
  for (final statement in statements) {
    await db.customStatement(statement);
  }
}

Future<void> _seedLorebookUse(AppDatabase db, String sessionId) async {
  final repo = LorebookUseManifestRepo(db);
  final identity = LorebookUseGenerationIdentity(
    sessionId: sessionId,
    messageId: 'message',
    swipeId: 0,
    agentSwipeId: 0,
  );
  final durable = _durableManifest('session-$sessionId');
  await repo.insertGenerationManifest(
    identity: identity,
    manifest: LorebookUseManifestInput(
      manifestJson: durable.canonicalJson,
      manifestHash: durable.canonicalHash,
      manifestSchemaVersion: 1,
      finalPromptHash: durable.providerMessagesHash,
      presetSnapshotHash: durable.promptProvenance.presetSnapshotHash,
    ),
    createdAt: 1,
    entries: [
      LorebookUseManifestEntryInput(
        lorebookId: durable.entries.single.lorebookId,
        entryId: durable.entries.single.entryId,
        entryOrder: 0,
        evidenceJson: jsonEncode(durable.entries.single.toJson()),
      ),
    ],
  );
  await repo.insertVariationAcceptance(
    acceptanceId: 'acceptance-$sessionId',
    identity: identity,
    acceptedByUserMessageId: 'user',
    acceptedAt: 2,
  );
}

ExactLorebookManifest _durableManifest(String id) => ExactLorebookManifest(
  entries: [
    ExactLorebookManifestEntry.fromMergedEntry(
      entry: LorebookEntry(
        id: 'entry-$id',
        lorebookId: 'book-$id',
        content: 'lore-$id',
        position: 'worldInfoBefore',
        order: 0,
      ),
      source: 'keyword',
      classification: 'worldInfoBefore',
      injectionIndex: 0,
      renderedContent: 'rendered-$id',
    ),
  ],
  promptProvenance: const ExactLorebookPromptProvenance(
    characterId: 'character',
    presetSnapshotHash: 'preset',
  ),
  providerMessagesHash: 'prompt',
);

Future<void> _expectClearGroups(AppDatabase db, String sessionId) async {
  const deletedTables = <(String, String)>[
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
    ('card_evolution_claims', 'session_id'),
    ('character_knowledge_fact_rows', 'chat_session_id'),
    ('chat_summaries', 'session_id'),
    ('info_blocks', 'session_id'),
    ('ledger_debug_runs', 'session_id'),
    ('card_evolution_debug_runs', 'session_id'),
    ('llm_request_capture_rows', 'session_id'),
    ('llm_call_event_rows', 'session_id'),
  ];
  for (final (table, column) in deletedTables) {
    final count = await _count(db, table, '$column = ?', sessionId);
    expect(count, 0, reason: table);
  }

  for (final (table, column) in const [
    ('chat_sessions', 'session_id'),
    ('character_session_baseline_rows', 'chat_session_id'),
    ('studio_config_rows', 'session_id'),
    ('lorebooks', 'activation_target_id'),
    ('session_lorebook_evolution_rows', 'chat_session_id'),
    ('session_canon_checkpoint_rows', 'chat_session_id'),
    ('session_lorebook_revision_rows', 'chat_session_id'),
    ('session_lorebook_embedding_job_rows', 'chat_session_id'),
  ]) {
    final count = await _count(db, table, '$column = ?', sessionId);
    expect(count, 1, reason: table);
  }

  // Clear chat keeps durable rewrite provenance and all of its children.
  final id = sessionId.replaceAll('-', '_');
  for (final (table, predicate, value) in [
    ('applied_canon_transition_rows', 'chat_session_id = ?', sessionId),
    ('rewrite_jobs', 'chat_session_id = ?', sessionId),
    ('rewrite_operations', 'chat_session_id = ?', sessionId),
    (
      'rewrite_operation_revisions',
      'rewrite_operation_id = ?',
      'operation_$id',
    ),
    ('rewrite_evidence_rows', 'rewrite_operation_id = ?', 'operation_$id'),
    (
      'canon_transition_fact_refs',
      'applied_canon_transition_id = ?',
      'transition_$id',
    ),
  ]) {
    expect(await _count(db, table, predicate, value), 1, reason: table);
  }

  final memoryBook = await db
      .customSelect(
        'SELECT entries_json, pending_drafts_json, settings_json, '
        'last_processed_message_count FROM memory_book_rows WHERE session_id = ?',
        variables: [Variable.withString(sessionId)],
      )
      .getSingle();
  expect(memoryBook.read<String>('entries_json'), '[]');
  expect(memoryBook.read<String>('pending_drafts_json'), '[]');
  expect(
    memoryBook.read<String>('settings_json'),
    '{"enabled":false,"memoryMode":"manual"}',
  );
  expect(memoryBook.read<int>('last_processed_message_count'), 0);

  expect(
    await _count(
      db,
      'embeddings',
      "source_type = 'chat_message' AND source_id = ?",
      sessionId,
    ),
    0,
  );
  expect(
    await _count(
      db,
      'embeddings',
      "source_type = 'memory_entry' AND source_id = ?",
      'memorybook_char_${sessionId.replaceAll('-', '_')}_$sessionId',
    ),
    0,
  );
}

Future<int> _count(
  AppDatabase db,
  String table,
  String predicate,
  String value,
) async {
  final row = await db
      .customSelect(
        'SELECT COUNT(*) AS count FROM $table WHERE $predicate',
        variables: [Variable.withString(value)],
      )
      .getSingle();
  return row.read<int>('count');
}

Future<void> _expectSessionCount(
  AppDatabase db,
  String sessionId,
  int expected,
) async {
  for (final (table, column) in _sessionTables) {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS count FROM $table WHERE $column = ?',
          variables: [Variable.withString(sessionId)],
        )
        .getSingle();
    expect(row.read<int>('count'), expected, reason: table);
  }

  for (final (table, predicate) in [
    ('embeddings', "source_type = 'chat_message' AND source_id = ?"),
    ('lorebooks', "activation_scope = 'chat' AND activation_target_id = ?"),
  ]) {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS count FROM $table WHERE $predicate',
          variables: [Variable.withString(sessionId)],
        )
        .getSingle();
    expect(row.read<int>('count'), expected, reason: table);
  }

  final id = sessionId.replaceAll('-', '_');
  for (final (table, predicate, value) in [
    (
      'rewrite_operation_revisions',
      'rewrite_operation_id = ?',
      'operation_$id',
    ),
    ('rewrite_evidence_rows', 'rewrite_operation_id = ?', 'operation_$id'),
    (
      'canon_transition_fact_refs',
      'applied_canon_transition_id = ?',
      'transition_$id',
    ),
  ]) {
    expect(await _count(db, table, predicate, value), expected, reason: table);
  }

  final lorebookEmbedding = await db
      .customSelect(
        "SELECT COUNT(*) AS count FROM embeddings WHERE source_type = 'lorebook_entry' AND source_id = ?",
        variables: [
          Variable.withString('lorebook_${sessionId.replaceAll('-', '_')}'),
        ],
      )
      .getSingle();
  expect(
    lorebookEmbedding.read<int>('count'),
    expected,
    reason: 'lorebook embeddings',
  );

  final memoryEmbedding = await db
      .customSelect(
        "SELECT COUNT(*) AS count FROM embeddings WHERE source_type = 'memory_entry' AND source_id = ?",
        variables: [
          Variable.withString(
            'memorybook_char_${sessionId.replaceAll('-', '_')}_$sessionId',
          ),
        ],
      )
      .getSingle();
  expect(
    memoryEmbedding.read<int>('count'),
    expected,
    reason: 'memory embeddings',
  );
}
