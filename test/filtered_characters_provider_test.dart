import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/state/character_provider.dart';
import 'package:glaze_flutter/features/character_list/character_sort.dart';
import 'package:glaze_flutter/features/character_list/filtered_characters_provider.dart';

import 'helpers/test_container.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() async => db.close());

  test('favorites do not bypass text search', () async {
    final repo = CharacterRepo(db);
    await repo.put(const Character(id: 'fav', name: 'Alice', fav: true));
    await repo.put(const Character(id: 'match', name: 'Bob Builder'));

    final container = makeContainer(db);
    addTearDown(container.dispose);
    await container.read(charactersProvider.future);

    const query = CharacterQuery(
      search: 'builder',
      favOnly: false,
      tags: [],
      minTokens: 0,
      maxTokens: 0,
      hasTokenFilter: false,
      sortBy: SortType.name,
      sortDir: SortDir.asc,
    );

    expect(
      container.read(filteredCharactersProvider(query)).map((c) => c.id),
      ['match'],
    );
  });

  test('favorites still sort first and favOnly remains independent', () async {
    final repo = CharacterRepo(db);
    await repo.put(const Character(id: 'plain', name: 'Alpha'));
    await repo.put(const Character(id: 'fav', name: 'Zulu', fav: true));

    final container = makeContainer(db);
    addTearDown(container.dispose);
    await container.read(charactersProvider.future);

    const all = CharacterQuery(
      search: '',
      favOnly: false,
      tags: [],
      minTokens: 0,
      maxTokens: 0,
      hasTokenFilter: false,
      sortBy: SortType.name,
      sortDir: SortDir.asc,
    );
    const favorites = CharacterQuery(
      search: '',
      favOnly: true,
      tags: [],
      minTokens: 0,
      maxTokens: 0,
      hasTokenFilter: false,
      sortBy: SortType.name,
      sortDir: SortDir.asc,
    );

    expect(
      container.read(filteredCharactersProvider(all)).map((c) => c.id),
      ['fav', 'plain'],
    );
    expect(
      container.read(filteredCharactersProvider(favorites)).map((c) => c.id),
      ['fav'],
    );
  });
}
