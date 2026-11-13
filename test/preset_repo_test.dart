import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/preset_repo.dart';
import 'package:glaze_flutter/core/models/preset.dart';

/// A preset library is decoded in another isolate once it is big, and the
/// repair of a row that does not round-trip still lands.
void main() {
  late AppDatabase db;
  late PresetRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = PresetRepo(db);
  });

  tearDown(() => db.close());

  Preset preset(String id, {int blocks = 1, int chars = 10}) => Preset(
    id: id,
    name: 'Preset $id',
    blocks: [
      for (var i = 0; i < blocks; i++)
        PresetBlock(
          id: '$id-$i',
          name: 'Block $i',
          role: 'system',
          content: 'x' * chars,
        ),
    ],
  );

  test('a small library round-trips', () async {
    await repo.put(preset('a'));
    await repo.put(preset('b', blocks: 2));

    final all = await repo.getAll();

    expect(all.map((p) => p.id).toSet(), {'a', 'b'});
    expect(all.firstWhere((p) => p.id == 'b').blocks, hasLength(2));
  });

  test('a big library round-trips through the other isolate', () async {
    // Past the off-thread threshold: 3 × 200 KB.
    for (final id in ['a', 'b', 'c']) {
      await repo.put(preset(id, blocks: 4, chars: 50 * 1024));
    }

    final all = await repo.getAll();

    expect(all, hasLength(3));
    expect(all.first.blocks.first.content.length, 50 * 1024);
    expect(all, await repo.getAll());
  });

  test('a row that does not round-trip is repaired on read', () async {
    await repo.put(preset('a'));
    // Hand-written JSON with the keys in another order: the model is the
    // same, the stored string is not.
    await db.customStatement(
      "UPDATE presets SET data_json = "
      "'{\"name\":\"Preset a\",\"id\":\"a\",\"blocks\":[]}' "
      "WHERE preset_id = 'a'",
    );

    final all = await repo.getAll();
    final stored = await (db.select(db.presets)).get();

    expect(all.single.id, 'a');
    expect(stored.single.dataJson, startsWith('{"id":"a"'));
  });
}
