import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../db/app_db.dart';
import '../file_export_service.dart';
import '../image_storage_service.dart';

class BackupExporter {
  // Schema version history:
  //   2 — initial v2 ZIP format (characters, chats, presets, api_configs,
  //         personas, lorebooks, embeddings, chat_summaries, memory_book_rows)
  //   3 — added extension_presets and info_blocks tables
  //   4 — added studio_config_rows (Studio agent profiles/settings)
  //   5 — added tracker_snapshots (per-message tracker state for rollback)
  //   6 — added pipeline_settings_rows (per-session pipeline LLM settings).
  //   7 — removed pipeline_settings_rows from the backup whitelist. Pipeline
  //         settings are now a singleton global in SharedPreferences; the
  //         Drift table was dropped in DB schema v52. The SharedPreferences
  //         payload ('pipelineSettings' key) is still captured via
  //         preferences.json.
  //   8 — added tracker_rows (live Tracker Values) alongside snapshots.
  //   9 — added studio_preset_rows (DB-backed Studio prompt block presets).
  //  10 — added atomic character facts and immutable session baselines.
  //  11 — added complete Card Rewriter/session-canon provenance.
  //  12 — added complete Agent Ops reconciliation and recovery provenance.
  //  13 — Collector journals use three-reconciliation batches.
  static const int schemaVersion = 13;

  /// Rows fetched per page while serializing a table. The whole table is never
  /// materialized at once — `chat_sessions` stores every message of every chat
  /// and can be hundreds of MB, which previously caused an out-of-memory crash.
  static const int _tablePageSize = 500;

  /// Table files up to this size are deflate-compressed in memory. Larger ones
  /// are stored uncompressed and streamed straight from the staging file, so a
  /// multi-GB table cannot exhaust RAM (the archive encoder buffers a whole
  /// compressed entry in memory).
  static const int _compressInMemoryBytes = 4 * 1024 * 1024;

  static const List<String> tableNames = [
    'characters',
    'character_revision_rows',
    'chat_sessions',
    'presets',
    'api_configs',
    'personas',
    'lorebooks',
    'lorebook_use_manifests',
    'lorebook_use_manifest_entries',
    'lorebook_use_acceptance_records',
    'embeddings',
    'chat_summaries',
    'memory_book_rows',
    'extension_presets',
    'info_blocks',
    'studio_config_rows',
    'studio_preset_rows',
    'tracker_rows',
    'tracker_snapshots',
    'character_folders',
    'character_folder_members',
    'memory_catalog_rows',
    'memory_entity_rows',
    'memory_salience_rows',
    'memory_cadence_rows',
    'memory_consolidation_rows',
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

  final AppDatabase _db;
  final ImageStorageService _imageStorage;

  BackupExporter(this._db, this._imageStorage);

  Future<String> export() async {
    final tempFile = await buildArchive(Directory.systemTemp);
    final filename = p.basename(tempFile.path);
    try {
      return await FileExportService.exportFile(
        sourcePath: tempFile.path,
        filename: filename,
        subfolder: 'backup',
      );
    } finally {
      try {
        await tempFile.delete();
      } catch (_) {}
    }
  }

  /// Builds the `.glz` archive inside [directory] and returns the file.
  ///
  /// Split out from [export] so tests can exercise the full serialization
  /// without going through the platform save/share dialog.
  @visibleForTesting
  Future<File> buildArchive(Directory directory) async {
    final now = DateTime.now();
    final filename =
        'Glaze_backup_${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}.glz';

    final tempFile = File(p.join(directory.path, filename));
    final stagingDir = await Directory.systemTemp.createTemp(
      'glaze_backup_staging_',
    );
    final encoder = ZipFileEncoder();
    encoder.create(tempFile.path);

    try {
      await _writeZip(encoder, stagingDir);
      await encoder.close();
      return tempFile;
    } catch (e) {
      try {
        await encoder.close();
      } catch (_) {}
      try {
        await tempFile.delete();
      } catch (_) {}
      rethrow;
    } finally {
      try {
        await stagingDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _writeZip(ZipFileEncoder encoder, Directory stagingDir) async {
    // 1. manifest.json
    final manifest = <String, dynamic>{
      '_isGlazeBackup': true,
      '_glazeVersion': schemaVersion,
      '_source': 'flutter',
      'schemaVersion': schemaVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'tables': tableNames,
    };
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    encoder.addArchiveFile(ArchiveFile.bytes('manifest.json', manifestBytes));

    // 2. tables/<name>.jsonl — paged out to a staging file, then streamed
    // into the archive so peak RAM stays bounded regardless of table size.
    for (final tableName in tableNames) {
      final staged = File(p.join(stagingDir.path, '$tableName.jsonl'));
      await _writeTableAsNdjson(tableName, staged);
      await _addStagedTable(encoder, staged, 'tables/$tableName.jsonl');
    }

    // 3. preferences.json
    final prefs = await SharedPreferences.getInstance();
    final prefsMap = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      final value = prefs.get(key);
      if (value != null) prefsMap[key] = value;
    }
    final prefsBytes = utf8.encode(jsonEncode(prefsMap));
    encoder.addArchiveFile(ArchiveFile.bytes('preferences.json', prefsBytes));

    // 4. avatars/characters/<id>.png and avatars/personas/<id>.png —
    // copy directly from disk into the zip via streams. We do not
    // encode them as base64, which is the main memory win over v1.
    final avatarIds = <String>{};
    final charactersRows = await _db
        .customSelect('SELECT char_id FROM characters')
        .get();
    for (final row in charactersRows) {
      final id = row.data['char_id'] as String?;
      if (id != null && id.isNotEmpty) avatarIds.add(id);
    }
    final personasRows = await _db
        .customSelect('SELECT persona_id FROM personas')
        .get();
    final personaIds = <String>{};
    for (final row in personasRows) {
      final id = row.data['persona_id'] as String?;
      if (id != null && id.isNotEmpty) personaIds.add(id);
    }

    final avatarsDir = Directory(p.join(_imageStorage.baseDir, 'avatars'));
    if (await avatarsDir.exists()) {
      await for (final entity in avatarsDir.list(followLinks: false)) {
        if (entity is! File) continue;
        final id = p.basenameWithoutExtension(entity.path);
        final ext = p.extension(entity.path).replaceFirst('.', '');
        final inArchive = ext.isEmpty ? 'avatars/$id' : 'avatars/$id.$ext';
        // If the id is a known character or persona, group it under the
        // matching subfolder so the importer can route it correctly.
        String? subfolder;
        if (avatarIds.contains(id)) {
          subfolder = 'characters';
        } else if (personaIds.contains(id)) {
          subfolder = 'personas';
        }
        if (subfolder != null) {
          final out = ext.isEmpty
              ? 'avatars/$subfolder/$id'
              : 'avatars/$subfolder/$id.$ext';
          await encoder.addFile(entity, out);
        } else {
          // Unknown id — keep the flat path for forward-compat.
          await encoder.addFile(entity, inArchive);
        }
      }
    }

    // 5. gallery/<charId>/<id>.<ext> — copy from disk as-is.
    final galleryDir = Directory(p.join(_imageStorage.baseDir, 'gallery'));
    if (await galleryDir.exists()) {
      await for (final charDir in galleryDir.list(followLinks: false)) {
        if (charDir is! Directory) continue;
        final charId = p.basename(charDir.path);
        await for (final f in charDir.list(followLinks: false)) {
          if (f is! File) continue;
          await encoder.addFile(f, 'gallery/$charId/${p.basename(f.path)}');
        }
      }
    }
  }

  /// Serializes a table to NDJSON on disk, one page of rows at a time.
  ///
  /// Drift doesn't support true row-streaming, so we page with LIMIT/OFFSET
  /// over a stable `rowid` order. Peak RAM is bounded by [_tablePageSize] rows
  /// plus the largest single row, instead of the entire table.
  Future<void> _writeTableAsNdjson(String tableName, File out) async {
    final orderBy = tableName == 'lorebook_use_acceptance_records'
        ? " ORDER BY CASE acceptance_kind WHEN 'variation' THEN 0 ELSE 1 END, accepted_at, acceptance_id, rowid"
        : ' ORDER BY rowid';
    final sink = out.openWrite();
    try {
      var offset = 0;
      while (true) {
        final rows = await _db
            .customSelect(
              'SELECT * FROM $tableName$orderBy LIMIT $_tablePageSize OFFSET $offset',
            )
            .get();
        if (rows.isEmpty) break;
        for (final row in rows) {
          try {
            sink.add(utf8.encode(jsonEncode(row.data)));
            sink.add(const [0x0A]); // '\n'
          } catch (_) {
            // skip unserializable rows
          }
        }
        offset += rows.length;
        if (rows.length < _tablePageSize) break;
        await sink.flush();
      }
    } finally {
      await sink.close();
    }
  }

  /// Adds a staged table file to the archive. Small files are compressed in
  /// memory; large ones are added as a stored (uncompressed) streaming entry
  /// so the encoder never has to hold the whole file in RAM.
  Future<void> _addStagedTable(
    ZipFileEncoder encoder,
    File file,
    String archiveName,
  ) async {
    final length = await file.length();
    if (length <= _compressInMemoryBytes) {
      final bytes = await file.readAsBytes();
      encoder.addArchiveFile(ArchiveFile.bytes(archiveName, bytes));
      return;
    }
    final archiveFile = ArchiveFile.stream(
      archiveName,
      InputFileStream(file.path),
    );
    archiveFile.compression = CompressionType.none;
    archiveFile.lastModTime =
        (await file.lastModified()).millisecondsSinceEpoch ~/ 1000;
    archiveFile.mode = (await file.stat()).mode;
    encoder.addArchiveFile(archiveFile);
  }
}
