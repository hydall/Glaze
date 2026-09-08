import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/services/character_book_converter.dart';
import 'package:glaze_flutter/core/import/silly_tavern_preset_parser.dart';

AppDatabase _testDb() => AppDatabase.forTesting(NativeDatabase.memory());

void main() {
  late AppDatabase db;

  setUp(() {
    db = _testDb();
  });

  tearDown(() async {
    await db.close();
  });

  group('LorebookRepo', () {
    late LorebookRepo repo;

    setUp(() {
      repo = LorebookRepo(db);
    });

    test('put and getAll round-trip', () async {
      final lb = Lorebook(
        id: 'lb1',
        name: 'World Lore',
        enabled: true,
        activationScope: 'global',
        entries: [
          LorebookEntry(
            id: '0',
            keys: ['castle'],
            content: 'The castle stands tall.',
          ),
        ],
      );

      await repo.put(lb);
      final all = await repo.getAll();
      expect(all.length, 1);
      expect(all.first.id, equals('lb1'));
      expect(all.first.name, equals('World Lore'));
      expect(all.first.entries.length, 1);
      expect(all.first.entries.first.keys, equals(['castle']));
    });

    test('getById returns lorebook or null', () async {
      expect(await repo.getById('missing'), isNull);

      await repo.put(Lorebook(id: 'lb1', name: 'Test'));
      final result = await repo.getById('lb1');
      expect(result, isNotNull);
      expect(result!.name, equals('Test'));
    });

    test('getByScopeAndTarget filters correctly', () async {
      await repo.put(Lorebook(
        id: 'global1',
        name: 'Global LB',
        activationScope: 'global',
      ));
      await repo.put(Lorebook(
        id: 'char_lb',
        name: 'Char LB',
        activationScope: 'character',
        activationTargetId: 'char1',
      ));
      await repo.put(Lorebook(
        id: 'char_lb2',
        name: 'Char LB 2',
        activationScope: 'character',
        activationTargetId: 'char2',
      ));

      final forChar1 = await repo.getByScopeAndTarget('character', 'char1');
      expect(forChar1.length, 1);
      expect(forChar1.first.id, equals('char_lb'));

      final globals = await repo.getByScopeAndTarget('global', '');
      expect(globals.length, 0,
          reason: 'Global lorebooks have null targetId, not empty string');

      final globalsDirect = (await repo.getAll())
          .where((lb) => lb.activationScope == 'global')
          .toList();
      expect(globalsDirect.length, 1);
      expect(globalsDirect.first.id, equals('global1'));

      final empty = await repo.getByScopeAndTarget('character', 'nonexistent');
      expect(empty, isEmpty);
    });

    test('delete removes lorebook', () async {
      await repo.put(Lorebook(id: 'lb1', name: 'Delete Me'));
      expect((await repo.getAll()).length, 1);

      await repo.delete('lb1');
      expect((await repo.getAll()).length, 0);
    });

    test('put updates existing lorebook', () async {
      await repo.put(Lorebook(id: 'lb1', name: 'V1'));
      await repo.put(Lorebook(id: 'lb1', name: 'V2'));

      final result = await repo.getById('lb1');
      expect(result!.name, equals('V2'));
    });

    test('createEntryFromCatalog adds entry to existing lorebook', () async {
      await repo.createEntryFromCatalog(
        characterId: 'char1',
        keys: ['magic'],
        content: 'Magic exists.',
      );

      var lb = await repo.getById('char1');
      expect(lb, isNotNull);
      expect(lb!.entries.length, 1);
      expect(lb.entries.first.content, equals('Magic exists.'));
      expect(lb.activationScope, equals('character'));
      expect(lb.activationTargetId, equals('char1'));

      await repo.createEntryFromCatalog(
        characterId: 'char1',
        keys: ['sword'],
        content: 'A sharp blade.',
      );

      lb = await repo.getById('char1');
      expect(lb!.entries.length, 2);
    });

    test('convertCharacterBook handles list and map entries', () {
      final listBook = convertCharacterBook({
        'name': 'List Book',
        'entries': [
          {
            'keys': ['alpha'],
            'content': 'List entry.',
          },
        ],
      }, 'char1');

      final mapBook = convertCharacterBook({
        'name': 'Map Book',
        'entries': {
          '0': {
            'keys': ['beta'],
            'content': 'Map entry.',
          },
        },
      }, 'char2');

      expect(listBook.entries, hasLength(1));
      expect(listBook.entries.first.keys, equals(['alpha']));
      expect(mapBook.entries, hasLength(1));
      expect(mapBook.entries.first.keys, equals(['beta']));
    });

    test('convertCharacterBook handles string positions', () {
      final book = convertCharacterBook({
        'name': 'String Position Book',
        'entries': [
          {
            'keys': ['alpha'],
            'content': 'Before character.',
            'position': 'before_char',
          },
          {
            'keys': ['beta'],
            'content': 'After character.',
            'position': 'after_char',
          },
          {
            'keys': ['gamma'],
            'content': 'At depth.',
            'position': 'at_depth',
          },
        ],
      }, 'char1');

      expect(book.entries[0].position, equals('worldInfoBefore'));
      expect(book.entries[1].position, equals('worldInfoAfter'));
      expect(book.entries[2].position, equals('lorebooksMacro'));
    });

    test('settings round-trip through put/getAll', () async {
      final lb = Lorebook(
        id: 'lb_settings',
        name: 'With Settings',
        settings: LorebookSettings(
          scanDepth: 10,
          vectorThreshold: 0.55,
          vectorTopK: 20,
        ),
      );

      await repo.put(lb);
      final result = await repo.getById('lb_settings');
      expect(result, isNotNull);
      expect(result!.settings, isNotNull);
      expect(result.settings!.scanDepth, equals(10));
      expect(result.settings!.vectorThreshold, equals(0.55));
      expect(result.settings!.vectorTopK, equals(20));
    });
  });

  group('CharacterRepo', () {
    late CharacterRepo repo;

    setUp(() {
      repo = CharacterRepo(db);
    });

    test('put and getAll round-trip', () async {
      final char = Character(id: 'c1', name: 'Alice', tags: ['fantasy', 'mage']);
      await repo.put(char);

      final all = await repo.getAll();
      expect(all.length, 1);
      expect(all.first.id, equals('c1'));
      expect(all.first.name, equals('Alice'));
      expect(all.first.tags, equals(['fantasy', 'mage']));
    });

    test('getById returns character or null', () async {
      expect(await repo.getById('missing'), isNull);

      await repo.put(Character(id: 'c1', name: 'Test'));
      final result = await repo.getById('c1');
      expect(result!.name, equals('Test'));
    });

    test('getByIds returns map of found characters', () async {
      await repo.put(Character(id: 'c1', name: 'Alice'));
      await repo.put(Character(id: 'c2', name: 'Bob'));
      await repo.put(Character(id: 'c3', name: 'Carol'));

      final result = await repo.getByIds({'c1', 'c3'});
      expect(result.length, 2);
      expect(result['c1']!.name, equals('Alice'));
      expect(result['c3']!.name, equals('Carol'));
      expect(result.containsKey('c2'), isFalse);
    });

    test('getByIds with empty set returns empty map', () async {
      final result = await repo.getByIds({});
      expect(result, isEmpty);
    });

    test('delete cascades to chat sessions, summaries, and memory book rows', () async {
      await repo.put(Character(id: 'c1', name: 'To Delete'));

      await db.into(db.chatSessions).insertOnConflictUpdate(
            ChatSessionsCompanion.insert(
              sessionId: 's1',
              characterId: 'c1',
              sessionIndex: 0,
              messagesJson: '[]',
            ),
          );

      await db.into(db.memoryBookRows).insertOnConflictUpdate(
            MemoryBookRowsCompanion.insert(
              sessionId: 's1',
              entriesJson: const Value('[]'),
            ),
          );

      await db.into(db.chatSummaries).insertOnConflictUpdate(
            ChatSummariesCompanion.insert(
              sessionId: 's1',
              content: 'summary text',
            ),
          );

      expect((await db.select(db.chatSessions).get()).length, 1);
      expect((await db.select(db.memoryBookRows).get()).length, 1);
      expect((await db.select(db.chatSummaries).get()).length, 1);

      await repo.delete('c1');

      expect((await db.select(db.characters).get()).length, 0);
      expect((await db.select(db.chatSessions).get()).length, 0,
          reason: 'Chat sessions should be cascade-deleted');
      expect((await db.select(db.memoryBookRows).get()).length, 0,
          reason: 'Memory book rows should be cascade-deleted');
      expect((await db.select(db.chatSummaries).get()).length, 0,
          reason: 'Chat summaries should be cascade-deleted');
    });

    test('delete with multiple sessions batches correctly', () async {
      await repo.put(Character(id: 'c1', name: 'Multi Session'));

      for (var i = 0; i < 5; i++) {
        await db.into(db.chatSessions).insertOnConflictUpdate(
              ChatSessionsCompanion.insert(
                sessionId: 's$i',
                characterId: 'c1',
                sessionIndex: i,
                messagesJson: '[]',
              ),
            );
        await db.into(db.memoryBookRows).insertOnConflictUpdate(
              MemoryBookRowsCompanion.insert(
                sessionId: 's$i',
                entriesJson: const Value('[]'),
              ),
            );
        await db.into(db.chatSummaries).insertOnConflictUpdate(
              ChatSummariesCompanion.insert(
                sessionId: 's$i',
                content: 'summary $i',
              ),
            );
      }

      await repo.delete('c1');

      expect((await db.select(db.chatSessions).get()).length, 0);
      expect((await db.select(db.memoryBookRows).get()).length, 0);
      expect((await db.select(db.chatSummaries).get()).length, 0);
    });

    test('delete does not affect other characters sessions', () async {
      await repo.put(Character(id: 'c1', name: 'Delete Me'));
      await repo.put(Character(id: 'c2', name: 'Keep Me'));

      await db.into(db.chatSessions).insertOnConflictUpdate(
            ChatSessionsCompanion.insert(
              sessionId: 's1',
              characterId: 'c1',
              sessionIndex: 0,
              messagesJson: '[]',
            ),
          );
      await db.into(db.chatSessions).insertOnConflictUpdate(
            ChatSessionsCompanion.insert(
              sessionId: 's2',
              characterId: 'c2',
              sessionIndex: 0,
              messagesJson: '[]',
            ),
          );

      await repo.delete('c1');

      final remaining = await db.select(db.chatSessions).get();
      expect(remaining.length, 1);
      expect(remaining.first.sessionId, equals('s2'));
    });

    test('createCharacterFromCatalog inserts character', () async {
      await repo.createCharacterFromCatalog(
        id: 'cat1',
        name: 'From Catalog',
        description: 'A catalog character',
        tags: ['tag1', 'tag2'],
        alternateGreetings: ['Hello!', 'Hi there!'],
      );

      final result = await repo.getById('cat1');
      expect(result, isNotNull);
      expect(result!.name, equals('From Catalog'));
      expect(result.description, equals('A catalog character'));
      expect(result.tags, equals(['tag1', 'tag2']));
      expect(result.alternateGreetings, equals(['Hello!', 'Hi there!']));
    });

    test('alternateGreetings and tags round-trip through put/getAll', () async {
      final char = Character(
        id: 'c1',
        name: 'Tags Test',
        tags: ['anime', 'fantasy'],
        alternateGreetings: ['Greeting 1', 'Greeting 2'],
      );

      await repo.put(char);
      final result = await repo.getById('c1');
      expect(result!.tags, equals(['anime', 'fantasy']));
      expect(result.alternateGreetings, equals(['Greeting 1', 'Greeting 2']));
    });

    test('extensions round-trip through put/getAll', () async {
      final char = Character(
        id: 'c1',
        name: 'Extensions Test',
        extensions: {'depth_prompt': {'prompt': 'test', 'depth': 4}},
      );

      await repo.put(char);
      final result = await repo.getById('c1');
      expect(result!.extensions.containsKey('depth_prompt'), isTrue);
    });

    test('watchAll emits updates', () async {
      final stream = repo.watchAll();

      final firstEmit = await stream.first;
      expect(firstEmit, isEmpty);

      await repo.put(Character(id: 'c1', name: 'Alice'));

      final secondEmit = await stream.first;
      expect(secondEmit.length, 1);
      expect(secondEmit.first.name, equals('Alice'));
    });

    group('variations', () {
      // Helper: a variation row in group [g] at [order].
      Future<void> putVariant(
        String id,
        String g,
        int order, {
        String? variantName,
        List<String> tags = const [],
      }) =>
          repo.put(Character(
            id: id,
            name: id,
            variantGroupId: g,
            variantOrder: order,
            variantName: variantName,
            tags: tags,
          ));

      test('getPage / watchTotalCount only return representatives', () async {
        await putVariant('c1', 'c1', 0);
        await putVariant('c1b', 'c1', 1, variantName: 'NSFW');
        await putVariant('c2', 'c2', 0);

        final page = await repo.getPage(
          limit: 50,
          offset: 0,
          sort: CharacterSortField.name,
          dir: CharacterSortDir.asc,
        );
        expect(page.map((c) => c.id), equals(['c1', 'c2']),
            reason: 'Only variant_order 0 rows are list representatives');

        final count = await repo.watchTotalCount().first;
        expect(count, 2);

        // getAll still returns every variation row.
        expect((await repo.getAll()).length, 3);
      });

      test('getVariants returns the group ordered, representative first',
          () async {
        await putVariant('c1b', 'c1', 1, variantName: 'NSFW');
        await putVariant('c1', 'c1', 0);

        final variants = await repo.getVariants('c1');
        expect(variants.map((c) => c.id), equals(['c1', 'c1b']));
        expect(variants.first.variantName, isNull);
        expect(variants.last.variantName, equals('NSFW'));
      });

      test('nextVariantOrder is max + 1 (and 0 for a fresh group)', () async {
        expect(await repo.nextVariantOrder('c1'), 0);
        await putVariant('c1', 'c1', 0);
        await putVariant('c1b', 'c1', 1);
        expect(await repo.nextVariantOrder('c1'), 2);
      });

      test('deleting the representative promotes the next sibling', () async {
        await putVariant('c1', 'c1', 0);
        await putVariant('c1b', 'c1', 1, variantName: 'AU');

        await repo.delete('c1');

        final variants = await repo.getVariants('c1');
        expect(variants.length, 1);
        expect(variants.first.id, equals('c1b'));
        expect(variants.first.variantOrder, equals(0),
            reason: 'Sibling promoted to representative so the group survives');

        final page = await repo.getPage(
          limit: 50,
          offset: 0,
          sort: CharacterSortField.name,
          dir: CharacterSortDir.asc,
        );
        expect(page.map((c) => c.id), equals(['c1b']));
      });

      // Variations are ordered by creation and the user cannot reorder them:
      // the row at order 0 is the original, which is what makes "which one
      // represents the group" a question with only one answer.
      test('getVariants returns the group in creation order, original first',
          () async {
        await putVariant('a', 'g', 0);
        await putVariant('b', 'g', 1);
        await putVariant('c', 'g', 2);

        final variants = await repo.getVariants('g');
        expect(variants.map((v) => v.id), equals(['a', 'b', 'c']));
        expect(variants.map((v) => v.variantOrder), equals([0, 1, 2]));
      });

      test('setHidden hides every variation in the group', () async {
        await putVariant('a', 'g', 0);
        await putVariant('b', 'g', 1);
        await putVariant('c', 'g', 2);

        await repo.setHidden('g', true);

        final variants = await repo.getVariants('g');
        expect(variants.map((v) => v.hidden), everyElement(isTrue));
      });

      test('standalone put backfills variantGroupId to its own id', () async {
        await repo.put(Character(id: 'solo', name: 'Solo'));
        final result = await repo.getById('solo');
        expect(result!.variantGroupId, equals('solo'));
      });
    });

    group('hidden', () {
      test('hidden characters are excluded from the list by default', () async {
        await repo.put(Character(id: 'a', name: 'Alice'));
        await repo.put(Character(id: 'b', name: 'Bob', hidden: true));

        final page = await repo.getPage(
          limit: 50,
          offset: 0,
          sort: CharacterSortField.name,
          dir: CharacterSortDir.asc,
        );
        expect(page.map((c) => c.id), equals(['a']));
        expect(await repo.watchTotalCount().first, 1);

        // getAll/getById still see hidden rows (chat, detail, sync depend on it).
        expect((await repo.getAll()).length, 2);
        expect((await repo.getById('b'))!.hidden, isTrue);
      });

      test('includeHidden surfaces hidden characters and counts them', () async {
        await repo.put(Character(id: 'a', name: 'Alice'));
        await repo.put(Character(id: 'b', name: 'Bob', hidden: true));

        final page = await repo.getPage(
          limit: 50,
          offset: 0,
          sort: CharacterSortField.name,
          dir: CharacterSortDir.asc,
          includeHidden: true,
        );
        expect(page.map((c) => c.id), equals(['a', 'b']));
        expect(await repo.watchTotalCount(includeHidden: true).first, 2);
      });

      test('setHidden hides/reveals every row in a variation group', () async {
        await repo.put(Character(id: 'c1', name: 'c1', variantGroupId: 'c1'));
        await repo.put(Character(
          id: 'c1b',
          name: 'c1b',
          variantGroupId: 'c1',
          variantOrder: 1,
        ));

        await repo.setHidden('c1', true);
        expect((await repo.getVariants('c1')).every((c) => c.hidden), isTrue);
        // Representative is hidden → group leaves the default list.
        final hiddenPage = await repo.getPage(
          limit: 50,
          offset: 0,
          sort: CharacterSortField.name,
          dir: CharacterSortDir.asc,
        );
        expect(hiddenPage, isEmpty);

        await repo.setHidden('c1', false);
        expect((await repo.getVariants('c1')).any((c) => c.hidden), isFalse);
      });

      test('setHidden hides a standalone row with empty variant_group_id',
          () async {
        // Legacy rows (and catalog imports predating the group backfill) can
        // still carry an empty variant_group_id. setHidden resolves the group
        // id to the char id for a standalone character, so it must match those
        // rows by id — otherwise the hide toggle silently affects zero rows.
        await db.into(db.characters).insert(
              const CharactersCompanion(
                charId: Value('legacy'),
                name: Value('Legacy'),
                variantGroupId: Value(''),
              ),
            );

        await repo.setHidden('legacy', true);
        expect((await repo.getById('legacy'))!.hidden, isTrue);

        final page = await repo.getPage(
          limit: 50,
          offset: 0,
          sort: CharacterSortField.name,
          dir: CharacterSortDir.asc,
        );
        expect(page, isEmpty);

        await repo.setHidden('legacy', false);
        expect((await repo.getById('legacy'))!.hidden, isFalse);
      });

      test('catalog imports are hideable', () async {
        await repo.createCharacterFromCatalog(id: 'cat', name: 'Cat');
        await repo.setHidden('cat', true);
        expect((await repo.getById('cat'))!.hidden, isTrue);
      });
    });
  });

  group('parseSillyTavernPreset', () {
    test('imports Glaze-export format (no identifier) correctly', () {
      final json = <String, dynamic>{
        'name': 'lucid_loom_v3_4_reminder',
        'prompts': [
          {
            'name': 'Global Think Trigger',
            'role': 'system',
            'content': 'Think first.',
            'enabled': false,
            'insertion_mode': 'relative',
            'depth': 4,
          },
          {
            'name': 'Core Instructions',
            'role': 'system',
            'content': 'You are Lumia.',
            'enabled': true,
            'insertion_mode': 'depth',
            'depth': 2,
          },
        ],
      };

      final preset = parseSillyTavernPreset(json, 'lucid_loom_v3_4_reminder.json');

      expect(preset.name, equals('lucid_loom_v3_4_reminder'));

      // Custom blocks should be present
      final customBlocks = preset.blocks.where((b) => !{
        'chat_history', 'char_card', 'char_personality', 'user_persona',
        'example_dialogue', 'worldInfoBefore', 'worldInfoAfter', 'scenario',
        'main', 'summary', 'authors_note', 'guided_generation', 'memory',
      }.contains(b.id)).toList();

      expect(customBlocks.length, equals(2));

      final block0 = customBlocks[0];
      expect(block0.name, equals('Global Think Trigger'));
      expect(block0.enabled, isFalse);
      expect(block0.insertionMode, equals('relative'));
      expect(block0.content, equals('Think first.'));

      final block1 = customBlocks[1];
      expect(block1.name, equals('Core Instructions'));
      expect(block1.enabled, isTrue);
      expect(block1.insertionMode, equals('depth'));
      expect(block1.depth, equals(2));
      expect(block1.content, equals('You are Lumia.'));
    });

    test('Glaze format: mandatory block names get normalized ids and empty content', () {
      final json = <String, dynamic>{
        'name': 'test_preset',
        'prompts': [
          {
            'name': 'Character Card',
            'role': 'system',
            'content': 'should be cleared',
            'enabled': true,
            'insertion_mode': 'relative',
          },
          {
            'name': 'My Custom Block',
            'role': 'system',
            'content': 'keep this',
            'enabled': true,
            'insertion_mode': 'relative',
          },
        ],
      };

      final preset = parseSillyTavernPreset(json, 'test.json');
      final charCard = preset.blocks.firstWhere((b) => b.id == 'char_card');
      expect(charCard.content, equals(''));

      final custom = preset.blocks.firstWhere((b) => b.name == 'My Custom Block');
      expect(custom.content, equals('keep this'));
    });

    test('SillyTavern native format (with identifier) still works', () {
      final json = <String, dynamic>{
        'name': 'st_preset',
        'prompts': [
          {
            'identifier': 'main',
            'name': 'Main Prompt',
            'role': 'system',
            'content': 'Write the reply.',
            'enabled': true,
          },
          {
            'identifier': 'myblock',
            'name': 'My Block',
            'role': 'system',
            'content': 'Custom content.',
            'enabled': true,
            'injection_position': 1,
            'injection_depth': 3,
          },
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'main', 'enabled': true},
              {'identifier': 'myblock', 'enabled': true},
            ],
          },
        ],
      };

      final preset = parseSillyTavernPreset(json, 'st_preset.json');
      expect(preset.name, equals('st_preset'));

      final myblock = preset.blocks.firstWhere((b) => b.id == 'myblock');
      expect(myblock.insertionMode, equals('depth'));
      expect(myblock.depth, equals(3));
    });
  });
}
