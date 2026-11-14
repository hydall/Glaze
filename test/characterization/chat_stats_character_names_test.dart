import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regression guard for the two statistics bugs where the sheet had no
/// character data to render:
///
///  * the Chat picker printed raw character ids instead of names, and
///  * the Character picker showed "—" with an empty dropdown.
///
/// Both came from seeding `_allCharacters` with
/// `ref.read(charactersProvider).value ?? []`: `charactersProvider` is an
/// `AsyncNotifier`, so a sheet opened before it was warmed reads `AsyncLoading`
/// (no value) and keeps an empty list for its whole lifetime. Characters are now
/// read from the repository, awaited like the sessions next to them.
void main() {
  final source =
      File('lib/features/chat/widgets/chat_stats_sheet.dart').readAsStringSync();

  group('ChatStatsSheet character data', () {
    test('characters are awaited from the repo, not a maybe-loading provider',
        () {
      expect(
        source.contains('await ref.read(characterRepoProvider).getAll()'),
        isTrue,
        reason: 'the sheet must load characters from the repository',
      );
      expect(
        source.contains('ref.read(charactersProvider)'),
        isFalse,
        reason:
            'reading charactersProvider without awaiting it yields an empty '
            'list when the provider has not been built yet',
      );
    });

    test('session labels never fall back to the raw character id', () {
      expect(
        source.contains('char?.name ?? s.characterId'),
        isFalse,
        reason: 'an orphaned session must show a placeholder, not an id',
      );
    });

    test('character dropdown renders an empty state', () {
      expect(source.contains('No characters yet'), isTrue);
    });
  });
}
