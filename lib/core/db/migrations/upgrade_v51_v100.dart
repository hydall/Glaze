part of '../app_db.dart';

extension _AppDatabaseUpgradeV51ToV100 on AppDatabase {
  Future<void> _upgradeV51ToV100(Migrator m, int from) async {
    if (from < 51) {
      // Migrate existing tracker_rows into baseline tracker_snapshots so
      // legacy sessions get a committed snapshot the read path can find.
      // For each session with trackers, insert one snapshot at the sentinel
      // anchor (messageId='', swipeId=0, agentSwipeId=0, committed=1). This
      // snapshot is never dropped by deleteForMessage (no real message has
      // id='') and is naturally superseded when a new turn writes a real
      // snapshot with a higher createdAt.
      final snapTables = await customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ).get();
      final snapNames = snapTables.map((r) => r.read<String>('name')).toSet();
      if (snapNames.contains('tracker_snapshots') &&
          snapNames.contains('tracker_rows')) {
        // Aggregate each session's trackers into a JSON array and insert
        // as a single baseline snapshot.
        final sessions = await customSelect(
          'SELECT DISTINCT session_id FROM tracker_rows',
        ).get();
        final now = currentTimestampSeconds();
        for (final s in sessions) {
          final sessionId = s.read<String>('session_id');
          final rows = await customSelect(
            'SELECT name, value, scope, provenance, updated_at '
            'FROM tracker_rows WHERE session_id = ? '
            'ORDER BY name',
            variables: [Variable.withString(sessionId)],
          ).get();
          if (rows.isEmpty) continue;
          final trackersJson = rows
              .map((r) {
                return jsonEncode({
                  'sessionId': sessionId,
                  'name': r.read<String>('name'),
                  'value': r.read<String>('value'),
                  'scope': r.read<String>('scope'),
                  'provenance': r.read<String>('provenance'),
                  'updatedAt': r.read<int>('updated_at'),
                });
              })
              .join(',');
          await customStatement(
            'INSERT OR REPLACE INTO tracker_snapshots '
            '(session_id, message_id, swipe_id, agent_swipe_id, '
            'trackers_json, committed, created_at) VALUES '
            "(?, '', 0, 0, ?, 1, ?)",
            [sessionId, '[$trackersJson]', now],
          );
        }
      }
    }
    if (from < 52) {
      // Pipeline settings are now a singleton global stored in
      // SharedPreferences (key 'pipelineSettings'), not per-session Drift
      // rows. Drop the table — per-session overrides are abandoned by
      // explicit user choice (pipeline config is set once
      // and applied uniformly across all chats). The SharedPreferences
      // payload is unaffected; PipelineSettings.fromJson reads the same
      // fields, with new cleaner fields defaulting to their @Default values.
      await m.deleteTable('pipeline_settings_rows');
    }
    if (from < 53) {
      // InfoBlock.agentSwipeId: bind ext blocks to the blue cleaned
      // sub-swipe so blocks launched after the POST-cleaner target the
      // cleaned text, not the raw streamed final. Default -1 = "no agent
      // swipe" (legacy blocks written before the cleaner existed or when
      // the cleaner is disabled — these match by (messageId, swipeId)
      // only, preserving prior behavior).
      final cols = await customSelect('PRAGMA table_info("info_blocks")').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('agent_swipe_id')) {
        await m.addColumn(infoBlocks, infoBlocks.agentSwipeId);
      }
    }
    if (from < 59) {
      // Purge raw ledger diagnostic rows (_ledger:$messageId) from
      // tracker_rows. These were append-only raw LLM outputs that grew
      // unbounded and were never read back by the prompt path or the UI
      // (the Agentic Ops dialog uses AgentOperationRecord, not tracker_rows).
      // Keeping them bloated tracker_rows and every snapshot copy.
      // _ledger_diag:* rows (run/skip reason, single upsert) are preserved.
      try {
        await customStatement(
          "DELETE FROM tracker_rows "
          "WHERE scope = 'ledger_diagnostic' "
          "AND name LIKE '_ledger:%' "
          "AND name NOT LIKE '_ledger_diag:%'",
        );
      } catch (e) {
        debugPrint('Migration 59 (purge ledger diagnostic rows) failed: $e');
      }
    }
    if (from < 65) {
      try {
        await m.addColumn(apiConfigs, apiConfigs.firstChunkTimeoutMs);
      } catch (e) {
        debugPrint('Migration 65 (firstChunkTimeoutMs column) failed: $e');
      }
    }
    if (from < 66) {
      await purgeRetiredAgenticMicroMemory();
    }
    if (from < 68) {
      final rows = await customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ).get();
      final tableNames = rows.map((row) => row.read<String>('name')).toSet();
      if (!tableNames.contains('character_knowledge_fact_rows')) {
        await m.createTable(characterKnowledgeFactRows);
      }
      if (!tableNames.contains('character_session_baseline_rows')) {
        await m.createTable(characterSessionBaselineRows);
      }
    }
    if (from < 72) {
      final columns = await customSelect(
        "PRAGMA table_info('api_configs')",
      ).get();
      final names = columns
          .map((column) => column.read<String>('name'))
          .toSet();
      if (!names.contains('extra_request_parameters_json')) {
        await m.addColumn(apiConfigs, apiConfigs.extraRequestParametersJson);
      }
    }
    if (from < 73) {
      await m.createTable(ledgerReconciliationCheckpoints);
    }
    if (from < 75) {
      final columns = await customSelect(
        "PRAGMA table_info('api_configs')",
      ).get();
      final names = columns
          .map((column) => column.read<String>('name'))
          .toSet();
      if (!names.contains('include_last_reasoning')) {
        await m.addColumn(apiConfigs, apiConfigs.includeLastReasoning);
      }
    }
    if (from < 76) {
      final columns = await customSelect(
        "PRAGMA table_info('api_configs')",
      ).get();
      final names = columns
          .map((column) => column.read<String>('name'))
          .toSet();
      if (!names.contains('show_native_reasoning')) {
        await m.addColumn(apiConfigs, apiConfigs.showNativeReasoning);
        await customStatement(
          'UPDATE api_configs SET show_native_reasoning = '
          'CASE WHEN omit_reasoning = 0 THEN 1 ELSE 0 END',
        );
      }
      if (!names.contains('omit_top_k')) {
        await m.addColumn(apiConfigs, apiConfigs.omitTopK);
      }
      if (!names.contains('omit_frequency_penalty')) {
        await m.addColumn(apiConfigs, apiConfigs.omitFrequencyPenalty);
      }
      if (!names.contains('omit_presence_penalty')) {
        await m.addColumn(apiConfigs, apiConfigs.omitPresencePenalty);
      }
    }
    if (from < 77) {
      await m.createTable(ledgerReconciliationCleanupJournals);
    }
    if (from < 78) {
      final prefs = await SharedPreferences.getInstance();
      if (!prefs.containsKey('gz_disabled_third_party_providers')) {
        await prefs.setStringList(
          'gz_disabled_third_party_providers',
          <String>[],
        );
      }
    }
    if (from < 79) {
      final columns = await customSelect(
        "PRAGMA table_info('api_configs')",
      ).get();
      final names = columns
          .map((column) => column.read<String>('name'))
          .toSet();
      if (!names.contains('reasoning_history_count')) {
        await m.addColumn(apiConfigs, apiConfigs.reasoningHistoryCount);
        await customStatement(
          'UPDATE api_configs SET reasoning_history_count = '
          'CASE WHEN include_last_reasoning = 1 THEN 1 ELSE 0 END',
        );
      }
    }
    if (from < 80) {
      final columns = await customSelect(
        "PRAGMA table_info('api_configs')",
      ).get();
      final names = columns
          .map((column) => column.read<String>('name'))
          .toSet();
      if (!names.contains('use_responses_api')) {
        await m.addColumn(apiConfigs, apiConfigs.useResponsesApi);
      }
    }
    if (from < 81) {
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_embeddings_source_type_id '
        'ON embeddings (source_type, source_id)',
      );
    }
    if (from < 82) {
      // Additive and guarded to tolerate interrupted development upgrades.
      final tables = await customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ).get();
      final names = tables.map((row) => row.read<String>('name')).toSet();
      if (!names.contains('character_revision_rows')) {
        await m.createTable(characterRevisionRows);
      }
      if (!names.contains('applied_canon_transition_rows')) {
        await m.createTable(appliedCanonTransitionRows);
      }
      if (!names.contains('rewrite_jobs')) await m.createTable(rewriteJobs);
      if (!names.contains('rewrite_operations')) {
        await m.createTable(rewriteOperations);
      }
      if (!names.contains('rewrite_operation_revisions')) {
        await m.createTable(rewriteOperationRevisions);
      }
      if (!names.contains('rewrite_evidence_rows')) {
        await m.createTable(rewriteEvidenceRows);
      }
      if (!names.contains('canon_transition_fact_refs')) {
        await m.createTable(canonTransitionFactRefs);
      }

      final factColumns = await customSelect(
        "PRAGMA table_info('character_knowledge_fact_rows')",
      ).get();
      final factNames = factColumns
          .map((column) => column.read<String>('name'))
          .toSet();
      if (!factNames.contains('basis_revision')) {
        await m.addColumn(
          characterKnowledgeFactRows,
          characterKnowledgeFactRows.basisRevision,
        );
      }
      if (!factNames.contains('basis_revision_hash')) {
        await m.addColumn(
          characterKnowledgeFactRows,
          characterKnowledgeFactRows.basisRevisionHash,
        );
      }

      final trackerColumns = await customSelect(
        "PRAGMA table_info('tracker_rows')",
      ).get();
      final trackerNames = trackerColumns
          .map((column) => column.read<String>('name'))
          .toSet();
      if (!trackerNames.contains('basis_revision')) {
        await m.addColumn(trackerRows, trackerRows.basisRevision);
      }
      if (!trackerNames.contains('basis_revision_hash')) {
        await m.addColumn(trackerRows, trackerRows.basisRevisionHash);
      }
    }
    if (from < 83) {
      // v82 was an unreleased interim schema that stored numeric lineage in
      // TEXT columns. Rebuild tables whose declared affinity is wrong:
      // SQLite's lax affinity makes ALTER insufficient for schema correctness.
      // TableMigration preserves rows, keys, unique constraints, and indexes.
      Future<bool> hasNonIntegerColumn(String table, String column) async {
        final columns = await customSelect("PRAGMA table_info('$table')").get();
        final match = columns.where(
          (row) => row.read<String>('name') == column,
        );
        return match.isNotEmpty &&
            match.single.read<String>('type').toUpperCase() != 'INTEGER';
      }

      if (await hasNonIntegerColumn('tracker_rows', 'basis_revision')) {
        await m.alterTable(
          TableMigration(
            trackerRows,
            columnTransformer: {
              trackerRows.basisRevision: const CustomExpression<int>(
                'CAST(basis_revision AS INTEGER)',
              ),
            },
          ),
        );
      }
      if (await hasNonIntegerColumn(
        'character_knowledge_fact_rows',
        'basis_revision',
      )) {
        await m.alterTable(
          TableMigration(
            characterKnowledgeFactRows,
            columnTransformer: {
              characterKnowledgeFactRows.basisRevision:
                  const CustomExpression<int>(
                    'CAST(basis_revision AS INTEGER)',
                  ),
            },
          ),
        );
      }
      if (await hasNonIntegerColumn('character_revision_rows', 'revision')) {
        await m.alterTable(
          TableMigration(
            characterRevisionRows,
            columnTransformer: {
              characterRevisionRows.revision: const CustomExpression<int>(
                'CAST(revision AS INTEGER)',
              ),
            },
          ),
        );
      }
      if (await hasNonIntegerColumn(
        'applied_canon_transition_rows',
        'basis_revision',
      )) {
        await m.alterTable(
          TableMigration(
            appliedCanonTransitionRows,
            columnTransformer: {
              appliedCanonTransitionRows.basisRevision:
                  const CustomExpression<int>(
                    'CAST(basis_revision AS INTEGER)',
                  ),
            },
          ),
        );
      }
      if (await hasNonIntegerColumn('rewrite_jobs', 'basis_revision')) {
        await m.alterTable(
          TableMigration(
            rewriteJobs,
            columnTransformer: {
              rewriteJobs.basisRevision: const CustomExpression<int>(
                'CAST(basis_revision AS INTEGER)',
              ),
            },
          ),
        );
      }
      if (await hasNonIntegerColumn(
        'rewrite_operation_revisions',
        'revision',
      )) {
        await m.alterTable(
          TableMigration(
            rewriteOperationRevisions,
            columnTransformer: {
              rewriteOperationRevisions.revision: const CustomExpression<int>(
                'CAST(revision AS INTEGER)',
              ),
            },
          ),
        );
      }
    }
    if (from < 84) {
      // v84 makes canon transitions structurally queryable. Existing v81-v83
      // payloads have no reliable JSON shape to backfill, so retain their
      // transition JSON and use neutral defaults. Rebuilding is required to
      // make chat_session_id nullable; TableMigration preserves existing rows,
      // primary/unique constraints, and declared indexes.
      final revisionColumns = await customSelect(
        "PRAGMA table_info('character_revision_rows')",
      ).get();
      final revisionNames = revisionColumns
          .map((row) => row.read<String>('name'))
          .toSet();
      if (!revisionNames.contains('parent_revision_hash')) {
        await m.addColumn(
          characterRevisionRows,
          characterRevisionRows.parentRevisionHash,
        );
      }

      final transitionColumns = await customSelect(
        "PRAGMA table_info('applied_canon_transition_rows')",
      ).get();
      final transitionNames = transitionColumns
          .map((row) => row.read<String>('name'))
          .toSet();
      if (!transitionNames.contains('rewrite_operation_id') ||
          transitionColumns
                  .singleWhere(
                    (row) => row.read<String>('name') == 'chat_session_id',
                  )
                  .read<int>('notnull') ==
              1) {
        await m.alterTable(
          TableMigration(
            appliedCanonTransitionRows,
            columnTransformer: {
              // v81-v83 rows predate structural fields. Preserve their
              // legacy payload and provenance while filling neutral values.
              appliedCanonTransitionRows.rewriteOperationId:
                  const CustomExpression<String>("''"),
              appliedCanonTransitionRows.revision: const CustomExpression<int>(
                '0',
              ),
              appliedCanonTransitionRows.revisionHash:
                  const CustomExpression<String>("''"),
              appliedCanonTransitionRows.semanticScopeKey:
                  const CustomExpression<String>("''"),
              appliedCanonTransitionRows.canonicalClaim:
                  const CustomExpression<String>("''"),
              appliedCanonTransitionRows.promotionDestination:
                  const CustomExpression<String>("''"),
              appliedCanonTransitionRows.affectedTrackerKeysJson:
                  const CustomExpression<String>("'[]'"),
            },
          ),
        );
      }
    }
    if (from < 85) {
      // v85 adds explicit durable compare-and-swap/apply state. Existing
      // operations and jobs have no reviewed/apply state, so use neutral
      // defaults that cannot accidentally qualify an operation for apply.
      final jobColumns = await customSelect(
        "PRAGMA table_info('rewrite_jobs')",
      ).get();
      final jobNames = jobColumns
          .map((row) => row.read<String>('name'))
          .toSet();
      if (!jobNames.contains('version')) {
        await m.addColumn(rewriteJobs, rewriteJobs.version);
      }
      if (!jobNames.contains('applied_character_revision')) {
        await m.addColumn(rewriteJobs, rewriteJobs.appliedCharacterRevision);
      }
      if (!jobNames.contains('applied_character_revision_hash')) {
        await m.addColumn(
          rewriteJobs,
          rewriteJobs.appliedCharacterRevisionHash,
        );
      }

      final operationColumns = await customSelect(
        "PRAGMA table_info('rewrite_operations')",
      ).get();
      final operationNames = operationColumns
          .map((row) => row.read<String>('name'))
          .toSet();
      if (!operationNames.contains('current_revision')) {
        await m.addColumn(rewriteOperations, rewriteOperations.currentRevision);
      }
      if (!operationNames.contains('decision')) {
        await m.addColumn(rewriteOperations, rewriteOperations.decision);
      }
      if (!operationNames.contains('validation_status')) {
        await m.addColumn(
          rewriteOperations,
          rewriteOperations.validationStatus,
        );
      }
      if (!operationNames.contains('decision_revision')) {
        await m.addColumn(
          rewriteOperations,
          rewriteOperations.decisionRevision,
        );
      }
      if (!operationNames.contains('applied_character_revision')) {
        await m.addColumn(
          rewriteOperations,
          rewriteOperations.appliedCharacterRevision,
        );
      }
      if (!operationNames.contains('applied_character_revision_hash')) {
        await m.addColumn(
          rewriteOperations,
          rewriteOperations.appliedCharacterRevisionHash,
        );
      }
      // SQLite cannot add CHECK constraints to an existing table. Rebuild the
      // v84 table after its new columns have been populated with their safe
      // defaults so upgraded databases enforce the same invariants as a fresh
      // v85 database. TableMigration retains legacy rows and all declared
      // indexes, including the apply-CAS lookup index.
      // The upgrade rebuild copies into the current table definition, which
      // enforces the v86 operation-status CHECK. Normalize out-of-domain
      // legacy statuses to the neutral non-reviewable 'pending' first, or
      // the copy would abort (v86 repeats this for the jobs table and for
      // databases that are already at v85).
      await customStatement(
        "UPDATE rewrite_operations SET status = 'pending' WHERE status NOT "
        "IN ('pending', 'reviewable', 'applied')",
      );
      await m.alterTable(TableMigration(rewriteOperations));
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_rewrite_operation_apply_cas '
        'ON rewrite_operations '
        '(rewrite_job_id, decision, validation_status, current_revision)',
      );
    }
    if (from < 86) {
      // v86 adds the durable Phase-4 job lifecycle fields. Existing jobs are
      // pre-lifecycle, so the new columns carry neutral defaults: no reason
      // text, an empty (audit-only) canon stamp, and a NULL idempotency key
      // (NULL request keys remain distinct under the unique index).
      final jobColumns = await customSelect(
        "PRAGMA table_info('rewrite_jobs')",
      ).get();
      final jobNames = jobColumns
          .map((row) => row.read<String>('name'))
          .toSet();
      if (!jobNames.contains('status_reason')) {
        await m.addColumn(rewriteJobs, rewriteJobs.statusReason);
      }
      if (!jobNames.contains('canon_stamp')) {
        await m.addColumn(rewriteJobs, rewriteJobs.canonStamp);
      }
      if (!jobNames.contains('request_key')) {
        await m.addColumn(rewriteJobs, rewriteJobs.requestKey);
      }
      // CHECK constraints cannot be installed without a table rebuild, and
      // the copy would abort on out-of-domain legacy statuses. Normalize
      // them first, fail-closed: unknown job statuses become terminal
      // 'cancelled' rows, unknown operation statuses become non-reviewable
      // 'pending' rows. Legitimate legacy 'pending'/'applied' rows pass
      // through unchanged.
      await customStatement(
        "UPDATE rewrite_jobs SET status = 'cancelled' WHERE status NOT IN "
        "('generating', 'pending', 'failed', 'cancelled', 'applied')",
      );
      await customStatement(
        "UPDATE rewrite_operations SET status = 'pending' WHERE status NOT "
        "IN ('pending', 'reviewable', 'applied')",
      );
      // Rebuild both tables so upgraded databases enforce the same status
      // CHECKs as a fresh v86 database while preserving rows and indexes
      // (the v85 TableMigration precedent).
      await m.alterTable(TableMigration(rewriteJobs));
      await customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_rewrite_job_request_key '
        'ON rewrite_jobs (request_key)',
      );
      await m.alterTable(TableMigration(rewriteOperations));
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_rewrite_operation_apply_cas '
        'ON rewrite_operations '
        '(rewrite_job_id, decision, validation_status, current_revision)',
      );
    }
    if (from < 87) {
      await m.createTable(lorebookUseManifests);
      await m.createTable(lorebookUseManifestEntries);
      await m.createTable(lorebookUseAcceptanceRecords);
    }
    if (from < 88) {
      // v87 used prompt_hash as part of the manifest identity. Rebuild the
      // unpublished tables so the variation anchor is authoritative and the
      // canonical payload/hash are immutable values instead.
      // v87 had no canonical payload to preserve, so its provisional rows
      // cannot be truthfully upgraded into the v88 contract. Drop children
      // first, then recreate the fully constrained immutable lane.
      await m.drop(lorebookUseAcceptanceRecords);
      await m.drop(lorebookUseManifestEntries);
      await m.drop(lorebookUseManifests);
      await m.createTable(lorebookUseManifests);
      await m.createTable(lorebookUseManifestEntries);
      await m.createTable(lorebookUseAcceptanceRecords);
    }
    if (from < 89) {
      // v88 called the provisional record a `generation` acceptance, but no
      // production path created it. It cannot establish the required fact
      // that a *subsequent user message* accepted an assistant variation.
      // Delete those unprovable records, retain immutable manifests/evidence,
      // and rebuild so upgraded databases enforce the v89 contract.
      await customStatement(
        'DROP TRIGGER IF EXISTS lorebook_use_acceptance_records_no_update',
      );
      final acceptanceColumns = await customSelect(
        'PRAGMA table_info("lorebook_use_acceptance_records")',
      ).get();
      final acceptanceColumnNames = acceptanceColumns
          .map((row) => row.read<String>('name'))
          .toSet();
      if (!acceptanceColumnNames.contains('accepted_by_user_message_id')) {
        await m.addColumn(
          lorebookUseAcceptanceRecords,
          lorebookUseAcceptanceRecords.acceptedByUserMessageId,
        );
      }
      await customStatement('DELETE FROM lorebook_use_acceptance_records');
      // alterTable rebuilds the table and drops its append-only trigger;
      // `_ensureSchemaIntegrity` re-arms it after the last step.
      await m.alterTable(TableMigration(lorebookUseAcceptanceRecords));
    }
    if (from < 90) {
      await m.createTable(ledgerReconciliationSuccessfulRuns);
      await m.createTable(ledgerReconciliationRunInvalidations);
      await m.createTable(ledgerReconciliationCursors);
    }
    if (from < 91) {
      // v90 accidentally rejected the empty predecessor required by the
      // genesis cursor. Rebuild to match the fresh-schema contract.
      await m.alterTable(TableMigration(ledgerReconciliationCursors));
    }
    if (from < 92) {
      await m.createTable(cardEvolutionClaims);
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_card_evolution_claim_session '
        'ON card_evolution_claims (session_id)',
      );
      await customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_card_evolution_claim_input '
        'ON card_evolution_claims (session_id, input_hash)',
      );
      await m.createTable(cardEvolutionProposalRuns);
    }
    if (from < 93) {
      await m.createTable(sessionLorebookEvolutionRows);
    }
    if (from < 94) {
      await m.createTable(cardEvolutionDebugRuns);
    }
    if (from < 95) {
      // v94 retained only one writer stage per session. Rebuild the table
      // with the stage in its key so card and lorebook diagnostics coexist.
      await m.alterTable(TableMigration(cardEvolutionDebugRuns));
    }
  }
}
