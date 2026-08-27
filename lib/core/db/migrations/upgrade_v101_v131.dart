part of '../app_db.dart';

extension _AppDatabaseUpgradeV101ToV131 on AppDatabase {
  Future<void> _upgradeV101ToV131(Migrator m, int from) async {
    if (from < 101) {
      await _retireStudioConfigProfiles();
    }
    if (from < 102) {
      final presetCols = await customSelect(
        'PRAGMA table_info("studio_preset_rows")',
      ).get();
      if (!presetCols.any(
        (row) => row.read<String>('name') == 'ledger_api_config_id',
      )) {
        await m.addColumn(studioPresetRows, studioPresetRows.ledgerApiConfigId);
      }
    }
    if (from < 103) {
      final tableNames = (await customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ).get()).map((row) => row.read<String>('name')).toSet();
      if (!tableNames.contains('preset_folders')) {
        await m.createTable(presetFolders);
      }
      if (!tableNames.contains('preset_folder_members')) {
        await m.createTable(presetFolderMembers);
      }
    }
    if (from < 105) {
      await _removeRetiredWriteLoopBlocks();
    }
    if (from < 106) {
      await _repairPresetBlockRouting();
    }
    if (from < 107) {
      final columns = await customSelect(
        "PRAGMA table_info('api_configs')",
      ).get();
      final names = columns
          .map((column) => column.read<String>('name'))
          .toSet();
      if (!names.contains('exclude_reasoning_from_context_budget')) {
        await m.addColumn(
          apiConfigs,
          apiConfigs.excludeReasoningFromContextBudget,
        );
      }
    }
    if (from < 108) {
      await m.createTable(cardEvolutionObservations);
    }
    if (from < 109) {
      // The Responses API opt-in became a protocol of its own; presets that
      // had the flag on keep talking to `/responses` after the split.
      await customStatement(
        "UPDATE api_configs SET protocol = 'openai_responses' "
        "WHERE protocol = 'openai' AND use_responses_api = 1",
      );
    }
    if (from < 110) {
      final columns = await customSelect(
        "PRAGMA table_info('api_configs')",
      ).get();
      final names = columns
          .map((column) => column.read<String>('name'))
          .toSet();
      if (!names.contains('use_system_instruction')) {
        await m.addColumn(apiConfigs, apiConfigs.useSystemInstruction);
      }
    }
    if (from < 111) {
      // `session_id` became a plain toggle. The retired default,
      // 'openrouter', meant "send only to openrouter.ai" — resolve it to
      // what it actually did for each preset so behaviour is unchanged.
      await customStatement(
        "UPDATE api_configs SET session_id_mode = CASE "
        "WHEN protocol = 'openrouter' OR endpoint LIKE '%openrouter.ai%' "
        "THEN 'always' ELSE 'off' END "
        "WHERE session_id_mode NOT IN ('always', 'off')",
      );
    }
    if (from < 112) {
      // The toggle covers Anthropic's `system` as well as Gemini's
      // `system_instruction`, so the column lost its `gemini_` prefix.
      final columns = await customSelect(
        "PRAGMA table_info('api_configs')",
      ).get();
      final names = columns
          .map((column) => column.read<String>('name'))
          .toSet();
      if (names.contains('gemini_use_system_instruction') &&
          !names.contains('use_system_instruction')) {
        await customStatement(
          'ALTER TABLE api_configs '
          'RENAME COLUMN gemini_use_system_instruction '
          'TO use_system_instruction',
        );
      }
    }
    if (from < 113) {
      final columns = await customSelect(
        "PRAGMA table_info('card_evolution_observations')",
      ).get();
      final columnNames = columns
          .map((column) => column.read<String>('name'))
          .toSet();
      if (!columnNames.contains('evidence_clusters_json')) {
        await m.addColumn(
          cardEvolutionObservations,
          cardEvolutionObservations.evidenceClustersJson,
        );
      }
      final observations = await customSelect(
        'SELECT id, evidence_message_ids FROM card_evolution_observations',
      ).get();
      for (final observation in observations) {
        final legacy = observation.read<String>('evidence_message_ids');
        final canonical = <String>[];
        try {
          final decoded = jsonDecode(legacy);
          if (decoded is List) {
            for (final value in decoded) {
              if (value is String &&
                  value.isNotEmpty &&
                  !canonical.contains(value)) {
                canonical.add(value);
              }
            }
          }
        } catch (_) {
          // Malformed legacy evidence is unverifiable and is discarded.
        }
        await customStatement(
          'UPDATE card_evolution_observations '
          'SET evidence_message_ids = ?, evidence_clusters_json = ?, '
          'repeat_count = 1 WHERE id = ?',
          [
            jsonEncode(canonical),
            jsonEncode(canonical.isEmpty ? const [] : [canonical]),
            observation.read<String>('id'),
          ],
        );
      }
    }
    if (from < 114) {
      // A character can legitimately return to an earlier canonical state
      // (A -> B -> A). Revision numbers identify lineage entries; hashes
      // identify their content and therefore must not be unique. Rebuilding
      // removes the old UNIQUE(character_id, revision_hash) auto-index while
      // preserving rows and creates the non-unique lookup index declared on
      // the table.
      await customStatement(
        'ALTER TABLE character_revision_rows '
        'RENAME TO character_revision_rows_v113',
      );
      await customStatement(
        'CREATE TABLE character_revision_rows ('
        'character_id TEXT NOT NULL, '
        'revision INTEGER NOT NULL, '
        'revision_hash TEXT NOT NULL, '
        "parent_revision_hash TEXT NOT NULL DEFAULT '', "
        'snapshot_json TEXT NOT NULL, '
        'created_at INTEGER NOT NULL DEFAULT 0, '
        'PRIMARY KEY (character_id, revision)'
        ')',
      );
      await customStatement(
        'INSERT INTO character_revision_rows '
        '(character_id, revision, revision_hash, parent_revision_hash, '
        'snapshot_json, created_at) '
        'SELECT character_id, revision, revision_hash, '
        'parent_revision_hash, snapshot_json, created_at '
        'FROM character_revision_rows_v113',
      );
      await customStatement('DROP TABLE character_revision_rows_v113');
      await customStatement(
        'CREATE INDEX idx_character_revision_hash '
        'ON character_revision_rows (character_id, revision_hash)',
      );
    }
    if (from < 115) {
      // Historical custom configs used OpenAI-named protocol/provider ids.
      // v109 also moved custom Responses users to openai_responses. Restore
      // both modes under the neutral custom protocol; use_responses_api keeps
      // selecting the endpoint inside that transport.
      await customStatement(
        "UPDATE api_configs SET protocol = 'custom_chat_completion', "
        "provider_id = 'custom_chat_completion' "
        "WHERE protocol IN ('openai', 'openai_responses', "
        "'openai_compatible') OR provider_id = 'openai_compatible'",
      );
    }
    if (from < 116) {
      await m.createTable(cardEvolutionCollectorRuns);
      // Legacy automatic proposals were produced at reconciliation 2/4/6.
      // Treat each completed proposal as delivery of the latest three-run
      // boundary already reached, so upgrading never immediately repeats a
      // proposal the user has reviewed or cancelled.
      await customStatement(
        'UPDATE card_evolution_claims '
        'SET predecessor_run_ordinal = ('
        'SELECT (COUNT(*) / 3) * 3 FROM reconciliation_successful_runs r '
        'WHERE r.session_id = card_evolution_claims.session_id) '
        "WHERE status = 'completed' AND predecessor_run_ordinal = 0",
      );
    }
    if (from < 117) {
      final columns = await customSelect(
        "PRAGMA table_info('card_evolution_observations')",
      ).get();
      final names = columns
          .map((column) => column.read<String>('name'))
          .toSet();
      if (!names.contains('retrieval_keys_json')) {
        await m.addColumn(
          cardEvolutionObservations,
          cardEvolutionObservations.retrievalKeysJson,
        );
      }
      if (!names.contains('target_kind')) {
        await m.addColumn(
          cardEvolutionObservations,
          cardEvolutionObservations.targetKind,
        );
      }
      // Safe structural backfill only. Rows without an exact target remain
      // unkeyed and are matched against a snapshot at read time, never
      // globally injected.
      await customStatement(
        "UPDATE card_evolution_observations SET target_kind = "
        "CASE WHEN lorebook_entry_id IS NOT NULL AND lorebook_entry_id <> '' "
        "THEN 'injected_lorebook_entry' "
        "WHEN card_field_path IS NOT NULL AND card_field_path <> '' "
        "THEN 'main_character_card' ELSE NULL END "
        'WHERE target_kind IS NULL',
      );
      await customStatement(
        "UPDATE card_evolution_observations "
        "SET retrieval_keys_json = json_array(lorebook_entry_id) "
        "WHERE lorebook_entry_id IS NOT NULL AND lorebook_entry_id <> '' "
        "AND retrieval_keys_json = '[]'",
      );
    }
    if (from < 118) {
      final columns = await customSelect(
        "PRAGMA table_info('api_configs')",
      ).get();
      final names = columns
          .map((column) => column.read<String>('name'))
          .toSet();
      if (!names.contains('prompt_post_processing')) {
        await m.addColumn(apiConfigs, apiConfigs.promptPostProcessing);
      }
    }
    if (from < 119) {
      // Card Rewriter runs that bail before resolving a model now record a
      // 'selection' diagnostic row. Rebuild the table so its CHECK accepts
      // that stage and stops requiring a model name for it.
      await m.alterTable(TableMigration(cardEvolutionDebugRuns));
    }
    if (from < 120) {
      // Ledger parse rejections and the repair call they silently trigger
      // were only ever visible in debug console output, so a failing turn
      // left nothing behind to diagnose.
      await m.createTable(ledgerDebugRuns);
    }
    if (from < 121) {
      await m.createTable(sessionCanonCheckpointRows);
      await m.createTable(sessionLorebookRevisionRows);
      await m.createTable(sessionLorebookEmbeddingJobRows);
      await _createSessionCanonIntegrity();
    }
    if (from < 122) {
      final columns = await customSelect(
        "PRAGMA table_info('api_configs')",
      ).get();
      final names = columns
          .map((column) => column.read<String>('name'))
          .toSet();
      if (!names.contains('embedding_requests_per_minute')) {
        await m.addColumn(apiConfigs, apiConfigs.embeddingRequestsPerMinute);
      }
    }
    if (from < 123) {
      await customStatement(
        'UPDATE studio_preset_rows SET max_final_history_messages = 50 '
        'WHERE max_final_history_messages = 30',
      );
    }
    if (from < 124) {
      await m.createTable(llmRequestCaptureRows);
      // Drift's createTable path creates indexes for a newly created table,
      // but migration fixtures may already contain the table and indexes.
      await customStatement(
        'CREATE INDEX IF NOT EXISTS '
        'idx_llm_request_capture_session_stage_created '
        'ON llm_request_capture_rows (session_id, stage, created_at_ms)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_llm_request_capture_created '
        'ON llm_request_capture_rows (created_at_ms)',
      );
    }
    if (from < 125) {
      final captureColumns = await customSelect(
        "PRAGMA table_info('llm_request_capture_rows')",
      ).get();
      if (!captureColumns.any(
        (column) => column.read<String>('name') == 'call_id',
      )) {
        await m.addColumn(llmRequestCaptureRows, llmRequestCaptureRows.callId);
      }
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_llm_request_capture_call '
        'ON llm_request_capture_rows (call_id)',
      );
      await m.createTable(llmCallEventRows);
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_llm_call_event_session_created '
        'ON llm_call_event_rows (session_id, created_at_ms)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_llm_call_event_call_attempt '
        'ON llm_call_event_rows (call_id, attempt)',
      );
      await _createLlmCallEventImmutabilityTrigger();
    }
    if (from < 126) {
      await m.createTable(ledgerReconciliationEffects);
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_reconciliation_effect_session_created '
        'ON ledger_reconciliation_effects (session_id, created_at)',
      );
      await _createLedgerReconciliationImmutabilityTriggers();
    }
    if (from < 127) {
      await customStatement(
        'ALTER TABLE card_evolution_collector_runs '
        'RENAME TO card_evolution_collector_runs_v126',
      );
      await customStatement(
        'DROP INDEX IF EXISTS idx_card_evolution_collector_session_ordinal',
      );
      await customStatement(
        'DROP INDEX IF EXISTS idx_card_evolution_collector_reconciliation',
      );
      await m.createTable(cardEvolutionCollectorRuns);
      await customStatement(
        'INSERT INTO card_evolution_collector_runs '
        '(id, session_id, character_id, collector_ordinal, '
        'reconciliation_run_id, reconciliation_run_ordinal, '
        'reconciliation_chain_hash, range_hash, input_hash, owner_id, '
        'status, lease_expires_at, model_output_hash, created_at, '
        'completed_at) SELECT id, session_id, character_id, '
        'collector_ordinal, reconciliation_run_id, '
        'reconciliation_run_ordinal, reconciliation_chain_hash, range_hash, '
        'input_hash, owner_id, status, lease_expires_at, model_output_hash, '
        'created_at, completed_at FROM card_evolution_collector_runs_v126',
      );
      await customStatement('DROP TABLE card_evolution_collector_runs_v126');
    }
    if (from < 128) {
      await customStatement(
        'ALTER TABLE card_evolution_claims '
        'RENAME TO card_evolution_claims_v127',
      );
      await customStatement(
        'DROP INDEX IF EXISTS idx_card_evolution_claim_session',
      );
      await customStatement(
        'DROP INDEX IF EXISTS idx_card_evolution_claim_input',
      );
      await customStatement(
        'DROP INDEX IF EXISTS idx_card_evolution_active_claim',
      );
      await m.createTable(cardEvolutionClaims);
      await customStatement(
        'INSERT INTO card_evolution_claims '
        '(id, session_id, character_id, owner_id, status, lease_expires_at, '
        'first_run_id, second_run_id, predecessor_cursor_hash, '
        'predecessor_run_ordinal, input_hash, rewrite_job_id, created_at, '
        'completed_at) SELECT id, session_id, character_id, owner_id, status, '
        'lease_expires_at, first_run_id, second_run_id, '
        'predecessor_cursor_hash, predecessor_run_ordinal, input_hash, '
        'rewrite_job_id, created_at, completed_at '
        'FROM card_evolution_claims_v127',
      );
      await customStatement('DROP TABLE card_evolution_claims_v127');
      await m.createTable(cardEvolutionWriterCalls);
      await customStatement(
        'CREATE INDEX IF NOT EXISTS '
        'idx_card_evolution_writer_call_session_updated '
        'ON card_evolution_writer_calls (session_id, updated_at)',
      );
      await _createCardEvolutionIntegrity();
    }
    if (from < 129) {
      await _normalizeDuplicateActiveRewriteJobs();
      await _createRewriteAuditIntegrity();
    }
    if (from < 130) {
      await m.createTable(ledgerReconciliationLeases);
    }
    if (from < 131) {
      final rows = await customSelect(
        'SELECT config_id, protocol, endpoint, model, stream, '
        'use_responses_api, embedding_endpoint FROM api_configs',
      ).get();
      for (final row in rows) {
        final endpoint = row.readNullable<String>('endpoint') ?? '';
        final embeddingEndpoint =
            row.readNullable<String>('embedding_endpoint') ?? '';
        final persistedEndpoint = EndpointNormalizer.persistedLlmEndpoint(
          raw: endpoint,
          protocol: row.read<String>('protocol'),
          model: row.readNullable<String>('model') ?? '',
          stream: row.read<int>('stream') != 0,
          useResponsesApi: row.read<int>('use_responses_api') != 0,
        );
        final persistedEmbeddingEndpoint =
            EndpointNormalizer.persistedEmbeddingEndpoint(embeddingEndpoint);
        if (persistedEndpoint == endpoint &&
            persistedEmbeddingEndpoint == embeddingEndpoint) {
          continue;
        }
        await customStatement(
          'UPDATE api_configs SET endpoint = ?, embedding_endpoint = ? '
          'WHERE config_id = ?',
          [
            persistedEndpoint,
            persistedEmbeddingEndpoint,
            row.read<String>('config_id'),
          ],
        );
      }
    }
  }
}
