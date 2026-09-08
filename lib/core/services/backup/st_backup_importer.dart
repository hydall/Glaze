import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../db/app_db.dart';
import '../../db/repositories/character_repo.dart';
import '../../db/repositories/chat_repo.dart';
import '../../db/repositories/lorebook_repo.dart';
import '../../db/repositories/persona_repo.dart';
import '../../db/repositories/preset_repo.dart';
import '../../import/silly_tavern_preset_parser.dart';
import '../../import/st_lorebook_importer.dart';
import '../../models/chat_message.dart';
import '../../models/persona.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import '../character_book_converter.dart';
import '../character_importer.dart';
import '../chat_import_export.dart';
import '../image_storage_service.dart';
import 'archive_stream.dart';
import 'backup_cancel.dart';

class StImportResult {
  int characters = 0;
  int lorebooks = 0;
  int presets = 0;
  int chats = 0;
  int personas = 0;
  final List<String> errors = [];
}

class StBackupImporter {
  final AppDatabase _db;
  final ImageStorageService _imageStorage;
  final ImportCancellationToken _cancel;
  late final CharacterRepo _charRepo;
  late final PersonaRepo _personaRepo;
  late final LorebookRepo _lorebookRepo;
  late final PresetRepo _presetRepo;
  late final ChatRepo _chatRepo;
  late final CharacterImporter _charImporter;

  StBackupImporter(this._db, this._imageStorage, [this._cancel = noCancel]) {
    _charRepo = CharacterRepo(_db);
    _personaRepo = PersonaRepo(_db);
    _lorebookRepo = LorebookRepo(_db);
    _presetRepo = PresetRepo(_db);
    _chatRepo = ChatRepo(_db);
    _charImporter = CharacterImporter(_imageStorage);
  }

  Future<StImportResult> importFromFile(
    String filePath, {
    void Function(String stage)? onProgress,
  }) async {
    final archive = ZipDecoder().decodeStream(InputFileStream(filePath));
    return _import(archive, onProgress: onProgress);
  }

  Future<StImportResult> import(
    Uint8List zipBytes, {
    void Function(String stage)? onProgress,
  }) async {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    return _import(archive, onProgress: onProgress);
  }

  Future<StImportResult> _import(
    Archive zip, {
    void Function(String stage)? onProgress,
  }) async {
    final result = StImportResult();
    final charNameToId = <String, String>{};

    onProgress?.call('Clearing existing data...');
    await _clearAllTables();
    _cancel.check();

    onProgress?.call('Importing characters...');
    await _importCharacters(zip, charNameToId, result);
    _cancel.check();

    onProgress?.call('Importing lorebooks...');
    await _importLorebooks(zip, result);
    _cancel.check();

    onProgress?.call('Importing presets...');
    await _importPresets(zip, result);
    _cancel.check();

    onProgress?.call('Importing chats...');
    await _importChats(zip, charNameToId, result);
    _cancel.check();

    onProgress?.call('Importing personas...');
    await _importPersonas(zip, result);
    _cancel.check();

    onProgress?.call('Finalizing...');
    return result;
  }

  Future<void> _clearAllTables() async {
    await _db.customStatement('PRAGMA foreign_keys = OFF');
    await _db.transaction(() async {
      const tables = [
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
      ];
      for (final table in tables) {
        try {
          await _db.customStatement('DELETE FROM $table');
        } catch (_) {}
      }
    });
    await _db.customStatement('PRAGMA foreign_keys = ON');
  }

  Future<void> _importCharacters(
    Archive zip,
    Map<String, String> charNameToId,
    StImportResult result,
  ) async {
    final paths = zip.files
        .where((f) =>
            f.isFile &&
            f.name.startsWith('characters/') &&
            f.name.toLowerCase().endsWith('.png') &&
            !f.name.substring('characters/'.length).contains('/'))
        .toList();

    for (final f in paths) {
      _cancel.check();
      try {
        final bytes = f.readBytes();
        if (bytes == null) continue;
        final fileName = f.name.split('/').last;
        final imported = await _charImporter.importFromBytes(bytes, fileName);
        await _charRepo.put(imported.character);

        if (imported.characterBookData != null) {
          final lb = convertCharacterBook(
              imported.characterBookData!, imported.character.id);
          await _lorebookRepo.put(lb);
        }

        final baseName = fileName.replaceAll(RegExp(r'\.png$', caseSensitive: false), '');
        charNameToId[baseName] = imported.character.id;
        result.characters++;
      } catch (e) {
        result.errors.add('Character ${f.name}: $e');
      }
    }
  }

  Future<void> _importLorebooks(Archive zip, StImportResult result) async {
    final paths = zip.files.where((f) =>
        f.isFile &&
        f.name.startsWith('worlds/') &&
        f.name.toLowerCase().endsWith('.json'));

    for (final f in paths) {
      _cancel.check();
      try {
        final text = utf8.decode(f.content as List<int>, allowMalformed: true);
        final json = jsonDecode(text) as Map<String, dynamic>;
        final fileName = f.name.split('/').last;
        final r = importSTLorebook(json, nameOverride: fileName);
        await _lorebookRepo.put(r.lorebook);
        result.lorebooks++;
      } catch (e) {
        result.errors.add('Lorebook ${f.name}: $e');
      }
    }
  }

  Future<void> _importPresets(Archive zip, StImportResult result) async {
    final paths = zip.files.where((f) =>
        f.isFile &&
        f.name.startsWith('OpenAI Settings/') &&
        f.name.toLowerCase().endsWith('.json'));

    for (final f in paths) {
      _cancel.check();
      try {
        final text = utf8.decode(f.content as List<int>, allowMalformed: true);
        final json = jsonDecode(text) as Map<String, dynamic>;
        final fileName = f.name
            .split('/')
            .last
            .replaceAll(RegExp(r'\.json$', caseSensitive: false), '');
        final preset = parseSillyTavernPreset(json, fileName);
        await _presetRepo.put(preset);
        result.presets++;
      } catch (e) {
        result.errors.add('Preset ${f.name}: $e');
      }
    }
  }

  Future<void> _importChats(
    Archive zip,
    Map<String, String> charNameToId,
    StImportResult result,
  ) async {
    final paths = zip.files.where((f) {
      if (!f.isFile || !f.name.startsWith('chats/')) return false;
      final lower = f.name.toLowerCase();
      return lower.endsWith('.jsonl') || lower.endsWith('.json');
    });

    final nextIdxByChar = <String, int>{};

    for (final f in paths) {
      _cancel.check();
      try {
        final parts = f.name.split('/');
        if (parts.length < 3) continue;
        final charFolder = parts[1];
        final glazeCharId = charNameToId[charFolder];
        if (glazeCharId == null) {
          result.errors
              .add('Chat ${f.name}: no character matched folder "$charFolder"');
          continue;
        }

        ChatImportResult parsed;
        if (f.name.toLowerCase().endsWith('.jsonl')) {
          parsed = await _parseJsonlChat(f);
        } else {
          parsed = importChatFromJsonlString(
              utf8.decode(f.content as List<int>, allowMalformed: true));
        }
        if (parsed.messages.isEmpty) continue;

        final idx = (nextIdxByChar[glazeCharId] ?? 0) + 1;
        nextIdxByChar[glazeCharId] = idx;

        await _chatRepo.put(ChatSession(
          id: '${glazeCharId}_$idx',
          characterId: glazeCharId,
          sessionIndex: idx,
          messages: parsed.messages,
          updatedAt: currentTimestampSeconds(),
        ));
        result.chats++;
      } catch (e) {
        result.errors.add('Chat ${f.name}: $e');
      }
    }

    for (final entry in nextIdxByChar.entries) {
      _cancel.check();
      final character = await _charRepo.getById(entry.key);
      if (character != null) {
        await _charRepo
            .put(character.copyWith(currentSessionIndex: entry.value));
      }
    }
  }

  /// Streams a `.jsonl` chat file line-by-line, never holding the whole
  /// file in memory.
  Future<ChatImportResult> _parseJsonlChat(ArchiveFile file) async {
    final messages = <ChatMessage>[];
    String? userName;
    var index = 0;
    await for (final line in readArchiveFileLines(file)) {
      _cancel.check();
      if (line.trim().isEmpty) continue;
      Map<String, dynamic> obj;
      try {
        obj = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (obj.containsKey('chat_metadata')) {
        userName = obj['user_name'] as String?;
        continue;
      }
      final msg = convertStMessage(obj, index);
      if (msg == null) continue;
      messages.add(msg);
      index++;
    }
    return ChatImportResult(messages: messages, userName: userName);
  }

  Future<void> _importPersonas(Archive zip, StImportResult result) async {
    final settingsFile = zip.files.firstWhere(
      (f) => f.isFile && f.name.toLowerCase().endsWith('settings.json'),
      orElse: () => ArchiveFile('', 0, <int>[]),
    );
    if (settingsFile.name.isEmpty) return;

    Map<String, dynamic> settings;
    try {
      final text =
          utf8.decode(settingsFile.content as List<int>, allowMalformed: true);
      settings = jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      result.errors.add('Personas (settings.json): $e');
      return;
    }

    final pu = settings['power_user'] is Map<String, dynamic>
        ? settings['power_user'] as Map<String, dynamic>
        : settings;
    final personasMap =
        (pu['personas'] as Map<String, dynamic>?) ??
            (settings['personas'] as Map<String, dynamic>?) ??
            {};
    final descMap =
        (pu['persona_descriptions'] as Map<String, dynamic>?) ??
            (settings['persona_descriptions'] as Map<String, dynamic>?) ??
            {};

    for (final entry in personasMap.entries) {
      _cancel.check();
      try {
        final avatarFilename = entry.key;
        final personaName = entry.value.toString();
        if (avatarFilename.isEmpty) continue;

        final descData = descMap[avatarFilename];
        String description = '';
        if (descData is Map<String, dynamic>) {
          description = (descData['description'] as String?) ?? '';
        }

        final id = _uniqueId();
        String? avatarPath;
        final avatarLower = avatarFilename.toLowerCase();
        for (final f in zip.files) {
          if (!f.isFile) continue;
          final n = f.name.toLowerCase();
          if (n.contains('user avatars') && n.endsWith(avatarLower)) {
            final avatarBytes = f.readBytes();
            if (avatarBytes == null) break;
            avatarPath = await _imageStorage.saveAvatar(id, avatarBytes);
            break;
          }
        }

        await _personaRepo.put(Persona(
          id: id,
          name: personaName,
          prompt: description,
          avatarPath: avatarPath,
          createdAt: currentTimestampSeconds(),
        ));
        result.personas++;
      } catch (e) {
        result.errors.add('Persona ${entry.key}: $e');
      }
    }
  }

  String _uniqueId() =>
      '${generateId()}_${(DateTime.now().microsecondsSinceEpoch % 1000000).toRadixString(36)}';
}
