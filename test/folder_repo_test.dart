import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/folder_repo.dart';
import 'package:glaze_flutter/core/models/folder.dart';

void main() {
  late AppDatabase db;
  late FolderRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = FolderRepo(db);
  });

  tearDown(() => db.close());

  test('folders are isolated per domain', () async {
    final lorebook = await repo.create(
      domain: FolderDomain.lorebook,
      name: 'Worlds',
    );
    final persona = await repo.create(
      domain: FolderDomain.persona,
      name: 'Mains',
    );

    final lorebookFolders = await repo.getFolders(FolderDomain.lorebook);
    final personaFolders = await repo.getFolders(FolderDomain.persona);

    expect(lorebookFolders.map((f) => f.id), [lorebook.id]);
    expect(personaFolders.map((f) => f.id), [persona.id]);
  });

  test('membership is two-way and idempotent within a folder', () async {
    final folder = await repo.create(
      domain: FolderDomain.lorebook,
      name: 'Worlds',
    );

    await repo.addMember(folder.id, 'book-1');
    await repo.addMember(folder.id, 'book-1');
    await repo.addMember(folder.id, 'book-2');

    final rows = await repo.watchMembers(FolderDomain.lorebook).first;
    expect(rows.map((r) => r.memberId).toSet(), {'book-1', 'book-2'});

    await repo.removeMember(folder.id, 'book-1');
    final after = await repo.watchMembers(FolderDomain.lorebook).first;
    expect(after.map((r) => r.memberId).toSet(), {'book-2'});
  });

  test('deleting a member only clears it inside the given domain', () async {
    final lorebookFolder = await repo.create(
      domain: FolderDomain.lorebook,
      name: 'Worlds',
    );
    final personaFolder = await repo.create(
      domain: FolderDomain.persona,
      name: 'Mains',
    );
    // Same id in two domains — the row must survive the other domain's clear.
    await repo.addMember(lorebookFolder.id, 'shared-id');
    await repo.addMember(personaFolder.id, 'shared-id');

    await repo.deleteMembersForMember(FolderDomain.lorebook, 'shared-id');

    final lorebookRows = await repo.watchMembers(FolderDomain.lorebook).first;
    final personaRows = await repo.watchMembers(FolderDomain.persona).first;
    expect(lorebookRows, isEmpty);
    expect(personaRows.map((r) => r.memberId), ['shared-id']);
  });

  test('deleting a folder removes its membership rows only', () async {
    final folder = await repo.create(
      domain: FolderDomain.regex,
      name: 'Chat',
    );
    await repo.addMember(folder.id, 'script-1');

    await repo.delete(folder.id);

    expect(await repo.getFolders(FolderDomain.regex), isEmpty);
    final rows = await repo.watchMembers(FolderDomain.regex).first;
    expect(rows, isEmpty);
  });
}
