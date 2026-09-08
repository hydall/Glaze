import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:archive/archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../db/app_db.dart';
import '../../db/repositories/api_config_repo.dart';
import '../../db/repositories/character_repo.dart';
import '../../db/repositories/chat_repo.dart';
import '../../db/repositories/lorebook_repo.dart';
import '../../db/repositories/persona_repo.dart';
import '../../db/repositories/preset_repo.dart';
import '../../import/silly_tavern_preset_parser.dart';
import '../../models/api_config.dart';
import '../../models/chat_message.dart';
import '../../models/lorebook.dart';
import '../../models/persona.dart';
import '../../state/global_regex_provider.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import '../character_importer.dart';
import '../image_storage_service.dart';
import 'backup_cancel.dart';
import 'tavo_lmdb_reader.dart';

class TavoImportResult {
  int characters = 0;
  int lorebooks = 0;
  int presets = 0;
  int chats = 0;
  int personas = 0;
  int apis = 0;
  int regexes = 0;
  final List<String> errors = [];
}

class TavoBackupImporter {
  final AppDatabase _db;
  final ImageStorageService _imageStorage;
  final ImportCancellationToken _cancel;
  late final CharacterRepo _charRepo;
  late final PersonaRepo _personaRepo;
  late final LorebookRepo _lorebookRepo;
  late final PresetRepo _presetRepo;
  late final ApiConfigRepo _apiRepo;
  late final ChatRepo _chatRepo;
  late final CharacterImporter _charImporter;

  TavoBackupImporter(this._db, this._imageStorage, [this._cancel = noCancel]) {
    _charRepo = CharacterRepo(_db);
    _personaRepo = PersonaRepo(_db);
    _lorebookRepo = LorebookRepo(_db);
    _presetRepo = PresetRepo(_db);
    _apiRepo = ApiConfigRepo(_db);
    _chatRepo = ChatRepo(_db);
    _charImporter = CharacterImporter(_imageStorage);
  }

  Future<TavoImportResult> importFromFile(
    String filePath, {
    void Function(String stage)? onProgress,
  }) async {
    final archive = ZipDecoder().decodeStream(InputFileStream(filePath));
    return _import(archive, onProgress: onProgress);
  }

  Future<TavoImportResult> import(
    Uint8List zipBytes, {
    void Function(String stage)? onProgress,
  }) async {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    return _import(archive, onProgress: onProgress);
  }

  Future<TavoImportResult> _import(
    Archive zip, {
    void Function(String stage)? onProgress,
  }) async {
    final result = TavoImportResult();

    onProgress?.call('backup_progress_clearing'.tr());
    await _clearAllTables();
    _cancel.check();

    onProgress?.call('backup_progress_reading'.tr());
    final mdbFile = zip.files.firstWhere(
      (f) => f.isFile && f.name.toLowerCase().endsWith('data.mdb'),
      orElse: () => throw const FormatException(
          'No data.mdb found in Tavo backup zip.'),
    );
    final mdbContent = mdbFile.content;
    final tavoData = parseTavoLmdb(
        mdbContent);

    final charEntityIdToGlazeId = <int, String>{};

    onProgress?.call('backup_progress_personas'.tr());
    await _importPersonas(tavoData, zip, result);
    _cancel.check();

    onProgress?.call('backup_progress_apis'.tr());
    await _importApiEndpoints(tavoData, result);
    _cancel.check();

    onProgress?.call('backup_progress_regex'.tr());
    await _importRegexes(tavoData, result);
    _cancel.check();

    onProgress?.call('backup_progress_lorebooks'.tr());
    await _importLorebooks(tavoData, result);
    _cancel.check();

    onProgress?.call('backup_progress_presets'.tr());
    await _importPresets(tavoData, result);
    _cancel.check();

    onProgress?.call('backup_progress_characters'.tr());
    await _importCharacters(tavoData, zip, charEntityIdToGlazeId, result);
    _cancel.check();

    onProgress?.call('backup_progress_chats'.tr());
    await _importChats(tavoData, charEntityIdToGlazeId, result);
    _cancel.check();

    onProgress?.call('backup_progress_finalizing'.tr());
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

  Future<Uint8List?> _readAvatarFromZip(
      Archive zip, String? charaCardPath) async {
    if (charaCardPath == null || charaCardPath.isEmpty) return null;
    final filename = charaCardPath.split('/').last.toLowerCase();
    for (final f in zip.files) {
      if (!f.isFile) continue;
      final lower = f.name.toLowerCase();
      if (lower.endsWith('charactercards/$filename') ||
          lower.endsWith('/$filename') ||
          lower == filename) {
        return f.readBytes();
      }
    }
    return null;
  }

  Future<void> _importPersonas(
      TavoData data, Archive zip, TavoImportResult result) async {
    final personas = data.categories['persona_ref'];
    if (personas == null || personas.isEmpty) return;

    for (final pref in personas) {
      _cancel.check();
      try {
        final s = pref.structured;
        final name = (s['name'] as String?) ?? '';
        final avatarPath = (s['avatarPath'] as String?) ?? '';
        String description = (s['description'] as String?) ?? '';

        String? finalName;
        String? finalPrompt;
        String? rawAvatarRef;

        if (name.isEmpty && description.isEmpty) {
          // Fallback to extracted text strings
          final strings = pref.fields
              .where((f) => f.type == 'text' && (f.data as String).trim().isNotEmpty)
              .map((f) => f.data as String)
              .toList();
          if (strings.isEmpty) continue;

          rawAvatarRef = strings.firstWhere(
            (s) => s.startsWith('charaCard/'),
            orElse: () => '',
          );
          if (rawAvatarRef.isEmpty) rawAvatarRef = null;

          final textOnly = strings.where((s) => s != rawAvatarRef).toList();
          if (textOnly.length >= 2) {
            textOnly.sort((a, b) => b.length.compareTo(a.length));
            finalPrompt = textOnly.first;
            finalName = textOnly.last;
          } else if (textOnly.isNotEmpty) {
            finalName = textOnly.first;
            finalPrompt = '';
          } else {
            continue;
          }
        } else {
          finalName = name.isNotEmpty ? name : 'User Persona';
          finalPrompt = description;
          rawAvatarRef = avatarPath.isNotEmpty ? avatarPath : null;
        }

        final id = _uniqueId();
        String? savedAvatarPath;
        if (rawAvatarRef != null) {
          final bytes = await _readAvatarFromZip(zip, rawAvatarRef);
          if (bytes != null) {
            savedAvatarPath = await _imageStorage.saveAvatar(id, bytes);
          }
        }

        await _personaRepo.put(Persona(
          id: id,
          name: finalName,
          prompt: finalPrompt,
          avatarPath: savedAvatarPath,
          createdAt: currentTimestampSeconds(),
        ));
        result.personas++;
      } catch (e) {
        result.errors.add('Tavo Persona: $e');
      }
    }
  }

  Future<void> _importApiEndpoints(
      TavoData data, TavoImportResult result) async {
    final endpoints = data.categories['endpoint'];
    if (endpoints == null || endpoints.isEmpty) return;

    final seen = <String>{};
    for (final ep in endpoints) {
      _cancel.check();
      try {
        final s = ep.structured;
        final url = (s['url'] as String?) ?? '';
        final model = (s['model'] as String?) ?? '';
        final name = (s['name'] as String?) ?? '';
        final paramsJson = s['params_json'] as String?;
        Map<String, dynamic> params = {};
        if (paramsJson != null) {
          try {
            final decoded = jsonDecode(paramsJson);
            if (decoded is Map<String, dynamic>) params = decoded;
          } catch (_) {}
        }

        final dedupKey = '$url|$model';
        if (seen.contains(dedupKey)) continue;
        seen.add(dedupKey);

        final temperature = (params['temperature'] as num?)?.toDouble() ?? 0.7;
        final topP = (params['top_p'] as num?)?.toDouble() ?? 0.9;
        final topK = (params['top_k'] as num?)?.toInt() ?? 0;
        final frequencyPenalty =
            (params['frequency_penalty'] as num?)?.toDouble() ?? 0.0;
        final presencePenalty =
            (params['presence_penalty'] as num?)?.toDouble() ?? 0.0;
        final maxTokens = (params['max_tokens'] as num?)?.toInt() ?? 8000;
        final contextSize = (params['context_length'] as num?)?.toInt() ?? 32000;

        await _apiRepo.put(ApiConfig(
          id: 'tavo_${_uniqueId()}',
          name: name.isNotEmpty ? name : (url.isNotEmpty ? url : 'Tavo Endpoint'),
          providerId: 'openai_compatible',
          endpoint: url,
          model: model,
          maxTokens: maxTokens,
          contextSize: contextSize,
          temperature: temperature,
          topP: topP,
          topK: topK,
          frequencyPenalty: frequencyPenalty,
          presencePenalty: presencePenalty,
          stream: true,
        ));
        result.apis++;
      } catch (e) {
        result.errors.add('Tavo API: $e');
      }
    }
  }

  Future<void> _importRegexes(
      TavoData data, TavoImportResult result) async {
    final regexes = data.categories['regex'];
    if (regexes == null || regexes.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    // Mirror JS behaviour: Tavo import wipes existing regex scripts before
    // appending the imported set.
    await prefs.remove('gz_global_regex_scripts');

    final imported = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    for (final regGroup in regexes) {
      _cancel.check();
      try {
        final s = regGroup.structured;
        final groupName = (s['name'] as String?) ?? '';

        // rules_json comes through the extracted-fields fallback because it
        // isn't in REGEX_FIELDS.
        List<dynamic>? rulesJson;
        final rulesStr = s['rules_json'] as String?;
        if (rulesStr != null) {
          try {
            final decoded = jsonDecode(rulesStr);
            if (decoded is List) rulesJson = decoded;
          } catch (_) {}
        }
        if (rulesJson == null) {
          for (final f in regGroup.fields) {
            if (f.type == 'json' && f.data is List) {
              rulesJson = f.data as List<dynamic>;
              break;
            }
          }
        }
        if (rulesJson == null) {
          // Last-ditch: text fields containing a serialised array of rules
          for (final f in regGroup.fields) {
            if (f.type != 'text') continue;
            final txt = (f.data as String).trim();
            if (!txt.startsWith('[') || !txt.contains('"findRegex"')) continue;
            try {
              final decoded = jsonDecode(txt);
              if (decoded is List) {
                rulesJson = decoded;
                break;
              }
            } catch (_) {}
          }
        }
        if (rulesJson == null) continue;

        for (final rule in rulesJson) {
          if (rule is! Map<String, dynamic>) continue;
          final identifier = rule['identifier']?.toString();
          final ruleName = rule['name']?.toString();
          if (identifier == null ||
              identifier.isEmpty ||
              ruleName == null ||
              ruleName.isEmpty) {
            continue;
          }
          final id = 'tavo_$identifier';
          if (seenIds.contains(id)) continue;
          seenIds.add(id);

          final trimList = rule['trimStrings'];
          final trimOut = trimList is List ? trimList.join('\n') : '';
          final finalName =
              groupName.isNotEmpty ? '[$groupName] $ruleName' : ruleName;

          final raw = <String, dynamic>{
            'id': id,
            'name': finalName,
            'regex': (rule['findRegex'] as String?) ?? '',
            'replacement': (rule['replaceString'] as String?) ?? '',
            'trimOut': trimOut,
            'placement': <int>[1, 2],
            'ephemerality': <int>[1, 2],
            'disabled': rule['enabled'] == false,
            'markdownOnly': false,
            'runOnEdit': false,
            'macroRules': rule['substitution'] == 'none' ? '0' : '1',
            'minDepth': rule['minDepth'],
            'maxDepth': rule['maxDepth'],
          };
          imported.add(normalizeJsGlobalRegex(raw));
          result.regexes++;
        }
      } catch (e) {
        result.errors.add('Tavo Regex: $e');
      }
    }

    if (imported.isNotEmpty) {
      await prefs.setString('gz_global_regex_scripts', jsonEncode(imported));
    }
  }

  Future<void> _importLorebooks(
      TavoData data, TavoImportResult result) async {
    final lorebooks = data.categories['lorebook'];
    if (lorebooks == null || lorebooks.isEmpty) return;

    for (final lb in lorebooks) {
      _cancel.check();
      try {
        final s = lb.structured;
        String lbName = (s['name'] as String?) ?? '';

        // entries_json isn't in our parsed structured fields — fall back to json fields
        List<dynamic>? entriesJson;
        for (final f in lb.fields) {
          if (f.type == 'json' && f.data is List) {
            entriesJson = f.data as List<dynamic>;
            break;
          }
        }
        if (entriesJson == null) continue;

        if (lbName.isEmpty) {
          final texts = lb.fields
              .where((f) => f.type == 'text')
              .map((f) => f.data as String)
              .toList();
          if (texts.isNotEmpty) lbName = texts.last;
        }

        final entries = <LorebookEntry>[];
        for (final raw in entriesJson) {
          if (raw is! Map<String, dynamic>) continue;
          final e = raw;
          final keys = (e['keywords'] is List)
              ? (e['keywords'] as List).map((k) => k.toString()).toList()
              : <String>[];
          final secondary = (e['secondaryKeywords'] is List)
              ? (e['secondaryKeywords'] as List).map((k) => k.toString()).toList()
              : <String>[];

          entries.add(LorebookEntry(
            id: 'tavo_${e['identifier'] ?? _uniqueId()}',
            keys: keys,
            secondaryKeys: secondary,
            content: (e['content'] as String?) ?? '',
            comment: (e['name'] as String?) ?? '',
            enabled: e['enabled'] != false,
            constant: e['strategy'] == 'constant',
            selectiveLogic: 0,
            order: 100,
            probability: (e['probability'] is num)
                ? (e['probability'] as num).toInt()
                : 100,
            scanDepth: (e['scanDepth'] is num)
                ? (e['scanDepth'] as num).toInt()
                : 2,
            caseSensitive: e['caseSensitive'] as bool? ?? false,
            matchWholeWords: e['matchWholeWord'] as bool? ?? false,
            sticky: (e['sticky'] is num) ? (e['sticky'] as num).toInt() : 0,
            cooldown: (e['cooldown'] is num) ? (e['cooldown'] as num).toInt() : 0,
            delay: (e['delay'] is num) ? (e['delay'] as num).toInt() : 0,
            group: (e['groupName'] as String?) ?? '',
            preventRecursion: e['preventRecursion'] as bool? ?? false,
          ));
        }

        await _lorebookRepo.put(Lorebook(
          id: 'tavo_lb_${lb.entityId}',
          name: lbName.isNotEmpty ? lbName : 'Tavo Lorebook',
          enabled: true,
          activationScope: 'global',
          entries: entries,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
        result.lorebooks++;
      } catch (e) {
        result.errors.add('Tavo Lorebook: $e');
      }
    }
  }

  Future<void> _importPresets(
      TavoData data, TavoImportResult result) async {
    final presets = data.categories['preset'];
    if (presets == null || presets.isEmpty) return;

    for (final pre in presets) {
      _cancel.check();
      try {
        final s = pre.structured;
        String name = (s['name'] as String?) ?? 'Tavo Preset';
        List<dynamic>? promptsJson;
        final promptsStr = s['prompts_json'] as String?;
        if (promptsStr != null) {
          try {
            final decoded = jsonDecode(promptsStr);
            if (decoded is List) promptsJson = decoded;
          } catch (_) {}
        }

        if (promptsJson == null) {
          for (final f in pre.fields) {
            if (f.type == 'json' && f.data is List) {
              final list = f.data as List;
              if (list.isNotEmpty &&
                  list.first is Map &&
                  (list.first as Map).containsKey('identifier')) {
                promptsJson = list;
                break;
              }
            } else if (f.type == 'text') {
              final txt = f.data as String;
              if (txt.length < 50 && !txt.contains('{')) {
                name = txt;
              }
            }
          }
        }

        if (promptsJson == null) continue;

        final preset = parseSillyTavernPreset(
          {'name': name, 'prompts': promptsJson},
          name,
        );
        await _presetRepo.put(preset);
        result.presets++;
      } catch (e) {
        result.errors.add('Tavo Preset: $e');
      }
    }
  }

  Future<void> _importCharacters(
    TavoData data,
    Archive zip,
    Map<int, String> charEntityIdToGlazeId,
    TavoImportResult result,
  ) async {
    final chars = data.categories['character'];
    if (chars == null || chars.isEmpty) return;

    for (final ch in chars) {
      _cancel.check();
      try {
        final s = ch.structured;

        // Prefer v2/v3 chara_card block from JSON fields
        Map<String, dynamic>? v2Data;
        for (final f in ch.fields) {
          if (f.type != 'json') continue;
          final raw = f.data;
          if (raw is Map<String, dynamic>) {
            final spec = raw['spec'];
            if (spec == 'chara_card_v2' || spec == 'chara_card_v3') {
              final d = raw['data'];
              if (d is Map<String, dynamic>) v2Data = d;
              break;
            }
          }
        }

        Uint8List? avatarBytes;
        final avatarPath = s['avatarPath'] as String?;
        if (avatarPath != null && avatarPath.isNotEmpty) {
          avatarBytes = await _readAvatarFromZip(zip, avatarPath);
        }

        // Build a v2 JSON wrapper and run it through CharacterImporter
        final cardData = <String, dynamic>{};
        if (v2Data != null) {
          cardData.addAll(v2Data);
        } else if ((s['name'] as String?)?.isNotEmpty == true) {
          cardData['name'] = s['name'];
          if (s['description'] != null) cardData['description'] = s['description'];
          if (s['first_mes'] != null) cardData['first_mes'] = s['first_mes'];
          if (s['scenario'] != null) cardData['scenario'] = s['scenario'];
          if (s['personality'] != null) cardData['personality'] = s['personality'];
          if (s['mes_example'] != null) cardData['mes_example'] = s['mes_example'];
          if (s['system_prompt'] != null) cardData['system_prompt'] = s['system_prompt'];
          final altGreet = s['alternate_greetings'];
          if (altGreet is String) {
            try {
              final parsed = jsonDecode(altGreet);
              if (parsed is List) cardData['alternate_greetings'] = parsed;
            } catch (_) {}
          }
          final srcStr = s['source'] as String?;
          if (srcStr != null) {
            try {
              final src = jsonDecode(srcStr);
              if (src is Map && src['fav'] == true) cardData['fav'] = true;
            } catch (_) {}
          }
        } else {
          // No structured + no v2 — best-effort heuristic from extracted strings
          final strings = ch.fields
              .where((f) => f.type == 'text' &&
                  (f.data as String).trim().isNotEmpty)
              .map((f) => f.data as String)
              .toList();
          if (strings.length < 2) continue;

          final avatarStr = strings.firstWhere(
            (st) => st.startsWith('charaCard/'),
            orElse: () => '',
          );
          if (avatarStr.isNotEmpty) {
            avatarBytes ??= await _readAvatarFromZip(zip, avatarStr);
          }
          final rem = strings.where((st) => st != avatarStr).toList();
          cardData['name'] = rem.isNotEmpty ? rem.removeLast() : 'Unknown';
          final sortedByLen = [...rem]
            ..sort((a, b) => b.length.compareTo(a.length));
          cardData['description'] =
              sortedByLen.isNotEmpty ? sortedByLen[0] : '';
          cardData['first_mes'] =
              sortedByLen.length > 1 ? sortedByLen[1] : '';
        }

        if ((cardData['name'] as String?)?.isEmpty ?? true) {
          cardData['name'] = 'Unknown';
        }

        if (avatarBytes != null) {
          cardData['avatar'] =
              'data:image/png;base64,${base64Encode(avatarBytes)}';
        }

        final wrapped = {'spec': 'chara_card_v2', 'data': cardData};
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(wrapped)));
        final imported = await _charImporter.importFromBytes(bytes, 'card.json');
        await _charRepo.put(imported.character);
        charEntityIdToGlazeId[ch.entityId] = imported.character.id;
        result.characters++;
      } catch (e) {
        result.errors.add('Tavo Character: $e');
      }
    }
  }

  Future<void> _importChats(
    TavoData data,
    Map<int, String> charEntityIdToGlazeId,
    TavoImportResult result,
  ) async {
    if (data.chats.isEmpty) return;
    final nextIdxByChar = <String, int>{};

    for (final chatBlock in data.chats) {
      _cancel.check();
      try {
        final msgs = chatBlock.messages
            .where((m) => (m.structured['text'] as String?) != null)
            .toList();
        if (msgs.isEmpty) continue;

        final charEntityId = chatBlock.characterId;
        if (charEntityId == null) continue;
        final glazeCharId = charEntityIdToGlazeId[charEntityId];
        if (glazeCharId == null) continue;

        final messages = <ChatMessage>[];
        for (var i = 0; i < msgs.length; i++) {
          final tm = msgs[i];
          final st = tm.structured;
          final text = (st['text'] as String?) ?? '';
          final isUser = (st['characterId'] as int?) == 0;
          final ts = tm.timestamp ?? DateTime.now().millisecondsSinceEpoch;

          messages.add(ChatMessage(
            id: 'tavo_${tm.entityId}_$i',
            role: isUser ? 'user' : 'assistant',
            content: text,
            timestamp: ts,
          ));
        }
        if (messages.isEmpty) continue;

        final idx = (nextIdxByChar[glazeCharId] ?? 0) + 1;
        nextIdxByChar[glazeCharId] = idx;

        await _chatRepo.put(ChatSession(
          id: '${glazeCharId}_$idx',
          characterId: glazeCharId,
          sessionIndex: idx,
          messages: messages,
          updatedAt: currentTimestampSeconds(),
        ));
        result.chats++;
      } catch (e) {
        result.errors.add('Tavo Chat: $e');
      }
    }

    // Sync currentSessionIndex on each affected character
    for (final entry in nextIdxByChar.entries) {
      final character = await _charRepo.getById(entry.key);
      if (character != null) {
        await _charRepo.put(
            character.copyWith(currentSessionIndex: entry.value));
      }
    }
  }

  String _uniqueId() =>
      '${generateId()}_${(DateTime.now().microsecondsSinceEpoch % 1000000).toRadixString(36)}';
}
