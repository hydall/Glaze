import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';

void main() {
  test('stores Glaze avatar paths relative to the data root', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = CharacterRepo(db);

    await repo.put(
      const Character(
        id: 'relative-avatar',
        name: 'Portable',
        avatarPath:
            '/var/mobile/Containers/Data/Application/OLD/Documents/Glaze/avatars/portable.png',
      ),
    );

    final result = await repo.getById('relative-avatar');
    expect(result!.avatarPath, 'avatars/portable.png');
  });
}
