import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/state/character_provider.dart';

import 'helpers/test_container.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() async => db.close());

  test('new character variant starts its own session sequence', () async {
    const source = Character(
      id: 'source',
      name: 'Source',
      currentSessionIndex: 7,
      variantGroupId: 'source',
    );
    final repo = CharacterRepo(db);
    await repo.put(source);

    final container = makeContainer(db);
    addTearDown(container.dispose);
    await container.read(charactersProvider.future);

    final variant = await container
        .read(charactersProvider.notifier)
        .addVariant(source, 'Variant');

    expect(variant.currentSessionIndex, 0);
    expect((await repo.getById(variant.id))?.currentSessionIndex, 0);
  });
}
