part of '../app_db.dart';

extension _AppDatabaseStudioLegacyMigrations on AppDatabase {
  Future<void> _migrateStudioPresetBlocksToExplicitSemantics() async {
    final rows = await customSelect(
      'SELECT preset_id, blocks_json FROM studio_preset_rows',
    ).get();
    for (final row in rows) {
      final presetId = row.read<String>('preset_id');
      final source = row.read<String>('blocks_json');
      try {
        final canonical = StudioPresetCodec.canonicalizeBlocksJson(source);
        if (canonical == source) continue;
        await customStatement(
          'UPDATE studio_preset_rows SET blocks_json = ?, updated_at = ? '
          'WHERE preset_id = ?',
          [canonical, DateTime.now().millisecondsSinceEpoch, presetId],
        );
      } on Object {
        // Preserve malformed rows for recovery instead of replacing user data.
      }
    }
  }

  Future<void> _canonicalizeStudioAgents() async {
    final columns = await customSelect(
      'PRAGMA table_info("studio_config_rows")',
    ).get();
    if (!columns.any((row) => row.read<String>('name') == 'agents_json')) {
      return;
    }
    final rows = await customSelect(
      'SELECT session_id, agents_json FROM studio_config_rows',
    ).get();
    for (final row in rows) {
      final sessionId = row.read<String>('session_id');
      final source = row.read<String>('agents_json');
      try {
        final canonical = StudioAgentCodec.canonicalizeAgentsJson(source);
        if (canonical == source) continue;
        await customStatement(
          'UPDATE studio_config_rows SET agents_json = ?, updated_at = ? '
          'WHERE session_id = ?',
          [canonical, currentTimestampSeconds(), sessionId],
        );
      } on Object {
        // Preserve malformed rows for recovery instead of replacing user data.
      }
    }
  }

  Future<void> _migrateStudioRuntimeToPresets() async {
    final presetColumns = await customSelect(
      'PRAGMA table_info("studio_preset_rows")',
    ).get();
    final presetColumnNames = presetColumns
        .map((row) => row.read<String>('name'))
        .toSet();
    for (final definition in const {
      'agents_json': "TEXT NOT NULL DEFAULT '[]'",
      'expensive_api_config_id': "TEXT NOT NULL DEFAULT ''",
      'cheap_api_config_id': "TEXT NOT NULL DEFAULT ''",
      'cleaner_api_config_id': "TEXT NOT NULL DEFAULT ''",
      'max_final_history_messages': 'INTEGER NOT NULL DEFAULT 30',
    }.entries) {
      if (!presetColumnNames.contains(definition.key)) {
        await customStatement(
          'ALTER TABLE studio_preset_rows ADD COLUMN ${definition.key} '
          '${definition.value}',
        );
      }
    }
    final configColumns = await customSelect(
      'PRAGMA table_info("studio_config_rows")',
    ).get();
    final configColumnNames = configColumns
        .map((row) => row.read<String>('name'))
        .toSet();
    for (final definition in const {
      'profile_id': "TEXT NOT NULL DEFAULT ''",
      'profile_name': "TEXT NOT NULL DEFAULT ''",
      'broadcast_blocks_json': "TEXT NOT NULL DEFAULT '[]'",
      'agents_json': "TEXT NOT NULL DEFAULT '[]'",
      'expensive_api_config_id': "TEXT NOT NULL DEFAULT ''",
      'cheap_api_config_id': "TEXT NOT NULL DEFAULT ''",
      'cleaner_api_config_id': "TEXT NOT NULL DEFAULT ''",
      'max_final_history_messages': 'INTEGER NOT NULL DEFAULT 30',
    }.entries) {
      if (!configColumnNames.contains(definition.key)) {
        await customStatement(
          'ALTER TABLE studio_config_rows ADD COLUMN ${definition.key} '
          '${definition.value}',
        );
      }
    }

    await _ensureDefaultStudioPresetRow();

    final configRows = await customSelect(
      'SELECT session_id, profile_id, profile_name, agents_json, '
      'expensive_api_config_id, cheap_api_config_id, cleaner_api_config_id, '
      'max_final_history_messages, updated_at FROM studio_config_rows',
    ).get();
    await applyLegacyStudioRuntimePayloads([
      for (final row in configRows)
        {
          'session_id': row.read<String>('session_id'),
          'profile_id': row.read<String>('profile_id'),
          'profile_name': row.read<String>('profile_name'),
          'agents_json': row.read<String>('agents_json'),
          'expensive_api_config_id': row.read<String>(
            'expensive_api_config_id',
          ),
          'cheap_api_config_id': row.read<String>('cheap_api_config_id'),
          'cleaner_api_config_id': row.read<String>('cleaner_api_config_id'),
          'max_final_history_messages': row.read<int>(
            'max_final_history_messages',
          ),
          'updated_at': row.read<int>('updated_at'),
        },
    ]);

    await customStatement('''
      CREATE TABLE studio_config_rows_v99 (
        session_id TEXT NOT NULL PRIMARY KEY,
        profile_id TEXT NOT NULL DEFAULT '',
        profile_name TEXT NOT NULL DEFAULT '',
        enabled INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0, 1)),
        broadcast_blocks_json TEXT NOT NULL DEFAULT '[]',
        created_at INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await customStatement('''
      INSERT INTO studio_config_rows_v99
        (session_id, profile_id, profile_name, enabled,
         broadcast_blocks_json, created_at, updated_at)
      SELECT session_id, profile_id, profile_name, enabled,
             broadcast_blocks_json, created_at, updated_at
      FROM studio_config_rows
    ''');
    await customStatement('DROP TABLE studio_config_rows');
    await customStatement(
      'ALTER TABLE studio_config_rows_v99 RENAME TO studio_config_rows',
    );
    await customStatement(
      'CREATE INDEX idx_studio_config_session '
      'ON studio_config_rows (session_id)',
    );
  }

  Future<void> _retireStudioConfigProfiles() async {
    final columns = await customSelect(
      'PRAGMA table_info("studio_config_rows")',
    ).get();
    final columnNames = columns.map((row) => row.read<String>('name')).toSet();
    if (!columnNames.contains('profile_id')) return;

    if (columnNames.contains('broadcast_blocks_json')) {
      final rows = await customSelect(
        'SELECT broadcast_blocks_json FROM studio_config_rows '
        "WHERE broadcast_blocks_json != '[]' AND broadcast_blocks_json != '' "
        'ORDER BY updated_at DESC',
      ).get();
      List<String>? broadcasts;
      for (final row in rows) {
        try {
          final decoded = jsonDecode(row.read<String>('broadcast_blocks_json'));
          if (decoded is List) {
            final values = decoded.whereType<String>().toList(growable: false);
            if (values.isNotEmpty) {
              broadcasts = values;
              break;
            }
          }
        } on Object {
          // Preserve malformed legacy rows until the table rebuild below.
        }
      }
      if (broadcasts != null) {
        final presets = await customSelect(
          'SELECT preset_id, runtime_settings_json FROM studio_preset_rows',
        ).get();
        for (final row in presets) {
          final presetId = row.read<String>('preset_id');
          try {
            final decoded = jsonDecode(
              row.read<String>('runtime_settings_json'),
            );
            final runtime = decoded is Map && decoded.isNotEmpty
                ? StudioRuntimeSettings.fromJson(
                    Map<String, dynamic>.from(decoded),
                  )
                : const StudioRuntimeSettings();
            if (runtime.broadcastBlocks.isNotEmpty) continue;
            await customStatement(
              'UPDATE studio_preset_rows SET runtime_settings_json = ? '
              'WHERE preset_id = ?',
              [
                jsonEncode(
                  StudioPresetCodec.encodeRuntime(
                    runtime.copyWith(broadcastBlocks: broadcasts),
                  ),
                ),
                presetId,
              ],
            );
          } on Object {
            // Do not replace malformed preset runtime data during migration.
          }
        }
      }
    }

    await customStatement('''
      CREATE TABLE studio_config_rows_v101 (
        session_id TEXT NOT NULL PRIMARY KEY,
        enabled INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0, 1)),
        created_at INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await customStatement('''
      INSERT INTO studio_config_rows_v101
        (session_id, enabled, created_at, updated_at)
      SELECT config.session_id, config.enabled, config.created_at,
             config.updated_at
      FROM studio_config_rows AS config
      WHERE EXISTS (
        SELECT 1 FROM chat_sessions AS chat
        WHERE chat.session_id = config.session_id
      )
    ''');
    await customStatement('DROP TABLE studio_config_rows');
    await customStatement(
      'ALTER TABLE studio_config_rows_v101 RENAME TO studio_config_rows',
    );
    await customStatement(
      'CREATE INDEX idx_studio_config_session '
      'ON studio_config_rows (session_id)',
    );
  }

  Future<void> applyLegacyStudioRuntimePayloads(
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return;
    await _ensureDefaultStudioPresetRow();
    final canonicalByProfile = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final sessionId = _studioString(row['session_id'] ?? row['sessionId']);
      if (sessionId.isEmpty) continue;
      final storedProfileId = _studioString(
        row['profile_id'] ?? row['profileId'],
      );
      final profileId = storedProfileId.isEmpty ? sessionId : storedProfileId;
      final normalized = <String, dynamic>{
        ...row,
        'session_id': sessionId,
        'profile_id': profileId,
      };
      final existing = canonicalByProfile[profileId];
      if (existing == null ||
          _preferStudioProfileRow(normalized, existing, profileId)) {
        canonicalByProfile[profileId] = normalized;
      }
    }
    final profiles = canonicalByProfile.entries.toList()
      ..sort((a, b) {
        final updated = _studioInt(
          b.value['updated_at'] ?? b.value['updatedAt'],
        ).compareTo(_studioInt(a.value['updated_at'] ?? a.value['updatedAt']));
        return updated != 0 ? updated : a.key.compareTo(b.key);
      });
    if (profiles.isEmpty) return;

    final payloads = <String, List<MapEntry<String, Map<String, dynamic>>>>{};
    for (final profile in profiles) {
      final payload = _studioProfilePayload(profile.value);
      payloads.putIfAbsent(payload.key, () => []).add(profile);
    }
    final winner = _studioProfilePayload(profiles.first.value);
    await customStatement(
      'UPDATE studio_preset_rows SET agents_json = ?, '
      'expensive_api_config_id = ?, cheap_api_config_id = ?, '
      'cleaner_api_config_id = ?, max_final_history_messages = ?',
      [
        winner.agents,
        winner.expensive,
        winner.cheap,
        winner.cleaner,
        winner.history,
      ],
    );

    final topology = await customSelect(
      'SELECT blocks_json, agent_enabled_json, execution_mode '
      'FROM studio_preset_rows ORDER BY '
      "CASE WHEN preset_id = 'default' THEN 0 ELSE 1 END, preset_id LIMIT 1",
    ).getSingle();
    final existingPresetRows = await customSelect(
      'SELECT preset_id, name, agents_json, expensive_api_config_id, '
      'cheap_api_config_id, cleaner_api_config_id, '
      'max_final_history_messages FROM studio_preset_rows',
    ).get();
    final existingIds = existingPresetRows
        .map((row) => row.read<String>('preset_id'))
        .toSet();
    final reusableVariantKeys = <String, String>{
      for (final row in existingPresetRows)
        if (row.read<String>('name').startsWith('Migrated '))
          row.read<String>('preset_id'): _studioProfilePayload({
            'agents_json': row.read<String>('agents_json'),
            'expensive_api_config_id': row.read<String>(
              'expensive_api_config_id',
            ),
            'cheap_api_config_id': row.read<String>('cheap_api_config_id'),
            'cleaner_api_config_id': row.read<String>('cleaner_api_config_id'),
            'max_final_history_messages': row.read<int>(
              'max_final_history_messages',
            ),
          }).key,
    };
    for (final entry in payloads.entries) {
      if (entry.key == winner.key) continue;
      final representatives = entry.value
        ..sort((a, b) => a.key.compareTo(b.key));
      final representative = representatives.first;
      final payload = _studioProfilePayload(representative.value);
      final presetId = _studioMigrationPresetId(
        representative.key,
        entry.key,
        existingIds,
        reusableVariantKeys,
      );
      existingIds.add(presetId);
      final profileName = _studioString(
        representative.value['profile_name'] ??
            representative.value['profileName'],
      );
      await customStatement(
        'INSERT INTO studio_preset_rows '
        '(preset_id, name, blocks_json, agents_json, '
        'expensive_api_config_id, cheap_api_config_id, '
        'cleaner_api_config_id, max_final_history_messages, '
        'agent_enabled_json, execution_mode, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(preset_id) DO UPDATE SET '
        'name = excluded.name, blocks_json = excluded.blocks_json, '
        'agents_json = excluded.agents_json, '
        'expensive_api_config_id = excluded.expensive_api_config_id, '
        'cheap_api_config_id = excluded.cheap_api_config_id, '
        'cleaner_api_config_id = excluded.cleaner_api_config_id, '
        'max_final_history_messages = excluded.max_final_history_messages, '
        'agent_enabled_json = excluded.agent_enabled_json, '
        'execution_mode = excluded.execution_mode, '
        'updated_at = excluded.updated_at',
        [
          presetId,
          'Migrated ${profileName.isEmpty ? representative.key : profileName}',
          topology.read<String>('blocks_json'),
          payload.agents,
          payload.expensive,
          payload.cheap,
          payload.cleaner,
          payload.history,
          topology.read<String>('agent_enabled_json'),
          topology.read<String>('execution_mode'),
          _studioInt(
            representative.value['updated_at'] ??
                representative.value['updatedAt'],
          ),
        ],
      );
    }
  }

  Future<void> _ensureDefaultStudioPresetRow() async {
    final existing = await customSelect(
      "SELECT 1 FROM studio_preset_rows WHERE preset_id = 'default'",
    ).getSingleOrNull();
    if (existing != null) return;
    final now = currentTimestampSeconds();
    await customStatement(
      'INSERT INTO studio_preset_rows '
      '(preset_id, name, blocks_json, agents_json, updated_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        'default',
        'Default Studio Preset',
        jsonEncode(_legacyStudioPresetMigrationBlocks()),
        StudioAgentCodec.encodeAgents(
          StudioControllerOntology.buildDefaultAgents(
            sessionId: 'default',
            now: now,
          ),
        ),
        now,
      ],
    );
  }

  bool _preferStudioProfileRow(
    Map<String, dynamic> candidate,
    Map<String, dynamic> existing,
    String id,
  ) {
    final candidateIsCanonical = _studioString(candidate['session_id']) == id;
    final existingIsCanonical = _studioString(existing['session_id']) == id;
    if (candidateIsCanonical != existingIsCanonical) {
      return candidateIsCanonical;
    }
    final updated = _studioInt(
      candidate['updated_at'] ?? candidate['updatedAt'],
    ).compareTo(_studioInt(existing['updated_at'] ?? existing['updatedAt']));
    if (updated != 0) return updated > 0;
    return _studioString(
          candidate['session_id'],
        ).compareTo(_studioString(existing['session_id'])) <
        0;
  }

  _StudioRuntimePayload _studioProfilePayload(Map<String, dynamic> row) {
    final rawAgentsValue = row['agents_json'] ?? row['agents'];
    final rawAgents = rawAgentsValue is String
        ? rawAgentsValue
        : jsonEncode(rawAgentsValue ?? const []);
    String agents;
    String keyAgents;
    try {
      agents = StudioAgentCodec.canonicalizeAgentsJson(rawAgents);
      keyAgents = 'canonical:$agents';
    } on Object {
      agents = rawAgents;
      keyAgents = 'malformed:$rawAgents';
    }
    final legacyApi = _studioString(
      row['run_api_config_id'] ?? row['runApiConfigId'],
    );
    String slot(String snake, String camel) {
      final value = _studioString(row[snake] ?? row[camel]);
      return value.isEmpty ? legacyApi : value;
    }

    final expensive = slot('expensive_api_config_id', 'expensiveApiConfigId');
    final cheap = slot('cheap_api_config_id', 'cheapApiConfigId');
    final cleaner = slot('cleaner_api_config_id', 'cleanerApiConfigId');
    final history = _studioInt(
      row['max_final_history_messages'] ?? row['maxFinalHistoryMessages'],
      fallback: 30,
    );
    return _StudioRuntimePayload(
      key: jsonEncode([keyAgents, expensive, cheap, cleaner, history]),
      agents: agents,
      expensive: expensive,
      cheap: cheap,
      cleaner: cleaner,
      history: history,
    );
  }

  String _studioString(Object? value) => value is String ? value : '';

  int _studioInt(Object? value, {int fallback = 0}) =>
      value is num ? value.toInt() : fallback;

  String _studioMigrationPresetId(
    String profileId,
    String payloadKey,
    Set<String> existingIds, [
    Map<String, String> reusableVariantKeys = const {},
  ]) {
    final safe = profileId
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9_-]+'), '_')
        .replaceAll(RegExp('_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    var hash = 0x811c9dc5;
    for (final unit in payloadKey.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    final base =
        'migrated_${safe.isEmpty ? 'profile' : safe}_'
        '${hash.toRadixString(16).padLeft(8, '0')}';
    var id = base;
    var suffix = 2;
    while (existingIds.contains(id)) {
      if (reusableVariantKeys[id] == payloadKey) return id;
      id = '${base}_$suffix';
      suffix++;
    }
    return id;
  }

  Future<void> _ensureLedgerPrompts() async {
    final rows = await customSelect(
      'SELECT preset_id, blocks_json FROM studio_preset_rows',
    ).get();
    for (final row in rows) {
      final blocks = (jsonDecode(row.read<String>('blocks_json')) as List)
          .whereType<Map<dynamic, dynamic>>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      var changed = false;
      final ledgerIndex = blocks.indexWhere(
        (block) => block['id'] == 'ledger_system',
      );
      if (ledgerIndex < 0) {
        blocks.add(_ledgerSystemPromptBlock());
        changed = true;
      } else if (blocks[ledgerIndex]['enabled'] != true) {
        blocks[ledgerIndex] = {...blocks[ledgerIndex], 'enabled': true};
        changed = true;
      }
      if (!blocks.any(
        (block) => block['id'] == 'ledger_reconciliation_prompt',
      )) {
        blocks.add(_ledgerReconciliationPromptBlock());
        changed = true;
      }
      if (!changed) continue;
      await customStatement(
        'UPDATE studio_preset_rows SET blocks_json = ?, '
        "updated_at = CAST(strftime('%s','now') AS INTEGER) "
        'WHERE preset_id = ?',
        [jsonEncode(blocks), row.read<String>('preset_id')],
      );
    }
  }

  /// Removes retired write-loop micro-memory while preserving range summaries,
  /// manual entries, Studio Ledger facts, and all MemoryBook settings.
  /// Removes retired agentic micro-memory after a schema upgrade or a restore.
  ///
  /// Backup and cloud imports can carry a pre-v66 `memory_book_rows` payload
  /// into an already-upgraded database, so this must remain callable after the
  /// one-time schema migration as well.
  Future<void> purgeRetiredAgenticMicroMemory() async {
    final rows = await customSelect(
      'SELECT session_id, entries_json, pending_drafts_json '
      'FROM memory_book_rows',
    ).get();
    for (final row in rows) {
      final removedIds = <String>{};

      List<dynamic>? filterAgentic(String raw, {required bool collectIds}) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! List) return null;
          return decoded.where((item) {
            if (item is! Map) return true;
            final isAgentic = item['source'] == 'agentic';
            if (isAgentic && collectIds) {
              final id = item['id'];
              if (id is String && id.isNotEmpty) removedIds.add(id);
            }
            return !isAgentic;
          }).toList();
        } catch (_) {
          return null;
        }
      }

      final entriesRaw = row.read<String>('entries_json');
      final draftsRaw = row.read<String>('pending_drafts_json');
      final entries = filterAgentic(entriesRaw, collectIds: true);
      final drafts = filterAgentic(draftsRaw, collectIds: false);
      if (entries != null || drafts != null) {
        await customStatement(
          'UPDATE memory_book_rows SET entries_json = ?, '
          'pending_drafts_json = ? WHERE session_id = ?',
          [
            entries == null ? entriesRaw : jsonEncode(entries),
            drafts == null ? draftsRaw : jsonEncode(drafts),
            row.read<String>('session_id'),
          ],
        );
      }

      for (final entryId in removedIds) {
        await customStatement('DELETE FROM embeddings WHERE entry_id = ?', [
          entryId,
        ]);
        await customStatement(
          'DELETE FROM memory_catalog_rows WHERE memory_entry_id = ?',
          [entryId],
        );
        await customStatement(
          'DELETE FROM memory_entity_rows WHERE memory_entry_id = ?',
          [entryId],
        );
        await customStatement(
          'DELETE FROM memory_salience_rows WHERE memory_entry_id = ?',
          [entryId],
        );
      }
    }
  }

  /// Historical no-op kept for migrations that already call it.
  /// Removes only the retired default write-loop seed from every stored preset.
  /// Matches by canonical id only — never by title, so a user-authored block
  /// with a similar name is never touched. Skips rows that have no matching
  /// block so unrelated presets are not rewritten.
  Future<void> _removeRetiredWriteLoopBlocks() async {
    const retiredId = 'writeloop_system';
    final rows = await customSelect(
      'SELECT preset_id, blocks_json FROM studio_preset_rows',
    ).get();
    for (final row in rows) {
      try {
        final raw = jsonDecode(row.read<String>('blocks_json')) as List;
        if (!raw.any((entry) => entry is Map && entry['id'] == retiredId)) {
          continue;
        }
        final kept = raw
            .whereType<Map<String, dynamic>>()
            .where((block) => block['id'] != retiredId)
            .toList(growable: false);
        await customStatement(
          'UPDATE studio_preset_rows SET blocks_json = ? WHERE preset_id = ?',
          [jsonEncode(kept), row.read<String>('preset_id')],
        );
      } catch (error) {
        debugPrint('Migration 105 (remove retired write-loop) failed: $error');
      }
    }
  }

  /// v104 — repairs the `injectionPoint` field of stored preset blocks whose
  /// routing was corrupted by the canonical codec shipped in nightly #197
  /// (which did not read `injectionPoint` from JSON, defaulting every block to
  /// `pregen`). The read-time repair in `migrateStudioPresetBlocksToV2` already
  /// fixes this in memory; this migration persists the fix so the stored JSON
  /// matches what the editor displays.
  Future<void> _repairPresetBlockRouting() async {
    final rows = await customSelect(
      'SELECT preset_id, blocks_json FROM studio_preset_rows',
    ).get();
    for (final row in rows) {
      try {
        final rawBlocks = jsonDecode(row.read<String>('blocks_json')) as List;
        final blocks = rawBlocks
            .whereType<Map<String, dynamic>>()
            .map((json) => StudioPresetCodec.canonicalizeBlock(json).block)
            .toList();
        final migrated = migrateStudioPresetBlocksToV2(blocks);
        if (identical(migrated, blocks)) continue;
        await customStatement(
          'UPDATE studio_preset_rows SET blocks_json = ? WHERE preset_id = ?',
          [
            jsonEncode(migrated.map((b) => b.toJson()).toList()),
            row.read<String>('preset_id'),
          ],
        );
      } catch (error) {
        debugPrint(
          'Migration 106 (repair preset block routing) failed: $error',
        );
      }
    }
  }
}

final class _StudioRuntimePayload {
  final String key;
  final String agents;
  final String expensive;
  final String cheap;
  final String cleaner;
  final int history;

  const _StudioRuntimePayload({
    required this.key,
    required this.agents,
    required this.expensive,
    required this.cheap,
    required this.cleaner,
    required this.history,
  });
}
