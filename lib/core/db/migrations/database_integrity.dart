part of '../app_db.dart';

extension _AppDatabaseIntegrityMigrations on AppDatabase {
  /// Installs every index and integrity trigger of the current schema.
  ///
  /// Runs after `createAll` and after the last upgrade step, never from a
  /// historical step: the helpers below describe the current schema, so a
  /// step that predates one of their tables would abort the whole upgrade.
  /// `Migrator.createTable` also skips a table's `@TableIndex` indexes, so
  /// upgraded databases get those here.
  Future<void> _ensureSchemaIntegrity() async {
    final existing = (await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'index'",
    ).get()).map((row) => row.read<String>('name')).toSet();
    for (final index in allSchemaEntities.whereType<Index>()) {
      if (existing.contains(index.entityName)) continue;
      final sql = index.createStatementsByDialect[SqlDialect.sqlite]!;
      try {
        await customStatement(sql);
      } catch (error) {
        // Rows written while an upgraded database lacked a unique index can
        // violate it. Keep the database openable; the next upgrade retries.
        if (!sql.startsWith('CREATE UNIQUE INDEX')) rethrow;
        debugPrint('Unique index ${index.entityName} not created: $error');
      }
    }
    await _createLorebookUseManifestImmutabilityTriggers();
    await _createLorebookUseManifestIntegrityTriggers();
    await _createLedgerReconciliationImmutabilityTriggers();
    await _createCardEvolutionIntegrity();
    await _createRewriteAuditIntegrity();
    await _createSessionCanonIntegrity();
    await _createLlmCallEventImmutabilityTrigger();
  }

  Future<void> _createLorebookUseManifestImmutabilityTriggers() async {
    for (final table in const [
      'lorebook_use_manifests',
      'lorebook_use_manifest_entries',
      'lorebook_use_acceptance_records',
    ]) {
      await customStatement(
        'CREATE TRIGGER IF NOT EXISTS ${table}_no_update '
        'BEFORE UPDATE ON $table BEGIN '
        "SELECT RAISE(ABORT, '$table is immutable'); END",
      );
    }
  }

  Future<void> _createLedgerReconciliationImmutabilityTriggers() async {
    for (final table in const [
      'reconciliation_successful_runs',
      'ledger_reconciliation_effects',
      'reconciliation_run_invalidations',
      'ledger_reconciliation_cursors',
    ]) {
      await customStatement(
        'CREATE TRIGGER IF NOT EXISTS ${table}_no_update '
        'BEFORE UPDATE ON $table BEGIN '
        "SELECT RAISE(ABORT, '$table is immutable'); END",
      );
    }
  }

  Future<void> _createCardEvolutionIntegrity() async {
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_card_evolution_active_claim '
      'ON card_evolution_claims (session_id) WHERE status = \'claimed\'',
    );
    await customStatement(
      'CREATE TRIGGER IF NOT EXISTS card_evolution_proposal_runs_no_update '
      'BEFORE UPDATE ON card_evolution_proposal_runs BEGIN '
      "SELECT RAISE(ABORT, 'card_evolution_proposal_runs is immutable'); END",
    );
    await customStatement(
      'CREATE TRIGGER IF NOT EXISTS '
      'card_evolution_writer_calls_completed_no_update '
      'BEFORE UPDATE ON card_evolution_writer_calls '
      "WHEN OLD.status = 'completed' BEGIN "
      "SELECT RAISE(ABORT, 'completed card_evolution_writer_calls are immutable'); END",
    );
  }

  Future<void> _normalizeDuplicateActiveRewriteJobs() async {
    final active = await customSelect(
      "SELECT id, chat_session_id, character_id FROM rewrite_jobs "
      "WHERE status IN ('generating', 'pending') "
      'ORDER BY chat_session_id, character_id, created_at, id',
    ).get();
    final retained = <String>{};
    for (final row in active) {
      final key =
          '${row.read<String>('chat_session_id')}\u001f'
          '${row.read<String>('character_id')}';
      if (retained.add(key)) continue;
      await customStatement(
        "UPDATE rewrite_jobs SET status = 'cancelled', "
        "status_reason = 'duplicateActiveJobMigrated', version = version + 1 "
        'WHERE id = ?',
        [row.read<String>('id')],
      );
    }
  }

  Future<void> _createRewriteAuditIntegrity() async {
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_rewrite_job_one_active '
      'ON rewrite_jobs (chat_session_id, character_id) '
      "WHERE status IN ('generating', 'pending')",
    );
    for (final table in const [
      'rewrite_operation_revisions',
      'rewrite_evidence_rows',
      'llm_request_capture_rows',
    ]) {
      await customStatement(
        'CREATE TRIGGER IF NOT EXISTS ${table}_no_update '
        'BEFORE UPDATE ON $table BEGIN '
        "SELECT RAISE(ABORT, '$table is immutable'); END",
      );
    }
  }

  Future<void> _createLlmCallEventImmutabilityTrigger() async {
    await customStatement(
      'CREATE TRIGGER IF NOT EXISTS llm_call_event_rows_no_update '
      'BEFORE UPDATE ON llm_call_event_rows BEGIN '
      "SELECT RAISE(ABORT, 'llm_call_event_rows is immutable'); END",
    );
  }

  Future<void> _createSessionCanonIntegrity() async {
    for (final table in const [
      'session_canon_checkpoint_rows',
      'session_lorebook_revision_rows',
    ]) {
      await customStatement(
        'CREATE TRIGGER IF NOT EXISTS ${table}_no_update '
        'BEFORE UPDATE ON $table BEGIN '
        "SELECT RAISE(ABORT, '$table is immutable'); END",
      );
    }
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS '
      'idx_session_lorebook_embedding_job_active '
      'ON session_lorebook_embedding_job_rows '
      '(chat_session_id, lorebook_id, entry_id) '
      "WHERE status IN ('pending', 'running')",
    );
  }

  Future<void> _createLorebookUseManifestIntegrityTriggers() async {
    // Rebuilding v88 records must replace, rather than retain, the old
    // generation-named index and selection prerequisite trigger.
    await customStatement(
      'DROP INDEX IF EXISTS idx_lorebook_use_one_generation_acceptance',
    );
    await customStatement(
      'DROP TRIGGER IF EXISTS lorebook_use_selection_requires_generation',
    );
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS '
      'idx_lorebook_use_one_variation_acceptance '
      'ON lorebook_use_acceptance_records '
      '(session_id, message_id, swipe_id, agent_swipe_id) '
      "WHERE acceptance_kind = 'variation'",
    );
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS lorebook_use_selection_requires_variation
      BEFORE INSERT ON lorebook_use_acceptance_records
      WHEN NEW.acceptance_kind = 'selection' AND NOT EXISTS (
        SELECT 1 FROM lorebook_use_acceptance_records AS variation
        WHERE variation.session_id = NEW.session_id
          AND variation.message_id = NEW.message_id
          AND variation.swipe_id = NEW.swipe_id
          AND variation.agent_swipe_id = NEW.agent_swipe_id
          AND variation.acceptance_kind = 'variation'
      )
      BEGIN SELECT RAISE(ABORT, 'selection requires variation acceptance'); END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS lorebook_use_selection_requires_entry
      BEFORE INSERT ON lorebook_use_acceptance_records
      WHEN NEW.acceptance_kind = 'selection' AND NOT EXISTS (
        SELECT 1 FROM lorebook_use_manifest_entries AS entry
        WHERE entry.session_id = NEW.session_id
          AND entry.message_id = NEW.message_id
          AND entry.swipe_id = NEW.swipe_id
          AND entry.agent_swipe_id = NEW.agent_swipe_id
          AND entry.lorebook_id = NEW.selected_lorebook_id
          AND entry.entry_id = NEW.selected_entry_id
          AND entry.entry_order = NEW.selected_entry_order
      )
      BEGIN SELECT RAISE(ABORT, 'selection requires manifest entry'); END
    ''');
  }
}
