import 'package:glaze_flutter/core/import/st_lorebook_importer.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/services/st_lorebook_exporter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('glazePositionToST', () {
    test('maps the known positions', () {
      expect(glazePositionToST('worldInfoBefore'), 0);
      expect(glazePositionToST('lorebooksMacro'), 4);
      expect(glazePositionToST('worldInfoAfter'), 1);
      expect(glazePositionToST('matchGlobal'), 1);
    });
  });

  group('Glaze → ST → Glaze round trip', () {
    final entry = const LorebookEntry(
      id: 'e1',
      comment: 'Bio',
      enabled: false,
      constant: true,
      keys: ['Alicia', 'alicia'],
      secondaryKeys: ['throne'],
      selectiveLogic: 1,
      content: 'Alicia rules the kingdom.',
      position: 'worldInfoBefore',
      order: 42,
      scanDepth: 7,
      caseSensitive: true,
      matchWholeWords: true,
      probability: 80,
      preventRecursion: true,
      sticky: 3,
      cooldown: 5,
      delay: 2,
      group: 'rulers',
      groupProminence: 250,
      characterFilter: LorebookCharacterFilter(names: ['Alicia'], isExclude: true),
      ignoreBudget: true,
      vectorSearch: true,
      useKeywordSearch: false,
      delayUntilRecursion: true,
      useGroupScoring: true,
    );

    final exported = glazeLorebookToSTJson(
      Lorebook(
        id: 'lb1',
        name: 'Kingdom lore',
        entries: [entry],
      ),
    );

    final imported = importSTLorebook(
      Map<String, dynamic>.from(exported),
      nameOverride: 'roundtrip',
    );
    final roundTripped = imported.lorebook.entries.single;

    test('keeps the book name', () {
      expect(imported.lorebook.name, 'Kingdom lore');
      expect(imported.entryCount, 1);
    });

    test('keeps core text fields', () {
      expect(roundTripped.comment, 'Bio');
      expect(roundTripped.content, 'Alicia rules the kingdom.');
      expect(roundTripped.keys, ['Alicia', 'alicia']);
      expect(roundTripped.secondaryKeys, ['throne']);
      expect(roundTripped.constant, true);
      expect(roundTripped.enabled, false);
      expect(roundTripped.selectiveLogic, 1);
      expect(roundTripped.order, 42);
      expect(roundTripped.probability, 80);
    });

    test('keeps recursion, group and timing fields', () {
      expect(roundTripped.preventRecursion, true);
      expect(roundTripped.delayUntilRecursion, true);
      expect(roundTripped.sticky, 3);
      expect(roundTripped.cooldown, 5);
      expect(roundTripped.delay, 2);
      expect(roundTripped.group, 'rulers');
      expect(roundTripped.groupProminence, 250);
      expect(roundTripped.useGroupScoring, true);
    });

    test('keeps scan overrides and Glaze-only flags', () {
      expect(roundTripped.scanDepth, 7);
      expect(roundTripped.caseSensitive, true);
      expect(roundTripped.matchWholeWords, true);
      expect(roundTripped.ignoreBudget, true);
      expect(roundTripped.vectorSearch, true);
      expect(roundTripped.useKeywordSearch, false);
    });

    test('keeps the position and the character filter', () {
      expect(roundTripped.position, 'worldInfoBefore');
      expect(roundTripped.characterFilter?.names, ['Alicia']);
      expect(roundTripped.characterFilter?.isExclude, true);
    });

    test('emits ST-shaped top-level fields', () {
      final st = exported['entries']['0'] as Map<String, dynamic>;
      expect(st['position'], 0); // worldInfoBefore
      expect(st['groupWeight'], 250);
      expect(st['preventRecursion'], true);
      expect(st['excludeRecursion'], false);
      expect(st['delayUntilRecursion'], true);
      expect(st['disable'], true);
      final filter = st['characterFilter'] as Map<String, dynamic>;
      expect(filter['names'], ['Alicia']);
      expect(filter['isExclude'], true);
      expect((exported['entries'] as Map).keys, contains('0'));
    });
  });

  group('ST-native imports', () {
    test('reads groupWeight and excludeRecursion fallbacks', () {
      final result = importSTLorebook({
        'entries': {
          '0': {
            'uid': 0,
            'key': ['k'],
            'content': 'c',
            'groupWeight': 33,
            'excludeRecursion': true,
            'delayUntilRecursion': true,
            'useGroupScoring': true,
          },
        },
      });
      final e = result.lorebook.entries.single;
      expect(e.groupProminence, 33);
      expect(e.preventRecursion, true);
      expect(e.delayUntilRecursion, true);
      expect(e.useGroupScoring, true);
    });

    test('parses the native ST characterFilter map', () {
      final result = importSTLorebook({
        'entries': {
          '0': {
            'uid': 0,
            'key': ['k'],
            'content': 'c',
            'characterFilter': {
              'isExclude': true,
              'names': ['Nova', 'Rex'],
              'tags': <String>[],
            },
          },
        },
      });
      final e = result.lorebook.entries.single;
      expect(e.characterFilter?.names, ['Nova', 'Rex']);
      expect(e.characterFilter?.isExclude, true);
    });

    test('prefers glazeMetadata for the canonical position string', () {
      final result = importSTLorebook({
        'entries': {
          '0': {
            'uid': 0,
            'key': ['k'],
            'content': 'c',
            'position': 1,
            'glazeMetadata': {'position': 'lorebooksMacro'},
          },
        },
      });
      expect(result.lorebook.entries.single.position, 'lorebooksMacro');
    });
  });
}
