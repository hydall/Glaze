import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
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
  static const int _schemaVersion = 10;

  final AppDatabase _db;
  final ImageStorageService _imageStorage;

  BackupExporter(this._db, this._imageStorage);

  Future<String> export() async {
    final now = DateTime.now();
    final filename =
        'Glaze_backup_${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}.glz';

    final tempFile = File('${Directory.systemTemp.path}/$filename');
    final encoder = ZipFileEncoder();
    encoder.create(tempFile.path);

    try {
      await _writeZip(encoder);
      await encoder.close();
      final path = await FileExportService.exportFile(
        sourcePath: tempFile.path,
        filename: filename,
        subfolder: 'backup',
      );
      try {
        await tempFile.delete();
      } catch (_) {}
      return path;
    } catch (e) {
      try {
        await encoder.close();
      } catch (_) {}
      try {
        await tempFile.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _writeZip(ZipFileEncoder encoder) async {
    // 1. manifest.json
    final manifest = <String, dynamic>{
      '_isGlazeBackup': true,
      '_glazeVersion': _schemaVersion,
      '_source': 'flutter',
      'schemaVersion': _schemaVersion,
      'exportedAt': DateTime.now().toIso8601String(),
    };
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    encoder.addArchiveFile(ArchiveFile.bytes('manifest.json', manifestBytes));

    // 2. tables/<name>.jsonl — streamed per row.
    for (final tableName in _knownTableNames()) {
      final bytes = await _streamTableAsNdjson(tableName);
      if (bytes.isEmpty) continue;
      encoder.addArchiveFile(
        ArchiveFile.bytes('tables/$tableName.jsonl', bytes),
      );
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

  /// Serializes a table to NDJSON bytes. Loads the table fully into memory
  /// (Drift doesn't support true row-streaming), but does so one table at
  /// a time, so peak RAM is bounded by the largest single table instead of
  /// the whole database.
  Future<List<int>> _streamTableAsNdjson(String tableName) async {
    final builder = BytesBuilder(copy: false);
    final rows = await _db.customSelect('SELECT * FROM $tableName').get();
    for (final row in rows) {
      try {
        final data = row.data;
        builder.add(utf8.encode(jsonEncode(data)));
        builder.add([0x0A]); // '\n'
      } catch (_) {
        // skip unserializable rows
      }
    }
    return builder.takeBytes();
  }

  List<String> _knownTableNames() {
    return const [
      'characters',
      'chat_sessions',
      'presets',
      'api_configs',
      'personas',
      'lorebooks',
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
    ];
  }
}
