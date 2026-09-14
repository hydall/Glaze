import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/lorebook_limits.dart';
import 'package:glaze_flutter/core/llm/lorebook_merger.dart';
import 'package:glaze_flutter/core/llm/lorebook_scanner.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';

ScannedEntry _scanned(
  String id, {
  bool constant = false,
  bool ignoreBudget = false,
  int? bookCap,
  String book = 'book',
}) => ScannedEntry(
  id: id,
  comment: 'entry $id',
  content: 'content $id',
  position: 'before',
  order: 0,
  lorebookName: book,
  lorebookId: book,
  constant: constant,
  maxInjectedEntries: bookCap,
  ignoreBudget: ignoreBudget,
);

List<ScannedEntry> _scan(
  Lorebook book, {
  String message = 'we ride to the castle at dawn',
}) => scanLorebooks(
  history: [ChatMessage(id: 'm1', role: 'user', content: message)],
  char: null,
  textToScan: message,
  chatId: null,
  lorebooks: [book],
  globalSettings: const LorebookGlobalSettings(),
  activations: const LorebookActivations(),
);

void main() {
  group('resolveGlobalEntryCap', () {
    test('keeps a value the settings screen could have produced', () {
      expect(
        resolveGlobalEntryCap(const LorebookGlobalSettings(
          maxInjectedEntries: 7,
        )),
        7,
      );
    });

    test('clamps a value a restore or a sync payload could smuggle in', () {
      expect(
        resolveGlobalEntryCap(const LorebookGlobalSettings(
          maxInjectedEntries: 0,
        )),
        1,
      );
      expect(
        resolveGlobalEntryCap(const LorebookGlobalSettings(
          maxInjectedEntries: -4,
        )),
        1,
      );
      expect(
        resolveGlobalEntryCap(const LorebookGlobalSettings(
          maxInjectedEntries: 5000,
        )),
        100,
      );
    });
  });

  group('resolvePerBookEntryCap', () {
    test('zero and below mean "defer to the global cap", not "inject none"', () {
      expect(resolvePerBookEntryCap(null), isNull);
      expect(resolvePerBookEntryCap(0), isNull);
      expect(resolvePerBookEntryCap(-2), isNull);
    });

    test('a real cap is passed through', () {
      expect(resolvePerBookEntryCap(3), 3);
    });
  });

  group('scanLorebooks per-book cap', () {
    test('a stored zero does not empty the book', () {
      final result = _scan(
        const Lorebook(
          id: 'book',
          name: 'Book',
          settings: LorebookSettings(maxInjectedEntries: 0),
          entries: [
            LorebookEntry(id: 'a', keys: ['castle'], order: 1, content: 'A'),
            LorebookEntry(id: 'b', keys: ['castle'], order: 2, content: 'B'),
            LorebookEntry(id: 'c', keys: ['castle'], order: 3, content: 'C'),
          ],
        ),
      );

      expect(result.map((e) => e.id), ['a', 'b', 'c']);
    });

    test('a real cap still cuts', () {
      final result = _scan(
        const Lorebook(
          id: 'book',
          name: 'Book',
          settings: LorebookSettings(maxInjectedEntries: 2),
          entries: [
            LorebookEntry(id: 'a', keys: ['castle'], order: 1, content: 'A'),
            LorebookEntry(id: 'b', keys: ['castle'], order: 2, content: 'B'),
            LorebookEntry(id: 'c', keys: ['castle'], order: 3, content: 'C'),
          ],
        ),
      );

      expect(result.map((e) => e.id), ['a', 'b']);
    });
  });

  group('mergeKeywordVector budget', () {
    test('an out-of-range global cap is clamped, not passed through', () {
      final result = mergeKeywordVector(
        keywordEntries: [_scanned('t0'), _scanned('t1'), _scanned('t2')],
        vectorEntries: const [],
        settings: const LorebookGlobalSettings(maxInjectedEntries: 0),
      );

      // Clamped to the minimum the settings screen allows, so one entry gets
      // through rather than none.
      expect(result.map((e) => e.id), ['t0']);
    });

    test('ignoreBudget survives the global cap and spends no slot', () {
      final result = mergeKeywordVector(
        keywordEntries: [
          _scanned('t0'),
          _scanned('free1', ignoreBudget: true),
          _scanned('free2', ignoreBudget: true),
          _scanned('t1'),
        ],
        vectorEntries: const [],
        settings: const LorebookGlobalSettings(maxInjectedEntries: 1),
      );

      // t0 takes the single slot; both exempt entries ride along; t1 is cut.
      expect(result.map((e) => e.id), ['t0', 'free1', 'free2']);
    });

    test('ignoreBudget survives a per-book cap', () {
      final result = mergeKeywordVector(
        keywordEntries: [
          _scanned('a', bookCap: 1),
          _scanned('free', bookCap: 1, ignoreBudget: true),
          _scanned('c', bookCap: 1),
        ],
        vectorEntries: const [],
        settings: const LorebookGlobalSettings(maxInjectedEntries: 10),
      );

      expect(result.map((e) => e.id), ['a', 'free']);
    });

    test('a constant that ignores the budget leaves the slots alone', () {
      final result = mergeKeywordVector(
        keywordEntries: [
          _scanned('c0', constant: true, ignoreBudget: true),
          _scanned('c1', constant: true, ignoreBudget: true),
          _scanned('t0'),
          _scanned('t1'),
        ],
        vectorEntries: const [],
        settings: const LorebookGlobalSettings(maxInjectedEntries: 2),
      );

      // Both constants are exempt, so the 2 slots still go to the triggered
      // entries rather than being eaten by the constants.
      expect(result.map((e) => e.id), ['c0', 'c1', 't0', 't1']);
    });

    test('a vector entry that ignores the budget outlives vectorTopK', () {
      final result = mergeKeywordVector(
        keywordEntries: const [],
        vectorEntries: const [
          LorebookEntry(id: 'v0', content: 'v0'),
          LorebookEntry(id: 'v1', content: 'v1'),
          LorebookEntry(id: 'free', content: 'free', ignoreBudget: true),
        ],
        settings: const LorebookGlobalSettings(
          maxInjectedEntries: 10,
          vectorTopK: 1,
        ),
      );

      expect(result.map((e) => e.id), ['v0', 'free']);
    });
  });
}
