import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/lorebook_merger.dart';
import 'package:glaze_flutter/core/llm/lorebook_scanner.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';

ScannedEntry _scanned({
  required String id,
  bool constant = false,
}) =>
    ScannedEntry(
      id: id,
      comment: 'entry $id',
      content: 'content $id',
      position: 'before',
      order: 0,
      lorebookName: 'book',
      lorebookId: 'book',
      constant: constant,
    );

LorebookEntry _vectorEntry(String id) => LorebookEntry(
      id: id,
      comment: 'vector $id',
      content: 'vector content $id',
      position: 'before',
    );

void main() {
  group('mergeKeywordVector constant overflow', () {
    test(
      'does not throw when constant entries exceed maxInjectedEntries',
      () {
        // Reproduces RangeError (end): Invalid value: Not greater than or
        // equal to 0: -53 from a world_info JSON with 58 constant entries
        // and the default maxInjectedEntries=5.
        final constants = [
          for (var i = 0; i < 58; i++) _scanned(id: 'c$i', constant: true),
        ];
        final triggered = [
          for (var i = 0; i < 3; i++) _scanned(id: 't$i', constant: false),
        ];
        final settings = const LorebookGlobalSettings(
          maxInjectedEntries: 5,
          vectorTopK: 10,
        );

        final result = mergeKeywordVector(
          keywordEntries: [...constants, ...triggered],
          vectorEntries: const [],
          settings: settings,
        );

        // All 58 constants are always in-budget by design; triggered
        // keywords are dropped because no slots remain.
        expect(result.length, 58);
        expect(result.map((e) => e.id).toSet(), contains('c0'));
        expect(result.map((e) => e.id).toSet(), contains('c57'));
        expect(result.any((e) => e.id.startsWith('t')), isFalse);
      },
    );

    test('still admits triggered keywords when constants fit the cap', () {
      final constants = [
        for (var i = 0; i < 3; i++) _scanned(id: 'c$i', constant: true),
      ];
      final triggered = [
        for (var i = 0; i < 5; i++) _scanned(id: 't$i', constant: false),
      ];
      final settings = const LorebookGlobalSettings(
        maxInjectedEntries: 5,
        vectorTopK: 10,
      );

      final result = mergeKeywordVector(
        keywordEntries: [...constants, ...triggered],
        vectorEntries: const [],
        settings: settings,
      );

      // 3 constants + 2 triggered (5 - 3 remaining slots).
      expect(result.length, 5);
      expect(result.map((e) => e.id).toSet(), contains('t0'));
      expect(result.map((e) => e.id).toSet(), contains('t1'));
      expect(result.any((e) => e.id == 't2'), isFalse);
    });

    test('drops vector entries when constants already exceed the cap', () {
      final constants = [
        for (var i = 0; i < 10; i++) _scanned(id: 'c$i', constant: true),
      ];
      final vectors = [
        for (var i = 0; i < 4; i++) _vectorEntry('v$i'),
      ];
      final settings = const LorebookGlobalSettings(
        maxInjectedEntries: 5,
        vectorTopK: 10,
      );

      final result = mergeKeywordVector(
        keywordEntries: constants,
        vectorEntries: vectors,
        settings: settings,
      );

      expect(result.length, 10);
      expect(result.any((e) => e.id.startsWith('v')), isFalse);
    });
  });
}
