import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_db.dart';
import 'backup/backup_cancel.dart';
import 'backup/backup_exporter.dart';
import 'backup/flutter_backup_importer.dart';
import 'backup/js_backup_importer.dart';
import 'backup/st_backup_importer.dart';
import 'backup/tavo_backup_importer.dart';
import 'image_storage_service.dart';

/// Decoded backup envelope routed to a specific importer.
enum BackupFormat { legacyJsonGlaze, flutterZip, sillyTavernZip, tavoZip }

class BackupService {
  /// Master switch for Tavo (`.tbk`) backup import.
  ///
  /// Disabled: the format is not advertised in the UI and is not detected
  /// here, so a Tavo archive is rejected as an unsupported ZIP. The importer
  /// ([TavoBackupImporter]), its LMDB reader and [BackupFormat.tavoZip] stay
  /// in the tree — flipping this back to `true` re-enables the whole path.
  ///
  /// Deliberately `final` rather than `const` so the disabled branch is not
  /// treated as dead code by the analyzer.
  static final bool tavoImportEnabled = false;

  static const _zipMagic = [0x50, 0x4B, 0x03, 0x04];
  static const _legacyV1JsonGlazeMaxBytes = 4;

  final AppDatabase _db;
  final ImageStorageService _imageStorage;
  final _CancelFlag _cancelFlag = _CancelFlag();
  late final ImportCancellationToken _cancel = ImportCancellationToken.wrap(
    isCancelled: _cancelFlag.isCancelled,
    check: _cancelFlag.check,
  );

  BackupService(this._db, ImageStorageService _imageStorage)
      : _imageStorage = _imageStorage;

  Future<String> exportBackup() =>
      BackupExporter(_db, _imageStorage).export();

  /// Cancels an in-flight import. The importer checks the flag at every
  /// major stage (before each table wipe and between batches).
  void cancelImport() => _cancelFlag.cancel();

  /// Token shared with importers. They call [ImportCancellationToken.check]
  /// at safe points and bail out with [ImportCancelledException].
  ImportCancellationToken get cancelToken => _cancel;

  /// Imports a backup from a file path. Streamed — the file is never read
  /// fully into memory.
  ///
  /// [onProgress] is called with a human-readable stage label.
  /// [onDetected] (optional) is called once with the detected format,
  /// useful for UI to show a stage-specific label.
  Future<void> importBackupFromFile(
    String filePath, {
    void Function(String stage)? onProgress,
    void Function(BackupFormat format)? onDetected,
  }) async {
    _cancelFlag.reset();
    final format = await _detectFormat(filePath);
    onDetected?.call(format);
    switch (format) {
      case BackupFormat.sillyTavernZip:
        await StBackupImporter(_db, _imageStorage, _cancel)
            .importFromFile(filePath, onProgress: onProgress);
        break;
      case BackupFormat.tavoZip:
        await TavoBackupImporter(_db, _imageStorage, _cancel)
            .importFromFile(filePath, onProgress: onProgress);
        break;
      case BackupFormat.flutterZip:
        await FlutterBackupImporter(_db, _imageStorage, _cancel)
            .importFromZipFile(filePath, onProgress: onProgress);
        break;
      case BackupFormat.legacyJsonGlaze:
        await _importLegacyJsonGlaze(filePath, onProgress: onProgress);
        break;
    }
    await _db.purgeRetiredAgenticMicroMemory();
  }

  Future<BackupFormat> _detectFormat(String filePath) async {
    final raf = await File(filePath).open();
    try {
      final header = await raf.read(_legacyV1JsonGlazeMaxBytes);
      if (header.length >= 4 &&
          header[0] == _zipMagic[0] &&
          header[1] == _zipMagic[1] &&
          header[2] == _zipMagic[2] &&
          header[3] == _zipMagic[3]) {
        final archive = ZipDecoder().decodeStream(InputFileStream(filePath));
        if (tavoImportEnabled && _isTavoArchive(archive)) {
          return BackupFormat.tavoZip;
        }
        if (_isSillyTavernArchive(archive)) return BackupFormat.sillyTavernZip;
        if (_isFlutterGlazeArchive(archive)) return BackupFormat.flutterZip;
        throw const FormatException(
            'ZIP is neither a SillyTavern nor a Glaze backup');
      }
      if (header.isNotEmpty && header[0] == 0x7B) {
        return BackupFormat.legacyJsonGlaze;
      }
      throw const FormatException('Unsupported backup file format');
    } finally {
      await raf.close();
    }
  }

  Future<void> _importLegacyJsonGlaze(
    String filePath, {
    void Function(String stage)? onProgress,
  }) async {
    onProgress?.call('Reading legacy backup...');
    final raf = await File(filePath).open();
    final builder = BytesBuilder(copy: false);
    try {
      const chunk = 1 << 20; // 1 MB
      while (true) {
        _cancel.check();
        final dst = Uint8List(chunk);
        final n = await raf.readInto(dst);
        if (n <= 0) break;
        if (n == chunk) {
          builder.add(dst);
        } else {
          builder.add(Uint8List.sublistView(dst, 0, n));
        }
      }
    } finally {
      await raf.close();
    }
    final bytes = builder.toBytes();
    onProgress?.call('Parsing legacy backup...');
    final jsonString = utf8.decode(bytes, allowMalformed: true);
    final data = jsonDecode(jsonString) as Map<String, dynamic>;
    onProgress?.call('Importing legacy backup...');
    final isGlazeBackup = data['_isGlazeBackup'] == true ||
        data.containsKey('tables') ||
        data.containsKey('characters');
    if (!isGlazeBackup) {
      throw const FormatException(
          'Legacy backup is not a valid Glaze file. Please re-export from the source app.');
    }
    if (data['_source'] == 'flutter') {
      // Old Glaze Flutter v1 monolith. Refused by policy — tell the user
      // to re-export from a v2 build.
      throw const FormatException(
          'Old Glaze backup format detected. Please re-export from the source app to continue.');
    }
    await JsBackupImporter(_db, _imageStorage)
        .import(data, onProgress: onProgress);
    await _deleteOrphanedSessions();
    await _applyPreferences(data);
  }

  Future<void> _applyPreferences(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final prefsData = data['preferences'] as Map<String, dynamic>?;
    if (prefsData != null) {
      final themeKeys = prefs.getKeys().where(
          (k) => k.startsWith('gz_theme_') || k.startsWith('glaze_theme_'));
      for (final k in themeKeys) {
        await prefs.remove(k);
      }
      for (final entry in prefsData.entries) {
        final v = entry.value;
        if (v is bool) {
          await prefs.setBool(entry.key, v);
        } else if (v is int) {
          await prefs.setInt(entry.key, v);
        } else if (v is double) {
          await prefs.setDouble(entry.key, v);
        } else if (v is String) {
          await prefs.setString(entry.key, v);
        }
      }
    }
    final lsData = data['localStorage'] as Map<String, dynamic>?;
    if (lsData != null) {
      final personaConnsRaw = lsData['gz_persona_connections'];
      if (personaConnsRaw != null) {
        try {
          final parsed = personaConnsRaw is String
              ? jsonDecode(personaConnsRaw) as Map<String, dynamic>
              : personaConnsRaw as Map<String, dynamic>;
          final conns = <String, dynamic>{
            'character': parsed['character'] ?? <String, dynamic>{},
            'chat': parsed['chat'] ?? <String, dynamic>{},
          };
          await prefs.setString('personaConnections', jsonEncode(conns));
        } catch (_) {}
      }
    }
  }

  bool _isTavoArchive(Archive archive) {
    for (final f in archive.files) {
      if (f.isFile && f.name.toLowerCase().endsWith('data.mdb')) return true;
    }
    return false;
  }

  bool _isSillyTavernArchive(Archive archive) {
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final n = f.name;
      if (n.startsWith('characters/') ||
          n.startsWith('worlds/') ||
          n.startsWith('OpenAI Settings/') ||
          n.startsWith('chats/') ||
          n.toLowerCase().endsWith('settings.json')) {
        return true;
      }
    }
    return false;
  }

  bool _isFlutterGlazeArchive(Archive archive) {
    for (final f in archive.files) {
      if (f.isFile && f.name == 'manifest.json') return true;
    }
    return false;
  }

  Future<void> _deleteOrphanedSessions() async {
    final charIds =
        (await _db.select(_db.characters).get()).map((r) => r.charId).toSet();
    if (charIds.isEmpty) return;

    final sessions = await _db.select(_db.chatSessions).get();
    final orphanIds = sessions
        .where((s) => !charIds.contains(s.characterId))
        .map((s) => s.sessionId)
        .toList();
    if (orphanIds.isEmpty) return;

    await _db.transaction(() async {
      for (final sid in orphanIds) {
        await (_db.delete(_db.chatSessions)..where((t) => t.sessionId.equals(sid))).go();
        await (_db.delete(_db.memoryBookRows)..where((t) => t.sessionId.equals(sid))).go();
        await (_db.delete(_db.chatSummaries)..where((t) => t.sessionId.equals(sid))).go();
      }
    });
  }
}

/// Cancellation flag shared between the service and importers.
class _CancelFlag {
  bool _cancelled = false;

  bool isCancelled() => _cancelled;

  void cancel() => _cancelled = true;

  void reset() => _cancelled = false;

  /// Throws [ImportCancelledException] if cancellation was requested.
  void check() {
    if (_cancelled) {
      throw const ImportCancelledException();
    }
  }
}
