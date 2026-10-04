import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/folder_repo.dart';
import 'package:glaze_flutter/core/db/repositories/preset_folder_repo.dart';
import 'package:glaze_flutter/core/models/folder.dart';
import 'package:glaze_flutter/core/models/preset_folder.dart';
import 'package:glaze_flutter/features/cloud_sync/adapters/folder_sync_store.dart';

void main() {
  late AppDatabase source;
  late AppDatabase target;
  late FolderSyncStore store;

  setUp(() {
    source = AppDatabase.forTesting(NativeDatabase.memory());
    target = AppDatabase.forTesting(NativeDatabase.memory());
    store = FolderSyncStore(
      source,
      FolderRepo(source),
      PresetFolderRepo(source),
    );
  });

  tearDown(() async {
    await source.close();
    await target.close();
  });

  test('generic and preset folders round-trip through applyAll', () async {
    final genericFolders = FolderRepo(source);
    final lorebook = await genericFolders.create(
      domain: FolderDomain.lorebook,
      name: 'Worlds',
    );
    final persona = await genericFolders.create(
      domain: FolderDomain.persona,
      name: 'Mains',
    );
    await genericFolders.addMember(lorebook.id, 'book-1');
    await genericFolders.addMember(lorebook.id, 'book-2');
    await genericFolders.addMember(persona.id, 'persona-1');

    final presetFolders = PresetFolderRepo(source);
    final chat = await presetFolders.create(name: 'Chat');
    final agentic = await presetFolders.create(name: 'Agentic');
    await presetFolders.addMember(chat.id, 'p1', PresetKind.normal);
    await presetFolders.addMember(agentic.id, 'p2', PresetKind.agentic);

    final payload = await store.getAll();

    await FolderSyncStore(
      target,
      FolderRepo(target),
      PresetFolderRepo(target),
    ).applyAll(payload);

    final targetGeneric = FolderRepo(target);
    final folders = await targetGeneric.getAllFolders();
    expect(folders.map((f) => '${f.domain.wireName}:${f.name}').toSet(), {
      'lorebook:Worlds',
      'persona:Mains',
    });

    final members = await targetGeneric.getAllMembers();
    expect(members.map((m) => m.memberId).toSet(), {
      'book-1',
      'book-2',
      'persona-1',
    });

    final targetPreset = PresetFolderRepo(target);
    final presetNames = (await targetPreset.getFolders())
        .map((f) => f.name)
        .toSet();
    expect(presetNames, {'Chat', 'Agentic'});

    final presetMembers = await targetPreset.getAllMembers();
    expect(presetMembers.map((m) => '${m.kind}:${m.presetId}').toSet(), {
      'normal:p1',
      'agentic:p2',
    });
  });

  test('applyAll replaces the local collections wholesale', () async {
    final targetStore = FolderSyncStore(
      target,
      FolderRepo(target),
      PresetFolderRepo(target),
    );
    await FolderRepo(target).create(
      domain: FolderDomain.regex,
      name: 'Stale',
    );

    await targetStore.applyAll(await store.getAll());

    expect(await FolderRepo(target).getAllFolders(), isEmpty);
    expect(await PresetFolderRepo(target).getFolders(), isEmpty);
  });
}
