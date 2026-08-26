part of '../app_db.dart';

extension _AppDatabaseUpgradeV2ToV50 on AppDatabase {
  Future<void> _upgradeV2ToV50(Migrator m, int from) async {
    if (from < 2) {
      await m.addColumn(apiConfigs, apiConfigs.mode);
    }
    if (from < 3) {
      await m.addColumn(chatSessions, chatSessions.sessionVarsJson);
    }
    if (from < 4) {
      await m.createTable(lorebooks);
    }
    if (from < 5) {
      await m.createTable(embeddings);
    }
    if (from < 6) {
      await m.createTable(chatSummaries);
    }
    if (from < 7) {
      await m.createTable(memoryBookRows);
    }
    if (from < 8) {
      await m.addColumn(characters, characters.galleryJson);
    }
    if (from < 9) {
      await m.addColumn(personas, personas.createdAt);
    }
    if (from < 10) {
      await m.addColumn(apiConfigs, apiConfigs.omitTemperature);
      await m.addColumn(apiConfigs, apiConfigs.omitTopP);
      await m.addColumn(apiConfigs, apiConfigs.omitReasoning);
      await m.addColumn(apiConfigs, apiConfigs.omitReasoningEffort);
    }
    if (from < 11) {
      await m.addColumn(apiConfigs, apiConfigs.embeddingUseSame);
      await m.addColumn(apiConfigs, apiConfigs.embeddingEndpoint);
      await m.addColumn(apiConfigs, apiConfigs.embeddingApiKey);
      await m.addColumn(apiConfigs, apiConfigs.embeddingModel);
      await m.addColumn(apiConfigs, apiConfigs.embeddingEnabled);
      await m.addColumn(apiConfigs, apiConfigs.embeddingMaxChunkTokens);
    }
    if (from < 12) {
      await m.addColumn(lorebooks, lorebooks.settingsJson);
    }
    if (from < 13) {
      await m.addColumn(chatSessions, chatSessions.authorsNoteJson);
      await m.addColumn(chatSessions, chatSessions.draft);
      await m.addColumn(characters, characters.currentSessionIndex);
      await m.addColumn(characters, characters.fav);
      await m.addColumn(characters, characters.extensionsJson);
    }
    if (from < 14) {
      await m.addColumn(chatSessions, chatSessions.lastScrollAnchorJson);
      await m.addColumn(characters, characters.characterVersion);
      await m.addColumn(lorebooks, lorebooks.description);
    }
    if (from < 15) {
      await m.addColumn(memoryBookRows, memoryBookRows.pendingDraftsJson);
    }
    if (from < 16) {
      // Guard: early builds may have already added macro_name under a
      // different schema version. Unguarded addColumn raises "duplicate
      // column name: macro_name" and aborts DB open (gray chats screen).
      final cols = await customSelect('PRAGMA table_info("characters")').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('macro_name')) {
        await m.addColumn(characters, characters.macroName);
      }
    }
    if (from < 17) {
      await customStatement(
        "DELETE FROM embeddings WHERE source_type = 'lorebook_entry'",
      );
    }
    if (from < 18) {
      final cols = await customSelect('PRAGMA table_info("characters")').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('picks_hash')) {
        await m.addColumn(characters, characters.picksHash);
      }
    }
    if (from < 19) {
      final cols = await customSelect('PRAGMA table_info("characters")').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('created_at')) {
        await m.addColumn(characters, characters.createdAt);
      }
      await customStatement(
        'UPDATE characters SET created_at = updated_at WHERE created_at = 0',
      );
    }
    if (from < 20) {
      // Guard: early builds may have already created these tables under a
      // different schema version. createTable without IF NOT EXISTS raises
      // "table ... already exists" and aborts the migration. Check the
      // sqlite_master catalog before creating.
      final tables = await customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ).get();
      final tableNames = tables.map((r) => r.read<String>('name')).toSet();
      if (!tableNames.contains('extension_presets')) {
        await m.createTable(extensionPresets);
      }
      if (!tableNames.contains('info_blocks')) {
        await m.createTable(infoBlocks);
      }
    }
    if (from < 21) {
      // Guard: same root cause as the column guards below — early builds
      // may have already added cache_control_ttl under a different version.
      final cols = await customSelect('PRAGMA table_info("api_configs")').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('cache_control_ttl')) {
        await m.addColumn(apiConfigs, apiConfigs.cacheControlTtl);
      }
    }
    if (from < 22) {
      // Guard: only add columns if the table existed before v20.
      // If the table was created in the `from < 20` branch above,
      // Drift already applied the current schema (including order/status),
      // so adding them again would cause "duplicate column" errors.
      //
      // Additionally, if the table was created at v20 by a version of
      // the code that already had order/status in the Dart schema, the
      // same duplicate would occur — so we use a SQL-level existence
      // check that works on all SQLite versions supported by the app.
      if (from >= 20) {
        final cols = await customSelect(
          'PRAGMA table_info("info_blocks")',
        ).get();
        final colNames = cols.map((r) => r.read<String>('name')).toSet();
        if (!colNames.contains('order')) {
          await m.addColumn(infoBlocks, infoBlocks.order_);
        }
        if (!colNames.contains('status')) {
          await m.addColumn(infoBlocks, infoBlocks.status);
        }
      }
    }
    if (from < 23) {
      // Guard: early `feat/freezed-3x-migration` builds may have already
      // added `protocol` under a different schema version. Without the
      // existence check Drift's `addColumn` raises "duplicate column name:
      // protocol" on upgrade, which aborts the whole migration and bricks
      // DB open (and everything downstream, including the chat WebView).
      final cols = await customSelect('PRAGMA table_info("api_configs")').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('protocol')) {
        await m.addColumn(apiConfigs, apiConfigs.protocol);
      }
    }
    if (from < 24) {
      // Guard each column: early builds may have added these under a
      // different schema version (same root cause as the protocol guard
      // above). The unguarded addColumn would raise "duplicate column name"
      // and abort the migration. The `from < 27` block below also guards
      // these, but that branch only runs when upgrading from < 27 — this
      // branch must be self-consistent on its own.
      final cols = await customSelect('PRAGMA table_info("api_configs")').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('top_k')) {
        await m.addColumn(apiConfigs, apiConfigs.topK);
      }
      if (!colNames.contains('frequency_penalty')) {
        await m.addColumn(apiConfigs, apiConfigs.frequencyPenalty);
      }
      if (!colNames.contains('presence_penalty')) {
        await m.addColumn(apiConfigs, apiConfigs.presencePenalty);
      }
      await customStatement(
        'UPDATE api_configs SET top_k = 0 WHERE top_k IS NULL',
      );
      await customStatement(
        'UPDATE api_configs SET frequency_penalty = 0.0 WHERE frequency_penalty IS NULL',
      );
      await customStatement(
        'UPDATE api_configs SET presence_penalty = 0.0 WHERE presence_penalty IS NULL',
      );
    }
    if (from < 25) {
      // Guard: previous versions of these migrations may have been partially
      // applied (e.g. an early `feat/freezed-3x-migration` build that landed
      // these columns under different schema versions). Without the guard
      // Drift's `addColumn` raises "duplicate column name" on upgrade.
      final cols = await customSelect('PRAGMA table_info("api_configs")').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('cache_breakpoint_mode')) {
        await m.addColumn(apiConfigs, apiConfigs.cacheBreakpointMode);
      }
      if (!colNames.contains('session_id_mode')) {
        await m.addColumn(apiConfigs, apiConfigs.sessionIdMode);
      }
    }
    if (from < 27) {
      // Schema may have been bumped past v24 without addColumn running (e.g.
      // early builds). Ensure columns exist before backfilling NULLs — Drift
      // map() uses ! on these fields.
      final cols = await customSelect('PRAGMA table_info("api_configs")').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('top_k')) {
        await m.addColumn(apiConfigs, apiConfigs.topK);
      }
      if (!colNames.contains('frequency_penalty')) {
        await m.addColumn(apiConfigs, apiConfigs.frequencyPenalty);
      }
      if (!colNames.contains('presence_penalty')) {
        await m.addColumn(apiConfigs, apiConfigs.presencePenalty);
      }
      if (!colNames.contains('cache_breakpoint_mode')) {
        await m.addColumn(apiConfigs, apiConfigs.cacheBreakpointMode);
      }
      if (!colNames.contains('session_id_mode')) {
        await m.addColumn(apiConfigs, apiConfigs.sessionIdMode);
      }
      await customStatement(
        'UPDATE api_configs SET top_k = 0 WHERE top_k IS NULL',
      );
      await customStatement(
        'UPDATE api_configs SET frequency_penalty = 0.0 WHERE frequency_penalty IS NULL',
      );
      await customStatement(
        'UPDATE api_configs SET presence_penalty = 0.0 WHERE presence_penalty IS NULL',
      );
      await customStatement(
        "UPDATE api_configs SET cache_breakpoint_mode = 'depth' WHERE cache_breakpoint_mode IS NULL",
      );
      await customStatement(
        "UPDATE api_configs SET session_id_mode = 'openrouter' WHERE session_id_mode IS NULL",
      );
    }
    if (from < 28) {
      // v28 adds swipe_id but existing rows can remain NULL (partial upgrade
      // or SQLite ADD COLUMN without a backfill). Drift reads swipe_id as
      // non-null, so NULL rows crash InfoBlocksRepository.getBySessionId.
      final cols = await customSelect('PRAGMA table_info("info_blocks")').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('swipe_id')) {
        await m.addColumn(infoBlocks, infoBlocks.swipeId);
      }
      await customStatement(
        'UPDATE info_blocks SET swipe_id = 0 WHERE swipe_id IS NULL',
      );
    }
    if (from < 29) {
      final tables = await customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ).get();
      final tableNames = tables.map((r) => r.read<String>('name')).toSet();
      if (!tableNames.contains('memory_catalog_rows')) {
        await m.createTable(memoryCatalogRows);
      }
    }
    if (from < 30) {
      final cols = await customSelect(
        'PRAGMA table_info("chat_summaries")',
      ).get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('enabled')) {
        await m.addColumn(chatSummaries, chatSummaries.enabled);
      }
      await customStatement(
        'UPDATE chat_summaries SET enabled = 1 WHERE enabled IS NULL',
      );
    }
    if (from < 31) {
      final tables = await customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ).get();
      final tableNames = tables.map((r) => r.read<String>('name')).toSet();
      if (!tableNames.contains('character_folders')) {
        await m.createTable(characterFolders);
      }
      if (!tableNames.contains('character_folder_members')) {
        await m.createTable(characterFolderMembers);
      }
    }
    if (from < 32) {
      final cols = await customSelect('PRAGMA table_info("characters")').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('token_count')) {
        await m.addColumn(characters, characters.tokenCount);
      }
    }
    if (from < 33) {
      // Character variations: rows sharing variant_group_id collapse to one
      // list card. Guarded like every prior column migration.
      final cols = await customSelect('PRAGMA table_info("characters")').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('variant_group_id')) {
        await m.addColumn(characters, characters.variantGroupId);
      }
      if (!colNames.contains('variant_name')) {
        await m.addColumn(characters, characters.variantName);
      }
      if (!colNames.contains('variant_order')) {
        await m.addColumn(characters, characters.variantOrder);
      }
      // Backfill: every existing character is its own standalone group.
      await customStatement(
        "UPDATE characters SET variant_group_id = char_id "
        "WHERE variant_group_id IS NULL OR variant_group_id = ''",
      );
    }
    if (from < 34) {
      // Hideable characters: the `hidden` flag excludes a character (group)
      // from the My Characters list. Guarded like every prior column.
      final cols = await customSelect('PRAGMA table_info("characters")').get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('hidden')) {
        await m.addColumn(characters, characters.hidden);
      }
    }
    if (from < 35) {
      // Memory Graph foundation (Phase G0): entity graph, salience, cadence,
      // and consolidation tables. Guarded like every prior table migration
      // to survive partial upgrades from early feature builds.
      final tables = await customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ).get();
      final tableNames = tables.map((r) => r.read<String>('name')).toSet();
      if (!tableNames.contains('memory_entity_rows')) {
        await m.createTable(memoryEntityRows);
      }
      if (!tableNames.contains('memory_salience_rows')) {
        await m.createTable(memorySalienceRows);
      }
      if (!tableNames.contains('memory_cadence_rows')) {
        await m.createTable(memoryCadenceRows);
      }
      if (!tableNames.contains('memory_consolidation_rows')) {
        await m.createTable(memoryConsolidationRows);
      }
    }
    if (from < 36) {
      final tables = await customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ).get();
      final tableNames = tables.map((r) => r.read<String>('name')).toSet();
      if (!tableNames.contains('studio_config_rows')) {
        await m.createTable(studioConfigRows);
      }
    }
    if (from < 37) {
      final cols = await customSelect(
        'PRAGMA table_info("studio_config_rows")',
      ).get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('build_api_config_id')) {
        await customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN build_api_config_id TEXT NOT NULL DEFAULT ""',
        );
      }
      if (!colNames.contains('run_api_config_id')) {
        await customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN run_api_config_id TEXT NOT NULL DEFAULT ""',
        );
      }
    }
    if (from < 38) {
      final cols = await customSelect(
        'PRAGMA table_info("studio_config_rows")',
      ).get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('selected_block_ids_json')) {
        await customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN selected_block_ids_json TEXT NOT NULL DEFAULT "[]"',
        );
      }
      if (!colNames.contains('selected_block_ids_initialized')) {
        await customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN selected_block_ids_initialized INTEGER NOT NULL DEFAULT 0',
        );
      }
    }
    if (from < 39) {
      final cols = await customSelect(
        'PRAGMA table_info("studio_config_rows")',
      ).get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('final_preset_id')) {
        await customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN final_preset_id TEXT NOT NULL DEFAULT ""',
        );
      }
    }
    if (from < 40) {
      final cols = await customSelect(
        'PRAGMA table_info("studio_config_rows")',
      ).get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('agent_studio_preset_id')) {
        await customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN agent_studio_preset_id TEXT NOT NULL DEFAULT ""',
        );
      }
      if (!colNames.contains('final_studio_preset_id')) {
        await customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN final_studio_preset_id TEXT NOT NULL DEFAULT ""',
        );
      }
    }
    if (from < 41) {
      final cols = await customSelect(
        'PRAGMA table_info("studio_config_rows")',
      ).get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('studio_preset_overrides_json')) {
        await customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN studio_preset_overrides_json TEXT NOT NULL DEFAULT "[]"',
        );
      }
    }
    if (from < 42) {
      final cols = await customSelect(
        'PRAGMA table_info("studio_config_rows")',
      ).get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('profile_id')) {
        await customStatement(
          "ALTER TABLE studio_config_rows ADD COLUMN profile_id "
          "TEXT NOT NULL DEFAULT ''",
        );
      }
      if (!colNames.contains('profile_name')) {
        await customStatement(
          "ALTER TABLE studio_config_rows ADD COLUMN profile_name "
          "TEXT NOT NULL DEFAULT ''",
        );
      }
      await customStatement(
        "UPDATE studio_config_rows SET profile_id = session_id "
        "WHERE profile_id IS NULL OR profile_id = ''",
      );
      await customStatement(
        "UPDATE studio_config_rows SET profile_name = "
        "CASE WHEN profile_id IS NULL OR profile_id = '' "
        "THEN 'Studio Profile' ELSE 'Studio: ' || profile_id END "
        "WHERE profile_name IS NULL OR profile_name = ''",
      );
    }
    if (from < 43) {
      final cols = await customSelect(
        'PRAGMA table_info("studio_config_rows")',
      ).get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('builder_prompt_template')) {
        await customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN builder_prompt_template TEXT NOT NULL DEFAULT ""',
        );
      }
    }
    if (from < 44) {
      final cols = await customSelect(
        'PRAGMA table_info("studio_config_rows")',
      ).get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('max_final_history_messages')) {
        await customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN '
          'max_final_history_messages INTEGER NOT NULL DEFAULT 30',
        );
      }
    }
    if (from < 45) {
      // Agentic memory trackers: lightweight key-value state written by the
      // memory agent (e.g. 'Lucy: chip in pocket', 'relationship: +1').
      // Guarded like every prior table migration to survive partial upgrades
      // from early feature builds.
      final tables = await customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ).get();
      final tableNames = tables.map((r) => r.read<String>('name')).toSet();
      if (!tableNames.contains('tracker_rows')) {
        await m.createTable(trackerRows);
      }
    }
    if (from < 46) {
      // Stage 3: routing mode for preset orchestrator — 'verbatim' (default,
      // blocks go to agents дословно) vs 'compiled' (legacy LLM digest).
      final cols = await customSelect(
        'PRAGMA table_info("studio_config_rows")',
      ).get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('routing_mode')) {
        await customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN routing_mode TEXT NOT NULL DEFAULT "verbatim"',
        );
      }
    }
    if (from < 47) {
      // Broadcast blocks: verbatim content of cross-cutting rules (output
      // language + prose-quality guards) captured at Studio build time so the
      // POST-cleaner can apply the user's own rules instead of a hardcoded
      // English-only cliché list. Guarded to survive partial upgrades.
      final cols = await customSelect(
        'PRAGMA table_info("studio_config_rows")',
      ).get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('broadcast_blocks_json')) {
        await customStatement(
          "ALTER TABLE studio_config_rows ADD COLUMN broadcast_blocks_json "
          "TEXT NOT NULL DEFAULT '[]'",
        );
      }
    }
    if (from < 48) {
      // Pipeline settings separation: extract pipeline LLM fields from
      // memory_book_rows.settings_json into a new pipeline_settings_rows
      // table so generation-pipeline config is owned by the pipeline, not
      // the memory book. Additive only — old JSON keys are left in
      // memory_book_rows.settings_json and silently ignored by the updated
      // MemoryBookSettings.fromJson (unknown keys are dropped by freezed).
      //
      // NOTE: the pipeline_settings_rows table was dropped in schema v52
      // (pipeline settings are now a singleton global in SharedPreferences).
      // This v48 migration is retained so users upgrading from <48 → >=52
      // still create the table transiently before the v52 step drops it.
      // The CREATE TABLE uses raw SQL (not m.createTable) because the Drift
      // table definition was removed when the table was dropped.
      final tables = await customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ).get();
      final tableNames = tables.map((r) => r.read<String>('name')).toSet();
      if (!tableNames.contains('pipeline_settings_rows')) {
        await customStatement(
          'CREATE TABLE IF NOT EXISTS pipeline_settings_rows ('
          'session_id TEXT NOT NULL PRIMARY KEY, '
          "settings_json TEXT NOT NULL DEFAULT '{}', "
          'updated_at INTEGER NOT NULL DEFAULT 0)',
        );
      }
      // Migrate existing per-session pipeline settings out of memory books.
      // Done in Dart (not SQL) because the field set is large and typed.
      final rows = await customSelect(
        'SELECT session_id, settings_json FROM memory_book_rows',
      ).get();
      const pipelineKeys = <String>{
        'generationSource',
        'generationModel',
        'generationEndpoint',
        'generationApiKey',
        'generationTemperature',
        'generationMaxTokens',
        'auxSource',
        'auxModel',
        'auxEndpoint',
        'auxApiKey',
        'auxTimeoutMs',
        'agenticWriteEnabled',
        'postCleanerEnabled',
        'postCleanerTemperature',
        'postCleanerMaxTokens',
        'postCleanerSource',
        'postCleanerModel',
        'postCleanerEndpoint',
        'postCleanerApiKey',
        'postCleanerTimeoutMs',
        'postCleanerContinuityEnabled',
        'postCleanerCharacterCheckEnabled',
        'postCleanerHistoryMessages',
        'postCleanerMaxCharsPerMessage',
        'consolidationEnabled',
        'consolidationThreshold',
        'consolidationSource',
        'consolidationModel',
        'consolidationEndpoint',
        'consolidationApiKey',
        'consolidationTimeoutMs',
      };
      for (final row in rows) {
        final sessionId = row.read<String>('session_id');
        final raw = row.read<String>('settings_json');
        Map<String, dynamic>? bookJson;
        try {
          bookJson = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          bookJson = null;
        }
        if (bookJson == null) continue;
        final pipelineJson = <String, dynamic>{};
        for (final key in pipelineKeys) {
          if (bookJson.containsKey(key)) {
            pipelineJson[key] = bookJson[key];
          }
        }
        // Historical builds stored the shared helper LLM config as
        // `sidecar*`. Preserve that config under the neutral `aux*` names.
        if (!pipelineJson.containsKey('auxSource') &&
            bookJson.containsKey('sidecarSource')) {
          pipelineJson['auxSource'] = bookJson['sidecarSource'];
        }
        if (!pipelineJson.containsKey('auxModel') &&
            bookJson.containsKey('sidecarModel')) {
          pipelineJson['auxModel'] = bookJson['sidecarModel'];
        }
        if (!pipelineJson.containsKey('auxEndpoint') &&
            bookJson.containsKey('sidecarEndpoint')) {
          pipelineJson['auxEndpoint'] = bookJson['sidecarEndpoint'];
        }
        if (!pipelineJson.containsKey('auxApiKey') &&
            bookJson.containsKey('sidecarApiKey')) {
          pipelineJson['auxApiKey'] = bookJson['sidecarApiKey'];
        }
        if (!pipelineJson.containsKey('auxTimeoutMs') &&
            bookJson.containsKey('sidecarTimeoutMs')) {
          pipelineJson['auxTimeoutMs'] = bookJson['sidecarTimeoutMs'];
        }
        if (pipelineJson.isEmpty) continue;
        await customStatement(
          'INSERT OR REPLACE INTO pipeline_settings_rows '
          '(session_id, settings_json, updated_at) '
          "VALUES (?, ?, CAST(strftime('%s','now') AS INTEGER))",
          [sessionId, jsonEncode(pipelineJson)],
        );
      }
    }
    if (from < 49) {
      // Studio Build/Run model overrides: allow the user to pick a specific
      // model from the API config's fetched model list, independent of the
      // config's default `model` field. Additive — defaults to '' (use
      // config.model).
      final cols = await customSelect(
        'PRAGMA table_info("studio_config_rows")',
      ).get();
      final colNames = cols.map((r) => r.read<String>('name')).toSet();
      if (!colNames.contains('build_model_override')) {
        await customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN build_model_override TEXT NOT NULL DEFAULT ""',
        );
      }
      if (!colNames.contains('run_model_override')) {
        await customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN run_model_override TEXT NOT NULL DEFAULT ""',
        );
      }
    }
    if (from < 50) {
      // Per-(message, swipe, agent-swipe) tracker state snapshots. Mirrors
      // Marinara-Engine's game_state_snapshots: each swipe of each message
      // owns an immutable tracker-state row so delete/swipe/regen rollback
      // is emergent (drop the rows; the previous committed snapshot becomes
      // "latest"). Guarded like every prior table migration to survive
      // partial upgrades.
      final tables = await customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ).get();
      final tableNames = tables.map((r) => r.read<String>('name')).toSet();
      if (!tableNames.contains('tracker_snapshots')) {
        await m.createTable(trackerSnapshots);
      }
    }
  }
}
