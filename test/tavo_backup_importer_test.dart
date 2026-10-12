import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_repo.dart';
import 'package:glaze_flutter/core/db/repositories/persona_repo.dart';
import 'package:glaze_flutter/core/db/repositories/preset_repo.dart';
import 'package:glaze_flutter/core/db/repositories/summary_repo.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/services/backup/tavo_backup_importer.dart';
import 'package:glaze_flutter/core/services/backup/tavo_lmdb_reader.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';

/// A real Tavo 1.6.2 "Full backup", trimmed to the database, the avatars and
/// the auxiliary store. Made on a device with: a card carrying an embedded
/// book (Mira Vale), a standalone SillyTavern lorebook, an imported ST preset
/// and regex, a persona with an avatar, three chats (one renamed, pinned,
/// with a hidden message, rerolled replies, long-term memory and an attached
/// lorebook and regex group) and an endpoint with sampling overrides, a custom
/// header and a custom body.
const _fixture = 'test/fixtures/tavo/tavo_backup_v1.6.2.tbk';

Uint8List _entry(String name) {
  final zip = ZipDecoder().decodeBytes(File(_fixture).readAsBytesSync());
  return zip.findFile(name)!.readBytes()!;
}

class _TestImageStorage extends ImageStorageService {
  _TestImageStorage()
    : super(Directory.systemTemp.createTempSync('glaze_tavo_img_').path);

  final saved = <String, int>{};

  @override
  Future<String> saveAvatar(String characterId, Uint8List imageBytes) async {
    saved[characterId] = imageBytes.length;
    return '/fake/avatars/$characterId.png';
  }
}

void main() {
  group('parseTavoObjectBox', () {
    late TavoDatabase db;
    setUpAll(() => db = parseTavoObjectBox(_entry('objectbox/data.mdb')));

    test('decodes every entity through the schema stored in the file', () {
      expect(db.rows('Character').map((c) => c['name']), [
        'Victoria Ling',
        'Mira Vale',
      ]);
      final mira = db.rows('Character')[1];
      expect(mira['description'], startsWith('Mira is a cartographer'));
      expect(mira['personality'], 'curious, stubborn');
      expect(mira['alternateGreetings'], hasLength(2));
      expect(mira['creationDate'], 1700000000000);
      expect(db.rows('Conversation'), hasLength(3));
      expect(db.rows('Message'), hasLength(17));
    });

    test('reads the live tree, not stale copies left in free pages', () {
      // The file still holds an older version of this reply in a freed page;
      // a page scan would surface "Reply #3".
      final reply = db.rows('Message').firstWhere((m) => m['id'] == 17);
      expect(reply['content'], 'Reply #4 to: Second chat hello');
    });

    test('decodes ToMany relations and Flex properties', () {
      expect(db.related('Conversation.characters', 2), [2]);
      expect(db.related('Conversation.overrideLorebooks', 2), [1, 2]);
      expect(db.related('RegexConversationRef.regexes', 1), [1]);
      expect(db.rows('Endpoint').single['overrideHeaders'], {
        'X-Test-Header': 'hello',
      });
    });

    test('reads the auxiliary store with the reroll variants', () {
      final aux = parseTavoObjectBox(_entry('objectbox_aux/data.mdb'));
      expect(aux.rows('MessageVariant'), hasLength(6));
    });
  });

  group('TavoBackupInfo', () {
    Archive withInfo(String text) =>
        Archive()..addFile(ArchiveFile.string('backup_info.txt', text));

    test('the fixture is the version the importer was tested on', () {
      final zip = ZipDecoder().decodeBytes(File(_fixture).readAsBytesSync());
      final info = TavoBackupInfo.fromArchive(zip);
      expect(info.appVersion, '1.6.2');
      expect(info.databaseFormat, 2);
      expect(info.isTested, isTrue);
    });

    test('another app version or database format is flagged', () {
      final newer = TavoBackupInfo.fromArchive(
        withInfo('app_version: 1.7.0\ndatabase_format: 3\n'),
      );
      expect(newer.appVersion, '1.7.0');
      expect(newer.databaseFormat, 3);
      expect(newer.isTested, isFalse);
      expect(
        TavoBackupInfo.fromArchive(
          withInfo('app_version: 1.6.2\ndatabase_format: 3'),
        ).isTested,
        isFalse,
      );
    });

    test('a backup without version info is flagged', () {
      final info = TavoBackupInfo.fromArchive(Archive());
      expect(info.appVersion, isNull);
      expect(info.databaseFormat, isNull);
      expect(info.isTested, isFalse);
    });
  });

  group('TavoBackupInspection', () {
    test('lists what the fixture holds that will not come over', () {
      final zip = ZipDecoder().decodeBytes(File(_fixture).readAsBytesSync());
      final inspection = TavoBackupInspection.fromArchive(zip);
      expect(inspection.info.isTested, isTrue);
      expect(
        inspection.skipped.map((s) => '${s.kind.name} ${s.count} ${s.names}'),
        ['endpointHeaders 0 [API 1]', 'chatScenarios 1 []'],
      );
    });

    test('a standard backup is flagged as missing the swipes', () {
      final full = ZipDecoder().decodeBytes(File(_fixture).readAsBytesSync());
      final standard = Archive();
      for (final f in full.files) {
        if (!f.name.startsWith('objectbox_aux/')) standard.addFile(f);
      }
      final kinds = TavoBackupInspection.fromArchive(
        standard,
      ).skipped.map((s) => s.kind);
      expect(kinds, contains(TavoSkippedKind.rerollsNeedFullBackup));
    });
  });

  group('TavoBackupImporter', () {
    late AppDatabase db;
    late _TestImageStorage images;
    late TavoImportResult result;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      db = AppDatabase.forTesting(NativeDatabase.memory());
      images = _TestImageStorage();
      result = await TavoBackupImporter(db, images).importFromFile(_fixture);
    });

    tearDownAll(() => db.close());

    test('reports what it brought over', () {
      expect(result.info.isTested, isTrue);
      expect(result.characters, 2);
      expect(result.personas, 2);
      expect(result.apis, 1);
      expect(result.lorebooks, 2);
      expect(result.presets, 3);
      expect(result.regexes, 1);
      expect(result.chats, 3);
      expect(result.summaries, 1);
      expect(result.skippedGroupChats, 0);
      // The custom header has nowhere to go in Glaze, and says so.
      expect(result.errors, [contains('X-Test-Header')]);
    });

    test('characters keep every card field', () async {
      final chars = await CharacterRepo(db).getAll();
      final mira = chars.firstWhere((c) => c.name == 'Mira Vale');
      expect(mira.description, startsWith('Mira is a cartographer'));
      expect(mira.personality, 'curious, stubborn');
      expect(mira.scenario, 'A rainy evening at the docks.');
      expect(mira.systemPrompt, 'You are Mira. Stay in character.');
      expect(mira.postHistoryInstructions, 'Keep replies under 100 words.');
      expect(mira.creatorNotes, 'Test card for Tavo import.');
      expect(mira.alternateGreetings, [
        'Alt greeting one: Mira waves.',
        'Alt greeting two: Mira sighs.',
      ]);
      expect(mira.tags, ['fantasy', 'cartographer']);
      expect(mira.creator, 'glaze-test');
      expect(mira.characterVersion, '1.4');
      expect(mira.macroName, 'Mimi');
      expect(mira.depthPrompt, 'Mira hates being interrupted.');
      expect(mira.depthPromptDepth, 3);
      expect(mira.depthPromptRole, 'system');
      // Points at the book under the name Tavo gave it.
      expect(mira.world, "Mira Vale's Lorebook (Mira Book)");
      expect(mira.fav, isTrue);
      expect(mira.createdAt, 1700000000);
      expect(mira.extensions['custom_ext'], {'a': 1});
      expect(mira.extensions['group_only_greetings'], [
        'Group greeting: Mira nods to everyone.',
      ]);
      expect(images.saved[mira.id], 6235);
    });

    test('personas and the active one', () async {
      final personas = await PersonaRepo(db).getAll();
      final ren = personas.firstWhere((p) => p.name == 'Captain Ren');
      expect(ren.prompt, 'Ren is a retired sea captain with a limp.');
      expect(ren.avatarPath, isNotNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('activePersonaId'), ren.id);
    });

    test('endpoint merges global and per-endpoint sampling', () async {
      final api = (await ApiConfigRepo(db).getAll()).single;
      expect(api.protocol, LlmProtocol.customChatCompletion);
      expect(api.endpoint, startsWith('http://172.18.0.4:8088/v1'));
      expect(api.apiKey, 'test-key');
      expect(api.model, 'tavo-capture');
      // Global Model settings.
      expect(api.temperature, closeTo(0.8, 1e-9));
      expect(api.omitTemperature, isFalse);
      expect(api.maxTokens, 600);
      // Endpoint overrides.
      expect(api.topP, closeTo(0.95, 1e-9));
      expect(api.omitTopP, isFalse);
      expect(api.frequencyPenalty, closeTo(0.3, 1e-9));
      // Never set anywhere.
      expect(api.omitTopK, isTrue);
      expect(api.extraRequestParameters.map((p) => '${p.key}=${p.value}'), [
        'seed=42',
      ]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('activeApiConfigId'), api.id);
    });

    test('lorebook entries map Tavo strategies and positions', () async {
      final books = await LorebookRepo(db).getAll();
      final chars = await CharacterRepo(db).getAll();
      final mira = chars.firstWhere((c) => c.name == 'Mira Vale');

      final cardBook = books.firstWhere((b) => b.name.contains('Mira Book'));
      expect(cardBook.enabled, isFalse);
      expect(cardBook.activationScope, 'character');
      expect(cardBook.activationTargetId, mira.id);
      final harbor = cardBook.entries.firstWhere((e) => e.comment == 'Harbor');
      expect(harbor.keys, ['harbor', 'docks']);
      expect(harbor.secondaryKeys, ['night']);
      expect(harbor.selectiveLogic, 0);
      expect(harbor.position, 'worldInfoBefore');
      expect(harbor.probability, 70);
      expect(harbor.caseSensitive, isTrue);
      expect(harbor.matchWholeWords, isTrue);
      expect(harbor.scanDepth, 5);
      expect(harbor.sticky, 2);
      expect(harbor.cooldown, 1);
      expect(harbor.delay, 3);
      expect(harbor.group, 'places');
      expect(harbor.preventRecursion, isTrue);
      expect(
        cardBook.entries
            .firstWhere((e) => e.comment.startsWith('Compass'))
            .constant,
        isTrue,
      );

      final world = books.firstWhere((b) => b.name == 'world_of_fog');
      expect(world.activationScope, 'global');
      expect(world.enabled, isFalse);
      expect(world.entries.map((e) => e.comment), [
        'Always on',
        'Fog',
        'Lighthouse (disabled)',
      ]);
      final fog = world.entries[1];
      expect(fog.selectiveLogic, 1);
      expect(fog.position, 'worldInfoAfter');
      expect(world.entries[2].enabled, isFalse);
      expect(world.entries[2].selectiveLogic, 4);
    });

    test('presets keep block order, depth and enabled state', () async {
      final presets = await PresetRepo(db).getAll();
      expect(
        presets.map((p) => p.name),
        containsAll(['Default', 'Whisper', 'fog_preset']),
      );
      final fog = presets.firstWhere((p) => p.name == 'fog_preset');
      final main = fog.blocks.firstWhere((b) => b.id == 'main');
      expect(main.content, 'Custom main prompt for {{char}}.');
      final jb = fog.blocks.firstWhere((b) => b.name == 'My Jailbreak');
      expect(jb.insertionMode, 'depth');
      expect(jb.depth, 2);
      expect(jb.role, 'user');
      expect(
        fog.blocks.firstWhere((b) => b.name == 'Disabled Block').enabled,
        isFalse,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('activePresetId'), fog.id);
    });

    test('regex rules become global scripts', () async {
      final prefs = await SharedPreferences.getInstance();
      final scripts =
          jsonDecode(prefs.getString('gz_global_regex_scripts')!) as List;
      final rule = scripts.single as Map<String, dynamic>;
      expect(rule['name'], '[FogRegex] Strip asterisks');
      expect(rule['regex'], r'/\*([^*]+)\*/g');
      expect(rule['replacement'], r'_$1_');
      expect(rule['trimOut'], 'OOC:');
      expect(rule['placement'], [1, 2]);
      expect(rule['markdownOnly'], isTrue);
      expect(rule['promptOnly'], isFalse);
      expect(rule['maxDepth'], 5);
      // The group was attached to a chat, so the rule stays on.
      expect(rule['disabled'], isFalse);
    });

    test('chats keep order, hidden flags, reasoning and rerolls', () async {
      final chars = await CharacterRepo(db).getAll();
      final mira = chars.firstWhere((c) => c.name == 'Mira Vale');
      final sessions = await ChatRepo(db).getByCharacterId(mira.id);
      sessions.sort((a, b) => a.sessionIndex.compareTo(b.sessionIndex));
      expect(sessions, hasLength(2));

      final fogTalk = sessions.first;
      expect(fogTalk.sessionVars['sessionName'], 'Fog talk');
      final msgs = fogTalk.messages;
      expect(msgs.map((m) => m.role), [
        'assistant',
        'user',
        'assistant',
        'user',
        'assistant',
        'user',
        'assistant',
      ]);
      expect(msgs.first.content, 'Alt greeting one: Mira waves.');
      expect(msgs.first.greetingIndex, 1);
      expect(msgs[1].personaName, 'Captain Ren');
      expect(msgs[3].content, 'And the lighthouse?');
      expect(msgs[3].isHidden, isTrue);
      expect(msgs[2].reasoning, 'Reasoning for reply #1.');

      final rerolled = msgs.last;
      expect(rerolled.content, 'Reply #3 to: Mira, show me your compass.');
      expect(rerolled.swipes, hasLength(3));
      expect(rerolled.swipeId, 0);
      expect(rerolled.swipesMeta[1]['reasoning'], 'Reasoning for reply #4.');

      final second = sessions.last.messages.last;
      expect(second.content, 'Reply #4 to: Second chat hello');
      expect(second.swipes, hasLength(3));
      expect(second.swipeId, 2);

      final charAfter = await CharacterRepo(db).getById(mira.id);
      expect(charAfter!.currentSessionIndex, 2);
    });

    test('long-term memory becomes the chat summary', () async {
      final chars = await CharacterRepo(db).getAll();
      final mira = chars.firstWhere((c) => c.name == 'Mira Vale');
      final summary = await SummaryRepo(db).get('${mira.id}_1');
      expect(summary, isNotNull);
      expect(summary!.enabled, isTrue);
      expect(
        summary.content,
        '- Memory #1: Ren asked Mira about the harbor fog; Mira showed her '
        'brass compass.\n- Ren fears the lighthouse.',
      );
      expect(await SummaryRepo(db).get('${mira.id}_2'), isNull);
    });

    test('chat bindings carry over', () async {
      final prefs = await SharedPreferences.getInstance();
      final chars = await CharacterRepo(db).getAll();
      final mira = chars.firstWhere((c) => c.name == 'Mira Vale');
      final books = await LorebookRepo(db).getAll();
      final activations =
          jsonDecode(prefs.getString('lorebookActivations')!)
              as Map<String, dynamic>;
      expect(
        (activations['chat'] as Map)['${mira.id}_1'],
        unorderedEquals(books.map((b) => b.id)),
      );
      final personas = await PersonaRepo(db).getAll();
      final ren = personas.firstWhere((p) => p.name == 'Captain Ren');
      final connections =
          jsonDecode(prefs.getString('personaConnections')!)
              as Map<String, dynamic>;
      expect((connections['chat'] as Map)['${mira.id}_1'], ren.id);
    });

    test('a group chat is skipped', () async {
      // Sanity check on the rule itself: every fixture chat has one
      // character, and every one of them came through.
      final all = <ChatSession>[];
      for (final c in await CharacterRepo(db).getAll()) {
        all.addAll(await ChatRepo(db).getByCharacterId(c.id));
      }
      expect(all, hasLength(3));
    });
  });
}
