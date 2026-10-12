import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../db/app_db.dart';
import '../../db/repositories/api_config_repo.dart';
import '../../db/repositories/character_repo.dart';
import '../../db/repositories/chat_repo.dart';
import '../../db/repositories/lorebook_repo.dart';
import '../../db/repositories/persona_repo.dart';
import '../../db/repositories/preset_repo.dart';
import '../../db/repositories/summary_repo.dart';
import '../../import/silly_tavern_preset_parser.dart';
import '../../llm/transport/llm_protocol.dart';
import '../../models/api_config.dart';
import '../../models/character.dart';
import '../../models/chat_message.dart';
import '../../models/extra_request_parameter.dart';
import '../../models/lorebook.dart';
import '../../models/persona.dart';
import '../../state/global_regex_provider.dart';
import '../../utils/cast_helpers.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import '../image_storage_service.dart';
import 'backup_cancel.dart';
import 'tavo_lmdb_reader.dart';

/// Something a Tavo backup holds that the import leaves behind, shown before
/// the restore so nothing is lost by surprise.
enum TavoSkippedKind {
  /// Conversations with more than one character; Glaze has no group chats.
  groupChats,

  /// Endpoints with custom HTTP headers; Glaze connections have no headers.
  endpointHeaders,

  /// The alternatives of regenerated replies. Tavo keeps them in a second
  /// database that only its "Full backup" option writes, so a standard
  /// backup comes over with the chosen reply only.
  rerollsNeedFullBackup,

  /// Chats with their own scenario.
  chatScenarios,

  /// Chats pinned to a specific endpoint, image endpoint or chat theme.
  chatOverrides,

  /// Messages with attached files.
  attachments,

  /// Messages with a stored translation.
  translations,

  /// Chat and global variables.
  variables,

  /// Chat themes the user made or imported (Tavo's built-in ones are not
  /// counted).
  chatThemes,

  /// Plugins beyond the ones Tavo ships.
  plugins,

  /// Voice, image, speech-recognition and web-search endpoints.
  otherEndpoints,
}

class TavoSkipped {
  final TavoSkippedKind kind;

  /// How many objects are affected; 0 when the backup cannot tell.
  final int count;

  /// Names of the affected objects, when they have names worth showing.
  final List<String> names;

  const TavoSkipped(this.kind, {this.count = 0, this.names = const []});
}

/// What a Tavo backup is and what of it will not come over, read before the
/// restore clears anything.
class TavoBackupInspection {
  final TavoBackupInfo info;
  final List<TavoSkipped> skipped;

  const TavoBackupInspection({required this.info, required this.skipped});

  factory TavoBackupInspection.fromArchive(Archive zip) {
    final info = TavoBackupInfo.fromArchive(zip);
    final mdb = zip.findFile('objectbox/data.mdb')?.readBytes();
    if (mdb == null) return TavoBackupInspection(info: info, skipped: const []);
    final db = parseTavoObjectBox(mdb);
    final hasAux = zip.findFile('objectbox_aux/data.mdb') != null;
    return TavoBackupInspection(info: info, skipped: _skipped(db, hasAux));
  }

  static List<TavoSkipped> _skipped(TavoDatabase db, bool hasAux) {
    final out = <TavoSkipped>[];
    void add(TavoSkippedKind kind, {int count = 0, List<String>? names}) {
      if (count > 0 || (names?.isNotEmpty ?? false)) {
        out.add(TavoSkipped(kind, count: count, names: names ?? const []));
      }
    }

    String name(Map<String, dynamic> row) =>
        row['name'] is String ? row['name'] as String : '';
    bool nonEmpty(Object? v) {
      if (v is String) {
        final t = v.trim();
        return t.isNotEmpty && t != '[]' && t != '{}' && t != 'null';
      }
      if (v is Map) return v.isNotEmpty;
      if (v is List) return v.isNotEmpty;
      return false;
    }

    int intOf(Object? v) => v is num ? v.toInt() : 0;

    // Group chats are skipped whole, so nothing below counts them again.
    final groupIds = <int>{};
    for (final conv in db.rows('Conversation')) {
      final id = intOf(conv['id']);
      if (db.related('Conversation.characters', id).length > 1) {
        groupIds.add(id);
      }
    }
    final chats = [
      for (final c in db.rows('Conversation'))
        if (!groupIds.contains(intOf(c['id']))) c,
    ];
    final messages = [
      for (final m in db.rows('Message'))
        if (!groupIds.contains(intOf(m['conversationId']))) m,
    ];

    add(TavoSkippedKind.groupChats, count: groupIds.length);
    add(
      TavoSkippedKind.endpointHeaders,
      names: [
        for (final e in db.rows('Endpoint'))
          if (nonEmpty(e['overrideHeaders'])) name(e),
      ],
    );
    if (!hasAux && messages.any((m) => intOf(m['characterId']) != 0)) {
      out.add(const TavoSkipped(TavoSkippedKind.rerollsNeedFullBackup));
    }
    add(
      TavoSkippedKind.chatScenarios,
      count: chats.where((c) => nonEmpty(c['overrideScenario'])).length,
    );
    add(
      TavoSkippedKind.chatOverrides,
      count: chats
          .where(
            (c) =>
                intOf(c['overrideEndpointId']) != 0 ||
                intOf(c['overrideImageEndpointId']) != 0 ||
                intOf(c['overrideChatThemeId']) != 0,
          )
          .length,
    );
    add(
      TavoSkippedKind.attachments,
      count: messages.where((m) => nonEmpty(m['dbAttachments'])).length,
    );
    add(
      TavoSkippedKind.translations,
      count: messages.where((m) => nonEmpty(m['dbTranslation'])).length,
    );
    add(
      TavoSkippedKind.variables,
      count:
          [
            for (final c in db.rows('ConversationState'))
              if (!groupIds.contains(intOf(c['conversationId']))) c,
            ...db.rows('GlobalState'),
          ].where((r) => nonEmpty(r['dbVariables'])).length +
          messages.where((m) => nonEmpty(m['dbVariables'])).length,
    );
    add(
      TavoSkippedKind.chatThemes,
      names: [
        for (final t in db.rows('ChatTheme'))
          if (t['isOfficial'] != true) name(t),
      ],
    );
    add(
      TavoSkippedKind.plugins,
      names: [
        for (final p in db.rows('InstalledPlugin'))
          if (p['pluginId'] is String &&
              !(p['pluginId'] as String).startsWith('dev.tavoai.'))
            p['pluginId'] as String,
      ],
    );
    add(
      TavoSkippedKind.otherEndpoints,
      names: [
        for (final entity in const [
          'TtsEndpoint',
          'ImageEndpoint',
          'AsrEndpoint',
          'WebSearchEndpoint',
        ])
          for (final e in db.rows(entity)) name(e),
      ],
    );
    return out;
  }
}

class TavoImportResult {
  /// The backup's own version stamp; see [TavoBackupInfo.isTested].
  TavoBackupInfo info = const TavoBackupInfo();
  int characters = 0;
  int lorebooks = 0;
  int presets = 0;
  int chats = 0;
  int personas = 0;
  int apis = 0;
  int regexes = 0;
  int summaries = 0;

  /// Conversations with more than one character. Glaze has no group chats,
  /// so these are left out.
  int skippedGroupChats = 0;
  final List<String> errors = [];
}

/// What a Tavo backup says about itself in `backup_info.txt`.
class TavoBackupInfo {
  /// Tavo version and ObjectBox database format this importer was written
  /// against and tested on. A backup from anything else may carry fields or
  /// JSON shapes the importer does not know, and lose them silently.
  static const testedAppVersion = '1.6.2';
  static const testedDatabaseFormat = 2;

  /// Null when the backup does not say.
  final String? appVersion;
  final int? databaseFormat;

  const TavoBackupInfo({this.appVersion, this.databaseFormat});

  /// Reads `backup_info.txt` — `key: value` lines — from [zip]. A missing or
  /// unreadable file yields an info with both values unknown.
  factory TavoBackupInfo.fromArchive(Archive zip) {
    final file = zip.findFile('backup_info.txt');
    final bytes = file?.readBytes();
    if (bytes == null) return const TavoBackupInfo();
    final values = <String, String>{};
    for (final line in utf8.decode(bytes, allowMalformed: true).split('\n')) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      values[line.substring(0, colon).trim()] = line
          .substring(colon + 1)
          .trim();
    }
    final version = values['app_version'];
    return TavoBackupInfo(
      appVersion: version == null || version.isEmpty ? null : version,
      databaseFormat: int.tryParse(values['database_format'] ?? ''),
    );
  }

  /// Whether the backup comes from the Tavo version the importer was tested
  /// on. Anything else, an unknown version included, gets a warning before
  /// the import.
  bool get isTested =>
      appVersion == testedAppVersion && databaseFormat == testedDatabaseFormat;
}

/// Imports a Tavo backup (`.tbk`): a ZIP holding the app's ObjectBox database
/// (`objectbox/data.mdb`), the avatars it references (`CharacterCards/…`),
/// themes, plugins and a dump of the app's shared preferences.
///
/// Everything is read from the database; see [parseTavoObjectBox]. Tavo keeps
/// lorebooks, presets and regex rules as JSON in `db*` string properties, in
/// its own format rather than SillyTavern's, so each is mapped here field by
/// field.
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
  late final SummaryRepo _summaryRepo;

  TavoBackupImporter(this._db, this._imageStorage, [this._cancel = noCancel]) {
    _charRepo = CharacterRepo(_db);
    _personaRepo = PersonaRepo(_db);
    _lorebookRepo = LorebookRepo(_db);
    _presetRepo = PresetRepo(_db);
    _apiRepo = ApiConfigRepo(_db);
    _chatRepo = ChatRepo(_db);
    _summaryRepo = SummaryRepo(_db);
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
    final result = TavoImportResult()..info = TavoBackupInfo.fromArchive(zip);

    // Parsed before anything is cleared, so a broken file leaves the current
    // data alone.
    onProgress?.call('backup_progress_reading'.tr());
    final mdbFile =
        zip.findFile('objectbox/data.mdb') ??
        zip.files.firstWhere(
          (f) => f.isFile && f.name.toLowerCase().endsWith('data.mdb'),
          orElse: () => throw const FormatException(
            'No data.mdb found in Tavo backup zip.',
          ),
        );
    final tavo = parseTavoObjectBox(mdbFile.readBytes()!);
    mdbFile.clear();
    // Tavo keeps the alternatives of a regenerated reply in a second store,
    // which only the "Full backup" option writes into the archive.
    final auxFile = zip.findFile('objectbox_aux/data.mdb');
    final aux = auxFile == null
        ? null
        : parseTavoObjectBox(auxFile.readBytes()!);
    auxFile?.clear();
    _cancel.check();

    onProgress?.call('backup_progress_clearing'.tr());
    await _clearAllTables();
    _cancel.check();

    final s = _ImportState(tavo, zip, aux);

    onProgress?.call('backup_progress_personas'.tr());
    await _importPersonas(s, result);
    _cancel.check();

    onProgress?.call('backup_progress_apis'.tr());
    await _importEndpoints(s, result);
    _cancel.check();

    onProgress?.call('backup_progress_regex'.tr());
    await _importRegexes(s, result);
    _cancel.check();

    onProgress?.call('backup_progress_characters'.tr());
    await _importCharacters(s, result);
    _cancel.check();

    onProgress?.call('backup_progress_lorebooks'.tr());
    await _importLorebooks(s, result);
    _cancel.check();

    onProgress?.call('backup_progress_presets'.tr());
    await _importPresets(s, result);
    _cancel.check();

    onProgress?.call('backup_progress_chats'.tr());
    await _importChats(s, result);
    _cancel.check();

    onProgress?.call('backup_progress_finalizing'.tr());
    await _writeSelections(s);
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

  // ── Personas ──────────────────────────────────────────────────────────────

  Future<void> _importPersonas(_ImportState s, TavoImportResult result) async {
    for (final row in _sorted(s.tavo.rows('Persona'))) {
      _cancel.check();
      try {
        final id = _uniqueId();
        final avatarBytes = s.file(_str(row['avatar']));
        await _personaRepo.put(
          Persona(
            id: id,
            name: _str(row['name']).isNotEmpty ? _str(row['name']) : 'User',
            prompt: _str(row['description']),
            avatarPath: avatarBytes == null
                ? null
                : await _imageStorage.saveAvatar(id, avatarBytes),
            createdAt: _seconds(row['updateAt']),
          ),
        );
        s.personaIds[_id(row)] = id;
        if (row['active'] == true) s.activePersonaId = id;
        result.personas++;
      } catch (e) {
        result.errors.add('Tavo Persona ${row['name']}: $e');
      }
    }
  }

  // ── API endpoints ─────────────────────────────────────────────────────────

  /// Tavo keeps sampling in two places: the global Model settings
  /// (`ModelSetting`, one row) and per-endpoint overrides (`dbModelParams`,
  /// keyed by request field). The override wins, as it does in Tavo. A value
  /// Tavo leaves unset ("None") is not sent, which Glaze expresses with the
  /// matching `omit*` switch.
  Future<void> _importEndpoints(_ImportState s, TavoImportResult result) async {
    final rows = s.tavo.rows('ModelSetting');
    final global = rows.isEmpty ? const <String, dynamic>{} : rows.first;

    double? globalDouble(String key, String disableKey) =>
        global[disableKey] == true ? null : _double(global[key]);

    for (final row in _sorted(s.tavo.rows('Endpoint'))) {
      _cancel.check();
      try {
        final params = Map<String, dynamic>.from(
          _jsonMap(row['dbModelParams']),
        );
        double? take(String key, double? fallback) {
          final v = params.remove(key);
          return v is num ? v.toDouble() : fallback;
        }

        final temperature = take(
          'temperature',
          globalDouble('temperature', 'disableTemperature'),
        );
        final topP = take('top_p', globalDouble('topP', 'disableTopP'));
        final topK = take(
          'top_k',
          global['disableTopK'] == true ? null : _double(global['topK']),
        );
        final frequencyPenalty = take(
          'frequency_penalty',
          _double(global['frequencyPenalty']),
        );
        final presencePenalty = take(
          'presence_penalty',
          _double(global['presencePenalty']),
        );
        final maxTokens =
            take('max_tokens', null) ??
            take('max_completion_tokens', null) ??
            _double(global['maxCompletionTokens']);
        final reasoningEffort = params.remove('reasoning_effort');

        // Everything Glaze has no field for still reaches the request: the
        // leftover model params, Tavo's stop list and its custom body.
        final extra = <ExtraRequestParameter>[
          for (final e in params.entries)
            ExtraRequestParameter(key: e.key, value: jsonEncode(e.value)),
          if (global['stop'] is List && (global['stop'] as List).isNotEmpty)
            ExtraRequestParameter(
              key: 'stop',
              value: jsonEncode(global['stop']),
            ),
          for (final e in _jsonMap(row['dbOverrideBody']).entries)
            ExtraRequestParameter(key: e.key, value: jsonEncode(e.value)),
        ];

        final headers = row['overrideHeaders'];
        if (headers is Map && headers.isNotEmpty) {
          result.errors.add(
            'Tavo API ${row['name']}: custom headers are not supported and '
            'were skipped (${headers.keys.join(', ')}).',
          );
        }

        final platform = _str(row['platform']);
        final protocol = _protocolFor(platform);
        final url = _str(row['apiUrl']).isNotEmpty
            ? _str(row['apiUrl'])
            : (_defaultUrls[platform] ?? '');
        final id = 'tavo_${_uniqueId()}';
        final name = _str(row['name']);
        await _apiRepo.put(
          ApiConfig(
            id: id,
            name: name.isNotEmpty ? name : (url.isNotEmpty ? url : 'Tavo API'),
            providerId: protocol == LlmProtocol.customChatCompletion
                ? 'custom_chat_completion'
                : protocol,
            protocol: protocol,
            endpoint: url,
            apiKey: _str(row['secret']),
            model: _str(row['model']),
            maxTokens: maxTokens?.toInt() ?? 1500,
            temperature: temperature ?? 1.0,
            topP: topP ?? 1.0,
            topK: topK?.toInt() ?? 0,
            frequencyPenalty: frequencyPenalty ?? 0.0,
            presencePenalty: presencePenalty ?? 0.0,
            omitTemperature: temperature == null,
            omitTopP: topP == null,
            omitTopK: topK == null,
            omitFrequencyPenalty: frequencyPenalty == null,
            omitPresencePenalty: presencePenalty == null,
            reasoningEffort: reasoningEffort is String
                ? reasoningEffort
                : 'medium',
            stream: global['stream'] as bool? ?? true,
            extraRequestParameters: extra,
          ),
        );
        s.endpointIds[_id(row)] = id;
        if (row['active'] == true) s.activeApiId = id;
        result.apis++;
      } catch (e) {
        result.errors.add('Tavo API ${row['name']}: $e');
      }
    }
  }

  static String _protocolFor(String platform) => switch (platform) {
    'openai' => LlmProtocol.openai,
    'claude' ||
    'claude_protocol' ||
    'anthropic_protocol' => LlmProtocol.anthropic,
    'gemini' || 'gemini_protocol' => LlmProtocol.gemini,
    'openrouter' => LlmProtocol.openrouter,
    _ => LlmProtocol.customChatCompletion,
  };

  /// Tavo leaves `apiUrl` empty for its built-in platforms.
  static const _defaultUrls = <String, String>{
    'openai': 'https://api.openai.com/v1',
    'claude': 'https://api.anthropic.com/v1',
    'gemini': 'https://generativelanguage.googleapis.com',
    'openrouter': 'https://openrouter.ai/api/v1',
    'deepseek': 'https://api.deepseek.com/v1',
    'moonshot': 'https://api.moonshot.ai/v1',
  };

  // ── Regex ─────────────────────────────────────────────────────────────────

  /// Tavo attaches regex groups to chats; Glaze's scripts are global. A rule
  /// keeps its own switch, and a group no chat used comes in switched off, so
  /// it still changes nothing.
  Future<void> _importRegexes(_ImportState s, TavoImportResult result) async {
    final usedGroups = <int>{};
    for (final ref in s.tavo.rows('RegexConversationRef')) {
      usedGroups.addAll(
        s.tavo.related('RegexConversationRef.regexes', _id(ref)),
      );
      final direct = _int(ref['regexId']);
      if (direct != null && direct != 0) usedGroups.add(direct);
    }

    final imported = <Map<String, dynamic>>[];
    for (final group in _sorted(s.tavo.rows('Regex'))) {
      _cancel.check();
      final groupName = _str(group['name']);
      final groupUsed = usedGroups.contains(_id(group));
      for (final rule in _jsonList(group['dbEntries'])) {
        if (rule is! Map) continue;
        try {
          final name = _str(rule['name']);
          final timing = _str(rule['timing']);
          final raw = <String, dynamic>{
            'id': 'tavo_${rule['identifier'] ?? _uniqueId()}',
            'name': groupName.isNotEmpty ? '[$groupName] $name' : name,
            'regex': _str(rule['findRegex']),
            'replacement': _str(rule['replaceString']),
            'trimStrings': rule['trimStrings'] is List
                ? rule['trimStrings']
                : const <String>[],
            'placement': [
              for (final p in (rule['placements'] as List? ?? const []))
                ?_regexPlacements[p],
            ],
            'ephemerality': [1, 2],
            'disabled': rule['enabled'] == false || !groupUsed,
            'markdownOnly': timing == 'display' || timing == 'sendAndDisplay',
            'promptOnly': timing == 'send' || timing == 'sendAndDisplay',
            'runOnEdit': timing == 'editAndReceive',
            'substituteRegex': switch (_str(rule['substitution'])) {
              'raw' => 1,
              'escaped' => 2,
              _ => 0,
            },
            'minDepth': rule['minDepth'],
            'maxDepth': rule['maxDepth'],
          };
          imported.add(normalizeJsGlobalRegex(raw));
          result.regexes++;
        } catch (e) {
          result.errors.add('Tavo Regex $groupName: $e');
        }
      }
    }

    final prefs = await SharedPreferences.getInstance();
    if (imported.isEmpty) {
      await prefs.remove('gz_global_regex_scripts');
    } else {
      await prefs.setString('gz_global_regex_scripts', jsonEncode(imported));
    }
  }

  static const _regexPlacements = <String, int>{
    'user': 1,
    'char': 2,
    'lorebook': 5,
    'reasoning': 6,
  };

  // ── Characters ────────────────────────────────────────────────────────────

  Future<void> _importCharacters(
    _ImportState s,
    TavoImportResult result,
  ) async {
    for (final row in _sorted(s.tavo.rows('Character'))) {
      _cancel.check();
      try {
        final id = _uniqueId();
        final ext = Map<String, dynamic>.from(_jsonMap(row['dbExtensions']));
        // CCv3 fields Glaze has no column for travel in the extensions, which
        // a card export writes back out.
        final groupGreetings = _strings(row['groupOnlyGreetings']);
        if (groupGreetings.isNotEmpty) {
          ext['group_only_greetings'] = groupGreetings;
        }
        final multilingual = _jsonMap(row['dbCreatorNotesMultilingual']);
        if (multilingual.isNotEmpty) {
          ext['creator_notes_multilingual'] = multilingual;
        }
        final card = <String, dynamic>{'extensions': ext};
        final depthPrompt = ext['depth_prompt'] is Map
            ? ext['depth_prompt'] as Map
            : null;
        final avatarBytes = s.file(_str(row['avatar']));
        final nickname = _str(row['nickname']);
        final version = _str(row['characterVersion']);
        final world = ext['world'];

        final character = Character(
          id: id,
          name: _str(row['name']).isNotEmpty ? _str(row['name']) : 'Unknown',
          avatarPath: avatarBytes == null
              ? null
              : await _imageStorage.saveAvatar(id, avatarBytes),
          description: _str(row['description']),
          personality: _str(row['personality']),
          scenario: _str(row['scenario']),
          firstMes: _str(row['firstMes']),
          mesExample: _str(row['mesExample']),
          systemPrompt: _str(row['systemPrompt']),
          postHistoryInstructions: _str(row['postHistoryInstructions']),
          creator: _str(row['creator']),
          creatorNotes: _str(row['creatorNotes']),
          tags: _strings(row['tags']),
          alternateGreetings: _strings(row['alternateGreetings']),
          createdAt: _seconds(row['creationDate']),
          updatedAt: _seconds(row['updateAt']),
          fav: ext['fav'] == true,
          extensions: extractExtensionsJson(card),
          characterVersion: version.isNotEmpty ? version : '1',
          depthPrompt: _str(depthPrompt?['prompt']),
          depthPromptDepth: _int(depthPrompt?['depth']) ?? 4,
          depthPromptRole: depthPrompt?['role'] is String
              ? depthPrompt!['role'] as String
              : 'system',
          world: world is String && world.isNotEmpty ? world : null,
          macroName: nickname.isNotEmpty ? nickname : null,
        );
        await _charRepo.put(character);
        s.characters[_id(row)] = character;
        result.characters++;
      } catch (e) {
        result.errors.add('Tavo Character ${row['name']}: $e');
      }
    }
  }

  // ── Lorebooks ─────────────────────────────────────────────────────────────

  /// Tavo has no per-character lorebook link: a card's embedded book becomes
  /// a standalone lorebook named `<character>'s Lorebook (<book>)`, and books
  /// are attached to chats. The chat links come over as chat activations
  /// (see [_importChats]); a book that came from a card is also scoped to that
  /// character, so new chats with it pick the book up as they did in Tavo.
  Future<void> _importLorebooks(_ImportState s, TavoImportResult result) async {
    for (final row in _sorted(s.tavo.rows('Lorebook'))) {
      _cancel.check();
      try {
        final name = _str(row['name']);
        final owner = _ownerOf(name, s.characters.values);
        final entries = <LorebookEntry>[];
        final rawEntries = _jsonList(row['dbEntries']);
        for (var i = 0; i < rawEntries.length; i++) {
          final e = rawEntries[i];
          if (e is Map) entries.add(_lorebookEntry(e, _id(row), i));
        }
        final id = 'tavo_lb_${_id(row)}_${_uniqueId()}';
        await _lorebookRepo.put(
          Lorebook(
            id: id,
            name: name.isNotEmpty ? name : 'Tavo Lorebook',
            // A global switch would turn the book on in every chat; Tavo
            // books only apply where they are attached.
            enabled: false,
            activationScope: owner == null ? 'global' : 'character',
            activationTargetId: owner?.id,
            entries: entries,
            updatedAt: _seconds(row['updateAt']),
          ),
        );
        s.lorebookIds[_id(row)] = id;
        // Tavo renames a card's book to `<character>'s Lorebook (<book>)`;
        // the card's link has to name the book as it exists here, or the
        // editor shows a lorebook that is not in the list.
        if (owner != null && name.isNotEmpty && owner.world != name) {
          final linked = owner.copyWith(world: name);
          await _charRepo.put(linked);
          s.characters.updateAll((_, c) => c.id == owner.id ? linked : c);
        }
        result.lorebooks++;
      } catch (e) {
        result.errors.add('Tavo Lorebook ${row['name']}: $e');
      }
    }
  }

  /// The character whose card produced a book, from the name Tavo gives it.
  static Character? _ownerOf(String bookName, Iterable<Character> characters) {
    for (final c in characters) {
      final world = c.world;
      if (world != null &&
          (bookName == world || bookName.endsWith('($world)'))) {
        return c;
      }
    }
    for (final c in characters) {
      if (bookName.startsWith("${c.name}'s Lorebook")) return c;
    }
    return null;
  }

  static LorebookEntry _lorebookEntry(
    Map<dynamic, dynamic> e,
    int lorebookId,
    int index,
  ) {
    final strategy = _str(e['strategy']);
    final secondary = _strings(e['secondaryKeywords']);
    return LorebookEntry(
      id: 'tavo_${lorebookId}_${e['identifier'] ?? index}',
      comment: _str(e['name']),
      enabled: e['enabled'] != false,
      constant: strategy == 'constant',
      vectorSearch: strategy == 'vectorized',
      useKeywordSearch: strategy != 'vectorized',
      keys: _strings(e['keywords']),
      secondaryKeys: secondary,
      selectiveLogic: secondary.isEmpty
          ? 4
          : switch (_str(e['secondaryKeywordStrategy'])) {
              'andAny' => 0,
              'andAll' => 1,
              'notAny' => 2,
              'notAll' => 3,
              _ => 4,
            },
      content: _str(e['content']),
      position: switch (_str(e['injectionPosition'])) {
        'lorebookBefore' => 'worldInfoBefore',
        'lorebookAfter' => 'worldInfoAfter',
        _ => 'matchGlobal',
      },
      // Tavo has no order field; the list order is the insertion order.
      order: (index + 1) * 10,
      scanDepth: _int(e['scanDepth']),
      caseSensitive: e['caseSensitive'] as bool?,
      matchWholeWords: e['matchWholeWord'] as bool?,
      probability: _int(e['probability'])?.clamp(0, 100) ?? 100,
      preventRecursion: e['preventRecursion'] == true,
      sticky: _int(e['sticky']) ?? 0,
      cooldown: _int(e['cooldown']) ?? 0,
      delay: _int(e['delay']) ?? 0,
      group: _str(e['groupName']),
      groupProminence: _int(e['groupWeight']) ?? 100,
      useGroupScoring: e['useGroupScoring'] == true,
      delayUntilRecursion:
          e['delayUntilRecursion'] == true ||
          (e['delayUntilRecursion'] is num &&
              (e['delayUntilRecursion'] as num) > 0),
    );
  }

  // ── Presets ───────────────────────────────────────────────────────────────

  /// A Tavo preset is SillyTavern's prompt manager under other key names, so
  /// it is rewritten into a SillyTavern preset and read by the same parser.
  Future<void> _importPresets(_ImportState s, TavoImportResult result) async {
    for (final row in _sorted(s.tavo.rows('Preset'))) {
      _cancel.check();
      try {
        final name = _str(row['name']).isNotEmpty
            ? _str(row['name'])
            : 'Tavo Preset';
        final prompts = <Map<String, dynamic>>[];
        final order = <Map<String, dynamic>>[];
        for (final e in _jsonList(row['dbEntries'])) {
          if (e is! Map) continue;
          final identifier = _str(e['identifier']);
          if (identifier.isEmpty) continue;
          final type = _str(e['type']);
          prompts.add({
            'identifier': identifier,
            'name': _str(e['name']).isNotEmpty ? _str(e['name']) : identifier,
            'role': _str(e['role']),
            'content': _str(e['content']),
            'system_prompt': type == 'builtin' || type == 'marker',
            'marker': type == 'marker',
            'injection_position': e['injectionPosition'] == 'absolute' ? 1 : 0,
            'injection_depth': _int(e['injectionDepth']) ?? 4,
            'forbid_overrides': e['forbidOverrides'] == true,
          });
          order.add({
            'identifier': identifier,
            'enabled': e['enabled'] != false,
          });
        }
        var preset = parseSillyTavernPreset({
          'name': name,
          'prompts': prompts,
          'prompt_order': [
            {'character_id': 100001, 'order': order},
          ],
        }, name);
        final impersonation = _str(
          _jsonMap(row['dbBasicPrompts'])['impersonation'],
        );
        if (impersonation.isNotEmpty) {
          preset = preset.copyWith(impersonationPrompt: impersonation);
        }
        await _presetRepo.put(preset);
        s.presetIds[_id(row)] = preset.id;
        if (row['active'] == true) s.activePresetId = preset.id;
        result.presets++;
      } catch (e) {
        result.errors.add('Tavo Preset ${row['name']}: $e');
      }
    }
  }

  // ── Chats ─────────────────────────────────────────────────────────────────

  Future<void> _importChats(_ImportState s, TavoImportResult result) async {
    final messagesByConversation = <int, List<Map<String, dynamic>>>{};
    for (final m in s.tavo.rows('Message')) {
      final conv = _int(m['conversationId']) ?? 0;
      (messagesByConversation[conv] ??= []).add(m);
    }
    final variantsByMessage = <int, List<Map<String, dynamic>>>{};
    for (final v in [
      ...s.tavo.rows('MessageVariant'),
      ...?s.aux?.rows('MessageVariant'),
    ]) {
      final floor = _int(v['floorMessageId']) ?? 0;
      (variantsByMessage[floor] ??= []).add(v);
    }
    final ltmByConversation = {
      for (final l in s.tavo.rows('Ltm')) _int(l['conversationId']) ?? 0: l,
    };

    // Sessions are numbered per character in creation order.
    final conversations = [...s.tavo.rows('Conversation')]
      ..sort(
        (a, b) =>
            (_int(a['createAt']) ?? 0).compareTo(_int(b['createAt']) ?? 0),
      );
    final nextIndex = <String, int>{};
    final latest = <String, (int, int)>{};

    for (final conv in conversations) {
      _cancel.check();
      final convId = _id(conv);
      try {
        final messages = [...?messagesByConversation[convId]]
          ..sort((a, b) => _id(a).compareTo(_id(b)));
        final characterIds = s.tavo.related('Conversation.characters', convId);
        if (characterIds.length > 1) {
          result.skippedGroupChats++;
          continue;
        }
        final tavoCharId = characterIds.isNotEmpty
            ? characterIds.first
            : messages
                  .map((m) => _int(m['characterId']) ?? 0)
                  .firstWhere((id) => id != 0, orElse: () => 0);
        final character = s.characters[tavoCharId];
        if (character == null || messages.isEmpty) continue;

        final idx = (nextIndex[character.id] ?? 0) + 1;
        nextIndex[character.id] = idx;
        final sessionId = '${character.id}_$idx';
        final personaId = s.personaIds[_int(conv['personaId'])];

        final greetings = [
          if ((character.firstMes ?? '').isNotEmpty) character.firstMes!,
          ...character.alternateGreetings,
        ];
        final chatMessages = <ChatMessage>[];
        for (final m in messages) {
          final isUser = (_int(m['characterId']) ?? 0) == 0;
          final content = _str(m['content']);
          final variants = [...?variantsByMessage[_id(m)]]
            ..sort(
              (a, b) => (_int(a['position']) ?? 0).compareTo(
                _int(b['position']) ?? 0,
              ),
            );
          final swipes = [for (final v in variants) _str(v['content'])];
          var swipeId = variants.indexWhere((v) => v['selected'] == true);
          if (swipeId < 0) swipeId = swipes.indexOf(content);
          final isGreeting = chatMessages.isEmpty && !isUser;
          final greetingIndex = isGreeting ? greetings.indexOf(content) : -1;
          final reasoning = _str(m['reasoning']);

          chatMessages.add(
            ChatMessage(
              id: 'tavo_${convId}_${_id(m)}',
              role: isUser ? 'user' : 'assistant',
              content: content,
              timestamp: _int(m['timestamp']),
              personaId: isUser ? personaId : null,
              personaName: isUser && _str(m['speakerName']).isNotEmpty
                  ? _str(m['speakerName'])
                  : null,
              swipes: swipes.isNotEmpty
                  ? swipes
                  : (greetingIndex >= 0 ? [content] : const []),
              swipeId: swipeId < 0 ? 0 : swipeId,
              swipesMeta: [
                for (final v in variants)
                  {
                    if (_str(v['reasoning']).isNotEmpty)
                      'reasoning': _str(v['reasoning']),
                  },
              ],
              greetingIndex: greetingIndex >= 0 ? greetingIndex : null,
              reasoning: reasoning.isNotEmpty ? reasoning : null,
              isHidden: m['hidden'] == true,
            ),
          );
        }

        final title = _str(conv['title']);
        final updatedAt = _seconds(conv['updateAt']);
        await _chatRepo.put(
          ChatSession(
            id: sessionId,
            characterId: character.id,
            sessionIndex: idx,
            messages: chatMessages,
            updatedAt: updatedAt,
            sessionVars: {if (title.isNotEmpty) 'sessionName': title},
          ),
        );
        result.chats++;

        final prev = latest[character.id];
        if (prev == null || updatedAt >= prev.$2) {
          latest[character.id] = (idx, updatedAt);
        }

        if (personaId != null) s.personaByChat[sessionId] = personaId;
        final presetId = s.presetIds[_int(conv['overridePresetId'])];
        if (presetId != null) s.presetByChat[sessionId] = presetId;
        final books = [
          for (final lb in s.tavo.related(
            'Conversation.overrideLorebooks',
            convId,
          ))
            ?s.lorebookIds[lb],
        ];
        if (books.isNotEmpty) s.lorebooksByChat[sessionId] = books;

        // Tavo's long-term memory is one running summary kept as lines,
        // all of it injected every turn — Glaze's chat summary.
        final ltm = ltmByConversation[convId];
        final memories = _strings(ltm?['memories']);
        if (memories.isNotEmpty) {
          await _summaryRepo.put(
            sessionId: sessionId,
            content: memories.join('\n'),
            messageCount: chatMessages.length,
            enabled: ltm?['enabled'] == true,
          );
          result.summaries++;
        }
      } catch (e) {
        result.errors.add('Tavo Chat $convId: $e');
      }
    }

    for (final entry in latest.entries) {
      _cancel.check();
      final character = await _charRepo.getById(entry.key);
      if (character != null) {
        await _charRepo.put(
          character.copyWith(currentSessionIndex: entry.value.$1),
        );
      }
    }
  }

  // ── Active selections ─────────────────────────────────────────────────────

  /// Every id these maps held belonged to the data that was just cleared, so
  /// they are replaced outright rather than merged.
  Future<void> _writeSelections(_ImportState s) async {
    final prefs = await SharedPreferences.getInstance();
    Future<void> setOrRemove(String key, String? value) =>
        value == null ? prefs.remove(key) : prefs.setString(key, value);

    await setOrRemove('activePersonaId', s.activePersonaId);
    await setOrRemove('activePresetId', s.activePresetId);
    await setOrRemove('activeApiConfigId', s.activeApiId);
    await prefs.setString(
      'personaConnections',
      jsonEncode({'character': <String, String>{}, 'chat': s.personaByChat}),
    );
    await prefs.setString(
      'presetConnections',
      jsonEncode({'character': <String, String>{}, 'chat': s.presetByChat}),
    );
    await prefs.setString(
      'lorebookActivations',
      jsonEncode({
        'character': <String, List<String>>{},
        'chat': s.lorebooksByChat,
      }),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _uniqueId() =>
      '${generateId()}_${(DateTime.now().microsecondsSinceEpoch % 1000000).toRadixString(36)}';

  static List<Map<String, dynamic>> _sorted(List<Map<String, dynamic>> rows) =>
      [...rows]..sort((a, b) {
        final bySort = (_int(a['sortIndex']) ?? 0).compareTo(
          _int(b['sortIndex']) ?? 0,
        );
        return bySort != 0 ? bySort : _id(a).compareTo(_id(b));
      });

  static int _id(Map<String, dynamic> row) => _int(row['id']) ?? 0;

  static int? _int(Object? v) => v is num ? v.toInt() : null;

  static double? _double(Object? v) => v is num ? v.toDouble() : null;

  static String _str(Object? v) => v is String ? v : '';

  static List<String> _strings(Object? v) => v is List
      ? [
          for (final s in v)
            if (s is String) s,
        ]
      : const [];

  /// Tavo timestamps are milliseconds; Glaze stores seconds.
  static int _seconds(Object? ms) {
    final v = _int(ms);
    return v == null || v <= 0 ? currentTimestampSeconds() : v ~/ 1000;
  }

  static dynamic _json(Object? v) {
    if (v is! String || v.isEmpty) return v;
    try {
      return jsonDecode(v);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _jsonMap(Object? v) {
    final decoded = _json(v);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
  }

  static List<dynamic> _jsonList(Object? v) {
    final decoded = _json(v);
    return decoded is List ? decoded : const [];
  }
}

/// Tavo ids → Glaze ids, and the selections collected along the way.
class _ImportState {
  final TavoDatabase tavo;
  final Archive zip;

  /// The auxiliary store, when the backup carries one.
  final TavoDatabase? aux;

  final personaIds = <int, String>{};
  final endpointIds = <int, String>{};
  final presetIds = <int, String>{};
  final lorebookIds = <int, String>{};
  final characters = <int, Character>{};

  String? activePersonaId;
  String? activePresetId;
  String? activeApiId;
  final personaByChat = <String, String>{};
  final presetByChat = <String, String>{};
  final lorebooksByChat = <String, List<String>>{};

  _ImportState(this.tavo, this.zip, this.aux);

  /// Reads a file the database points at. Tavo stores paths relative to its
  /// files directory as `charaCard/…`; the backup keeps that directory as
  /// `CharacterCards/`.
  Uint8List? file(String tavoPath) {
    if (tavoPath.isEmpty) return null;
    final candidates = [
      if (tavoPath.startsWith('charaCard/'))
        'CharacterCards/${tavoPath.substring('charaCard/'.length)}',
      tavoPath,
    ];
    for (final name in candidates) {
      final f = zip.findFile(name);
      if (f != null && f.isFile) {
        final bytes = f.readBytes();
        f.clear();
        return bytes;
      }
    }
    return null;
  }
}
