import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/import/st_lorebook_importer.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/services/st_lorebook_exporter.dart';

/// #135: per-book lorebook settings did not survive an ST import or a
/// Glaze → ST → Glaze round trip, and the two tri-state entry flags came back
/// pinned to false.
void main() {
  Lorebook book({
    LorebookSettings? settings,
    String description = '',
    List<LorebookEntry> entries = const [],
  }) => Lorebook(
    id: 'lb-1',
    name: 'Kestrel Bay',
    settings: settings,
    description: description,
    entries: entries,
  );

  group('#135 — the book keeps its own settings', () {
    test('a round trip brings back everything the book was tuned to', () {
      const settings = LorebookSettings(
        scanDepth: 7,
        maxInjectedEntries: 3,
        contextPercent: 42,
        budgetCap: 1200,
        insertionStrategy: 'lorebook_first',
        injectionPosition: 'worldInfoBefore',
        recursiveScan: true,
        searchType: 'vector',
        vectorThreshold: 0.61,
        vectorTopK: 4,
      );

      final restored = importSTLorebook(
        glazeLorebookToSTJson(book(settings: settings)),
      ).lorebook;

      expect(restored.settings, isNotNull);
      expect(restored.settings!.scanDepth, 7);
      expect(restored.settings!.maxInjectedEntries, 3);
      expect(restored.settings!.contextPercent, 42);
      expect(restored.settings!.budgetCap, 1200);
      expect(restored.settings!.insertionStrategy, 'lorebook_first');
      expect(restored.settings!.injectionPosition, 'worldInfoBefore');
      expect(restored.settings!.recursiveScan, isTrue);
      expect(restored.settings!.searchType, 'vector');
      expect(restored.settings!.vectorThreshold, 0.61);
      expect(restored.settings!.vectorTopK, 4);
    });

    test('the description comes back with it', () {
      final restored = importSTLorebook(
        glazeLorebookToSTJson(book(description: 'notes for the reader')),
      ).lorebook;
      expect(restored.description, 'notes for the reader');
    });

    test('a book that was never tuned exports nothing to restore', () {
      final json = glazeLorebookToSTJson(book());
      expect((json['glazeMetadata'] as Map)['settings'], isNull);

      final restored = importSTLorebook(json).lorebook;
      expect(restored.settings, isNull);
      expect(restored.description, '');
    });

    test("a SillyTavern book keeps Glaze's defaults, not invented ones", () {
      // No glazeMetadata at all: the file did not come from here, and making
      // settings up for it would be worse than leaving it on the defaults.
      final restored = importSTLorebook({
        'name': 'From ST',
        'entries': <String, dynamic>{},
      }).lorebook;
      expect(restored.settings, isNull);
      expect(restored.description, '');
    });

    test('settings that no longer parse cost the tuning, not the import', () {
      final restored = importSTLorebook({
        'name': 'Kestrel Bay',
        'entries': {
          '0': {'key': <String>['tide'], 'content': 'the tide is out'},
        },
        'glazeMetadata': {'settings': 'not a settings object'},
      }).lorebook;
      expect(restored.settings, isNull);
      expect(restored.entries, hasLength(1), reason: 'the entries still land');
    });

    test('the export is still a SillyTavern book', () {
      final json = glazeLorebookToSTJson(
        book(
          settings: const LorebookSettings(scanDepth: 7),
          entries: [
            const LorebookEntry(id: 'e1', keys: ['tide'], content: 'out'),
          ],
        ),
      );
      expect(json['name'], 'Kestrel Bay');
      expect(json['entries'], isA<Map<String, dynamic>>());
      final entry = (json['entries'] as Map)['0'] as Map;
      expect(entry['key'], ['tide']);
      expect(entry['content'], 'out');
    });
  });

  group('#135 — the tri-state entry flags stay three-state', () {
    /// `entry.caseSensitive ?? book ?? global` is how `LorebookScanner`
    /// resolves them, so null is a value with a meaning: follow the setting the
    /// reader chose. Defaulting it to false turned "inherit" into "never".
    LorebookEntry entryFrom(Map<String, dynamic> raw) =>
        importSTLorebook({
          'name': 'b',
          'entries': {'0': raw},
        }).lorebook.entries.single;

    test('an entry that says nothing still inherits', () {
      final entry = entryFrom({'key': <String>['tide'], 'content': 'x'});
      expect(entry.caseSensitive, isNull);
      expect(entry.matchWholeWords, isNull);
    });

    test('an explicit false is kept as an explicit false', () {
      final entry = entryFrom({
        'key': <String>['tide'],
        'content': 'x',
        'caseSensitive': false,
        'matchWholeWords': false,
      });
      expect(entry.caseSensitive, isFalse);
      expect(entry.matchWholeWords, isFalse);
    });

    test('an explicit true survives', () {
      final entry = entryFrom({
        'key': <String>['tide'],
        'content': 'x',
        'caseSensitive': true,
        'matchWholeWords': true,
      });
      expect(entry.caseSensitive, isTrue);
      expect(entry.matchWholeWords, isTrue);
    });

    test('all three states survive a round trip', () {
      final exported = glazeLorebookToSTJson(
        book(
          entries: const [
            LorebookEntry(id: 'a', keys: ['a'], content: 'a'),
            LorebookEntry(
              id: 'b',
              keys: ['b'],
              content: 'b',
              caseSensitive: true,
              matchWholeWords: true,
            ),
            LorebookEntry(
              id: 'c',
              keys: ['c'],
              content: 'c',
              caseSensitive: false,
              matchWholeWords: false,
            ),
          ],
        ),
      );
      final entries = importSTLorebook(exported).lorebook.entries;

      expect(entries[0].caseSensitive, isNull);
      expect(entries[0].matchWholeWords, isNull);
      expect(entries[1].caseSensitive, isTrue);
      expect(entries[1].matchWholeWords, isTrue);
      expect(entries[2].caseSensitive, isFalse);
      expect(entries[2].matchWholeWords, isFalse);
    });
  });
}
