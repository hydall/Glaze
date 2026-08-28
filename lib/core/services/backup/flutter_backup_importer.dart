import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../db/app_db.dart';
import '../../db/repositories/session_lorebook_embedding_job_repo.dart';
import '../../llm/transport/endpoint_normalizer.dart';
import '../../models/studio_agent_codec.dart';
import '../../models/studio_preset_codec.dart';
import '../image_storage_service.dart';
import 'backup_cancel.dart';
import 'backup_helpers.dart';

class FlutterBackupImporter extends BackupHelpers {
  static const int _batchSize = 500;
  static const int _maxSchemaVersion = 13;

  @override
  final AppDatabase db;
  @override
  final ImageStorageService imageStorage;
  final ImportCancellationToken _cancel;
  final List<Map<String, dynamic>> _legacyStudioRuntimeRows = [];

  FlutterBackupImporter(this.db, this.imageStorage, [this._cancel = noCancel]);

  /// Imports a v2 Glaze backup (ZIP container with manifest.json and
  /// tables/*.jsonl). Streamed — file is never read fully into memory.
  Future<void> importFromZipFile(
    String filePath, {
    void Function(String stage)? onProgress,
  }) async {
    _legacyStudioRuntimeRows.clear();
    try {
      final archive = ZipDecoder().decodeStream(InputFileStream(filePath));
      await _importFromZip(archive, onProgress: onProgress);
    } finally {
      _legacyStudioRuntimeRows.clear();
    }
  }

  /// Imports a legacy v1 Glaze JSON-monolith. Kept for completeness but
  /// the service layer rejects v1 with a "please re-export" message.
  Future<void> importFromLegacyJson(
    Map<String, dynamic> data, {
    void Function(String stage)? onProgress,
  }) async {
    _legacyStudioRuntimeRows.clear();
    try {
      final tables = data['tables'] as Map<String, dynamic>?;
      if (tables == null) return;
      await _importTablesFromJson(tables, onProgress: onProgress);
      await restoreGalleryImages(data['gallery'] as Map<String, dynamic>?);
      await _restoreAvatars(data['avatars'] as Map<String, dynamic>?);
    } finally {
      _legacyStudioRuntimeRows.clear();
    }
  }

  Future<void> import(
    Map<String, dynamic> data, {
    void Function(String stage)? onProgress,
  }) => importFromLegacyJson(data, onProgress: onProgress);

  Future<void> _importFromZip(
    Archive archive, {
    void Function(String stage)? onProgress,
  }) async {
    final manifestEntry = archive.files.firstWhere(
      (f) => f.isFile && f.name == 'manifest.json',
      orElse: () => throw const FormatException(
        'Glaze backup is missing manifest.json — not a v2 backup',
      ),
    );
    final manifestJson =
        jsonDecode(utf8.decode(manifestEntry.readBytes()!))
            as Map<String, dynamic>;
    manifestEntry.clear();
    final schemaVersion = manifestJson['schemaVersion'] as int? ?? 0;
    // Minimum supported schemaVersion is 2 (initial ZIP format).
    // v3 added extension_presets and info_blocks — older backups simply won't
    // have those JSONL files, leaving the tables empty after import (fine).
    if (schemaVersion < 2) {
      throw const FormatException(
        'Glaze backup schema is too old. Please re-export from the source app.',
      );
    }
    if (schemaVersion > _maxSchemaVersion) {
      throw const FormatException(
        'Glaze backup was created by a newer app version.',
      );
    }

    final tableFiles = archive.files
        .where(
          (f) =>
              f.isFile &&
              f.name.startsWith('tables/') &&
              f.name.endsWith('.jsonl'),
        )
        .toList();
    final avatarFiles = archive.files
        .where((f) => f.isFile && f.name.startsWith('avatars/'))
        .toList();
    final galleryFiles = archive.files
        .where((f) => f.isFile && f.name.startsWith('gallery/'))
        .toList();

    // Pre-fetch existing columns.
    final existingColumns = <String, Set<String>>{};
    final allTableNames = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'drift_%'",
        )
        .get();
    for (final t in allTableNames) {
      final tName = t.read<String>('name');
      final cols = await db.customSelect("PRAGMA table_info('$tName')").get();
      existingColumns[tName] = cols.map((c) => c.read<String>('name')).toSet();
    }

    const importOrder = [
      'characters',
      'character_revision_rows',
      'chat_sessions',
      'lorebooks',
      'lorebook_use_manifests',
      'lorebook_use_manifest_entries',
      'lorebook_use_acceptance_records',
      'character_knowledge_fact_rows',
      'character_session_baseline_rows',
      'reconciliation_successful_runs',
      'ledger_reconciliation_effects',
      'reconciliation_run_invalidations',
      'ledger_reconciliation_checkpoints',
      'ledger_reconciliation_cleanup_journals',
      'card_evolution_collector_runs',
      'card_evolution_observations',
      'ledger_reconciliation_cursors',
      'rewrite_jobs',
      'rewrite_operations',
      'rewrite_operation_revisions',
      'rewrite_evidence_rows',
      'card_evolution_claims',
      'card_evolution_writer_calls',
      'card_evolution_proposal_runs',
      'applied_canon_transition_rows',
      'canon_transition_fact_refs',
      'session_canon_checkpoint_rows',
      'session_lorebook_evolution_rows',
      'session_lorebook_revision_rows',
    ];
    int rank(ArchiveFile file) {
      final table = file.name
          .substring('tables/'.length)
          .replaceAll(RegExp(r'\.jsonl$'), '');
      final index = importOrder.indexOf(table);
      return index < 0 ? importOrder.length : index;
    }

    tableFiles.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : a.name.compareTo(b.name);
    });

    onProgress?.call('Importing tables...');
    await db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      if (schemaVersion < 12) {
        await _clearAgentOpsStateMissingFromLegacyBackup();
      }
      for (final f in tableFiles) {
        _cancel.check();
        // e.g. tables/characters.jsonl → characters
        final tableName = f.name
            .substring('tables/'.length)
            .replaceAll(RegExp(r'\.jsonl$'), '');
        final knownCols = existingColumns[tableName];
        if (knownCols == null) continue;
        onProgress?.call('Importing $tableName...');
        await _importTableFromJsonl(f, tableName, knownCols);
        // Truncate WAL between tables to keep heap small.
        await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
      }
      if (schemaVersion < 13) {
        await _clearLegacyCollectorCadence();
      }
      await db.applyLegacyStudioRuntimePayloads(_legacyStudioRuntimeRows);
      if (schemaVersion >= 11) await _rebuildSessionLorebookEmbeddingQueue();
    } finally {
      await db.customStatement('PRAGMA foreign_keys = ON');
    }

    onProgress?.call('Restoring avatars...');
    _cancel.check();
    await _restoreAvatarsFromZip(avatarFiles);

    onProgress?.call('Restoring gallery...');
    _cancel.check();
    await _restoreGalleryFromZip(galleryFiles);

    onProgress?.call('Restoring settings...');
    await _restorePreferences(archive);
  }

  Future<void> _clearAgentOpsStateMissingFromLegacyBackup() =>
      db.transaction(() async {
        for (final table in const [
          'card_evolution_writer_calls',
          'card_evolution_claims',
          'card_evolution_observations',
          'card_evolution_collector_runs',
          'ledger_reconciliation_cursors',
          'ledger_reconciliation_cleanup_journals',
          'ledger_reconciliation_checkpoints',
          'ledger_reconciliation_effects',
          'reconciliation_run_invalidations',
          'reconciliation_successful_runs',
          'lorebook_use_acceptance_records',
          'lorebook_use_manifest_entries',
          'lorebook_use_manifests',
        ]) {
          await db.customStatement('DELETE FROM $table');
        }
      });

  Future<void> _clearLegacyCollectorCadence() => db.transaction(() async {
    await db.customStatement(
      'DELETE FROM card_evolution_writer_calls WHERE claim_id IN '
      "(SELECT id FROM card_evolution_claims WHERE status <> 'completed')",
    );
    await db.customStatement(
      "DELETE FROM card_evolution_claims WHERE status <> 'completed'",
    );
    await db.customStatement('DELETE FROM card_evolution_collector_runs');
    await db.customStatement('DELETE FROM card_evolution_observations');
  });

  /// Restores all SharedPreferences from [preferences.json] inside the ZIP.
  /// Keys are written as-is; missing file is silently ignored (v1 legacy or
  /// older backups that pre-date the preferences export).
  Future<void> _restorePreferences(Archive archive) async {
    final matches = archive.files
        .where((f) => f.isFile && f.name == 'preferences.json')
        .toList();
    if (matches.isEmpty) return;

    final preferencesEntry = matches.first;
    final bytes = preferencesEntry.readBytes();
    preferencesEntry.clear();
    if (bytes == null || bytes.isEmpty) return;

    Map<String, dynamic> map;
    try {
      map = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    for (final entry in map.entries) {
      final key = entry.key;
      final value = entry.value;
      try {
        if (value is bool) {
          await prefs.setBool(key, value);
        } else if (value is int) {
          await prefs.setInt(key, value);
        } else if (value is double) {
          await prefs.setDouble(key, value);
        } else if (value is String) {
          await prefs.setString(key, value);
        } else if (value is List) {
          await prefs.setStringList(
            key,
            value.map((e) => e.toString()).toList(),
          );
        }
      } catch (_) {
        // Skip individual keys that fail (e.g. type mismatch from older schema).
      }
    }
  }

  Future<void> _importTableFromJsonl(
    ArchiveFile file,
    String tableName,
    Set<String> knownCols,
  ) async {
    try {
      await db.customStatement('DELETE FROM $tableName');
    } catch (_) {}

    final bytes = file.readBytes();
    if (bytes == null || bytes.isEmpty) return;

    var lines = utf8
        .decode(bytes, allowMalformed: true)
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    // ArchiveFile caches what it decompressed; the lines are decoded now, so
    // the cached copy of a table that can run to hundreds of megabytes is pure
    // ballast for the rest of the import.
    file.clear();
    if (tableName == 'lorebook_use_acceptance_records') {
      int rank(String line) {
        try {
          final row = jsonDecode(line) as Map<String, dynamic>;
          return row['acceptance_kind'] == 'variation' ? 0 : 1;
        } catch (_) {
          return 2;
        }
      }

      lines.sort((a, b) => rank(a).compareTo(rank(b)));
    }

    final buffer = <(String, List<dynamic>)>[];
    var totalInserted = 0;
    await db.transaction(() async {
      await db.batch((batch) {
        for (final line in lines) {
          if ((++totalInserted % _batchSize) == 0) _cancel.check();
          Map<String, dynamic> r;
          try {
            r = jsonDecode(line) as Map<String, dynamic>;
            _stageLegacyStudioRuntimeRow(tableName, r);
            r = _canonicalizeRow(tableName, r);
          } catch (_) {
            continue;
          }
          final columns = r.keys.where(knownCols.contains).toList();
          if (columns.isEmpty) continue;

          final placeholders = columns.map((_) => '?').join(', ');
          final quotedColumns = columns.map((c) => '"$c"').join(', ');
          final sql =
              'INSERT OR REPLACE INTO $tableName ($quotedColumns) VALUES ($placeholders)';
          final args = <dynamic>[];
          for (final c in columns) {
            final v = r[c];
            if (v is List || v is Map) {
              args.add(jsonEncode(v));
            } else {
              args.add(v);
            }
          }
          buffer.add((sql, args));
          batch.customStatement(sql, args);
        }
      });
    });
    buffer.clear();
  }

  Future<void> _rebuildSessionLorebookEmbeddingQueue() async {
    await db.transaction(() async {
      await db.customStatement(
        "DELETE FROM embeddings WHERE source_type = 'session_lorebook_entry'",
      );
      await db.delete(db.sessionLorebookEmbeddingJobRows).go();
      final overlays = await db.select(db.sessionLorebookEvolutionRows).get();
      final jobs = SessionLorebookEmbeddingJobRepo(db);
      for (final overlay in overlays) {
        final checkpoint =
            await (db.select(db.sessionCanonCheckpointRows)
                  ..where(
                    (row) => row.chatSessionId.equals(overlay.chatSessionId),
                  )
                  ..orderBy([(row) => OrderingTerm.desc(row.sequence)])
                  ..limit(1))
                .getSingleOrNull();
        if (checkpoint == null) continue;
        await jobs.enqueueInTransaction(
          sessionId: overlay.chatSessionId,
          checkpointId: checkpoint.id,
          lorebookId: overlay.lorebookId,
          entryId: overlay.entryId,
          expectedContentHash: overlay.contentHash,
        );
      }
    });
  }

  Future<void> _importTablesFromJson(
    Map<String, dynamic> tables, {
    void Function(String stage)? onProgress,
  }) async {
    final existingColumns = <String, Set<String>>{};
    final allTableNames = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'drift_%'",
        )
        .get();
    for (final t in allTableNames) {
      final tName = t.read<String>('name');
      final cols = await db.customSelect("PRAGMA table_info('$tName')").get();
      existingColumns[tName] = cols.map((c) => c.read<String>('name')).toSet();
    }

    await db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      for (final entry in tables.entries) {
        _cancel.check();
        final tableName = entry.key;
        final rows = entry.value as List<dynamic>;
        if (rows.isEmpty) continue;

        onProgress?.call('Importing $tableName...');

        final knownCols = existingColumns[tableName];
        if (knownCols == null) continue;

        try {
          await db.customStatement('DELETE FROM $tableName');
        } catch (_) {}

        await db.transaction(() async {
          await db.batch((batch) {
            var i = 0;
            for (final row in rows) {
              if ((++i % _batchSize) == 0) _cancel.check();
              final source = Map<String, dynamic>.from(row as Map);
              _stageLegacyStudioRuntimeRow(tableName, source);
              final r = _canonicalizeRow(tableName, source);
              final columns = r.keys.where(knownCols.contains).toList();
              if (columns.isEmpty) continue;
              final placeholders = columns.map((_) => '?').join(', ');
              final quotedColumns = columns.map((c) => '"$c"').join(', ');
              final sql =
                  'INSERT OR REPLACE INTO $tableName ($quotedColumns) VALUES ($placeholders)';
              final args = <dynamic>[];
              for (final c in columns) {
                final v = r[c];
                if (v is List || v is Map) {
                  args.add(jsonEncode(v));
                } else {
                  args.add(v);
                }
              }
              batch.customStatement(sql, args);
            }
          });
        });
        await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
      }
      await db.applyLegacyStudioRuntimePayloads(_legacyStudioRuntimeRows);
    } finally {
      await db.customStatement('PRAGMA foreign_keys = ON');
    }
  }

  Map<String, dynamic> _canonicalizeRow(
    String tableName,
    Map<String, dynamic> row,
  ) {
    try {
      if (tableName == 'api_configs') {
        bool readBool(String key, {required bool fallback}) {
          final value = row[key];
          if (value is bool) return value;
          if (value is num) return value != 0;
          return fallback;
        }

        return {
          ...row,
          'endpoint': EndpointNormalizer.persistedLlmEndpoint(
            raw: row['endpoint']?.toString() ?? '',
            protocol: row['protocol']?.toString() ?? 'openai',
            model: row['model']?.toString() ?? '',
            stream: readBool('stream', fallback: true),
            useResponsesApi: readBool('use_responses_api', fallback: false),
          ),
          'embedding_endpoint': EndpointNormalizer.persistedEmbeddingEndpoint(
            row['embedding_endpoint']?.toString() ?? '',
          ),
        };
      }
      if (tableName == 'studio_preset_rows') {
        final blocks = row['blocks_json'];
        final source = blocks is String ? blocks : jsonEncode(blocks);
        final canonical = <String, dynamic>{
          ...row,
          'blocks_json': StudioPresetCodec.canonicalizeBlocksJson(source),
        };
        if (row.containsKey('agents_json')) {
          final agents = row['agents_json'];
          final agentsSource = agents is String ? agents : jsonEncode(agents);
          canonical['agents_json'] = StudioAgentCodec.canonicalizeAgentsJson(
            agentsSource,
          );
        }
        return canonical;
      }
      if (tableName == 'studio_config_rows') {
        final agents = row['agents_json'];
        final source = agents is String ? agents : jsonEncode(agents);
        return StudioAgentCodec.canonicalizeConfigRow({
          ...row,
          'agents_json': StudioAgentCodec.canonicalizeAgentsJson(source),
        });
      }
    } on Object {
      return row;
    }
    return row;
  }

  void _stageLegacyStudioRuntimeRow(
    String tableName,
    Map<String, dynamic> row,
  ) {
    if (tableName != 'studio_config_rows') return;
    const executionKeys = {
      'agents_json',
      'agents',
      'run_api_config_id',
      'runApiConfigId',
      'expensive_api_config_id',
      'expensiveApiConfigId',
      'cheap_api_config_id',
      'cheapApiConfigId',
      'cleaner_api_config_id',
      'cleanerApiConfigId',
      'max_final_history_messages',
      'maxFinalHistoryMessages',
    };
    if (row.keys.any(executionKeys.contains)) {
      _legacyStudioRuntimeRows.add(Map<String, dynamic>.from(row));
    }
  }

  Future<void> restoreGalleryImages(Map<String, dynamic>? galleryData) async {
    if (galleryData == null) return;

    for (final entry in galleryData.entries) {
      final charId = entry.key;
      final images = entry.value as List<dynamic>;

      final restoredEntries = <Map<String, dynamic>>[];

      for (final img in images) {
        _cancel.check();
        final imgMap = img as Map<String, dynamic>;
        final entryData = imgMap['entry'] as Map<String, dynamic>?;
        final base64Data = imgMap['base64'] as String?;
        if (base64Data == null) continue;

        final ext = extFromEntry(entryData);
        final id =
            entryData?['id'] as String? ??
            'gal_${DateTime.now().millisecondsSinceEpoch}';

        try {
          final savedPath = await imageStorage.saveBytes(
            base64Decode(base64Data),
            'gallery/$charId',
            id,
            ext,
          );
          if (entryData != null) {
            restoredEntries.add({...entryData, 'imagePath': savedPath});
          }
        } catch (_) {}
      }

      if (restoredEntries.isNotEmpty) {
        try {
          await db.customStatement(
            'UPDATE characters SET gallery_json = ? WHERE char_id = ?',
            [jsonEncode(restoredEntries), charId],
          );
        } catch (_) {}
      }
    }
  }

  Future<void> _restoreAvatars(Map<String, dynamic>? avatarsData) async {
    if (avatarsData == null) return;

    final chars = avatarsData['characters'] as Map<String, dynamic>?;
    if (chars != null) {
      for (final e in chars.entries) {
        _cancel.check();
        if (e.value is! String) continue;
        try {
          final bytes = base64Decode(e.value as String);
          final savedPath = await imageStorage.saveAvatar(
            e.key,
            Uint8List.fromList(bytes),
          );
          await db.customStatement(
            'UPDATE characters SET avatar_path = ? WHERE char_id = ?',
            [savedPath, e.key],
          );
        } catch (_) {}
      }
    }

    final personas = avatarsData['personas'] as Map<String, dynamic>?;
    if (personas != null) {
      for (final e in personas.entries) {
        _cancel.check();
        if (e.value is! String) continue;
        try {
          final bytes = base64Decode(e.value as String);
          final savedPath = await imageStorage.saveAvatar(
            e.key,
            Uint8List.fromList(bytes),
          );
          await db.customStatement(
            'UPDATE personas SET avatar_path = ? WHERE persona_id = ?',
            [savedPath, e.key],
          );
        } catch (_) {}
      }
    }
  }

  Future<void> _restoreAvatarsFromZip(List<ArchiveFile> avatarFiles) async {
    for (final f in avatarFiles) {
      _cancel.check();
      // avatars/<id>.png → id
      final base = p.basenameWithoutExtension(f.name);
      if (base.isEmpty) continue;
      try {
        final bytes = f.readBytes();
        f.clear();
        if (bytes == null) continue;
        final savedPath = await imageStorage.saveAvatar(base, bytes);
        if (f.name.startsWith('avatars/characters/') || !f.name.contains('/')) {
          await db.customStatement(
            'UPDATE characters SET avatar_path = ? WHERE char_id = ?',
            [savedPath, base],
          );
        } else if (f.name.startsWith('avatars/personas/')) {
          await db.customStatement(
            'UPDATE personas SET avatar_path = ? WHERE persona_id = ?',
            [savedPath, base],
          );
        }
      } catch (_) {}
    }
  }

  Future<void> _restoreGalleryFromZip(List<ArchiveFile> galleryFiles) async {
    // group by charId (gallery/<charId>/<id>.<ext>)
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final f in galleryFiles) {
      _cancel.check();
      final rel = f.name.substring('gallery/'.length);
      final parts = rel.split('/');
      if (parts.length < 2) continue;
      final charId = parts.first;
      final filename = parts.last;
      final ext = p.extension(filename).replaceFirst('.', '');
      final id = p.basenameWithoutExtension(filename);
      try {
        final bytes = f.readBytes();
        f.clear();
        if (bytes == null) continue;
        final savedPath = await imageStorage.saveBytes(
          bytes,
          'gallery/$charId',
          id,
          ext.isEmpty ? 'png' : ext,
        );
        grouped.putIfAbsent(charId, () => []).add({
          'id': id,
          'characterId': charId,
          'imagePath': savedPath,
        });
      } catch (_) {}
    }
    for (final e in grouped.entries) {
      try {
        await db.customStatement(
          'UPDATE characters SET gallery_json = ? WHERE char_id = ?',
          [jsonEncode(e.value), e.key],
        );
      } catch (_) {}
    }
  }
}
