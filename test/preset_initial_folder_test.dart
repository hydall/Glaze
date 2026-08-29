import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/preset_folder.dart';
import 'package:glaze_flutter/core/state/preset_folder_provider.dart';
import 'package:glaze_flutter/features/presets/preset_initial_folder.dart';

void main() {
  PresetFolder folder(String id) => PresetFolder(id: id, name: id);

  PresetFolderMemberships membershipsOf(Map<String, List<String>> byFolder) {
    final folders = <String, Set<String>>{};
    final presets = <String, Set<String>>{};
    byFolder.forEach((folderId, keys) {
      folders[folderId] = keys.toSet();
      for (final key in keys) {
        (presets[key] ??= <String>{}).add(folderId);
      }
    });
    return PresetFolderMemberships(byFolder: folders, byPreset: presets);
  }

  test('a preset that is in no folder opens the top level', () {
    final folderId = initialPresetFolderId(
      activeId: 'p1',
      kind: PresetKind.normal,
      memberships: membershipsOf({
        'f1': [presetMemberKey('p2', PresetKind.normal)],
      }),
      folders: [folder('f1')],
    );

    expect(folderId, isNull);
  });

  test('no active preset opens the top level', () {
    final folderId = initialPresetFolderId(
      activeId: null,
      kind: PresetKind.normal,
      memberships: membershipsOf({
        'f1': [presetMemberKey('p1', PresetKind.normal)],
      }),
      folders: [folder('f1')],
    );

    expect(folderId, isNull);
  });

  test('the folder holding the active preset is opened', () {
    final folderId = initialPresetFolderId(
      activeId: 'p1',
      kind: PresetKind.normal,
      memberships: membershipsOf({
        'f1': [presetMemberKey('p2', PresetKind.normal)],
        'f2': [presetMemberKey('p1', PresetKind.normal)],
      }),
      folders: [folder('f1'), folder('f2')],
    );

    expect(folderId, 'f2');
  });

  test('an agentic preset never matches a chat preset with the same id', () {
    final memberships = membershipsOf({
      'f1': [presetMemberKey('same', PresetKind.agentic)],
    });

    expect(
      initialPresetFolderId(
        activeId: 'same',
        kind: PresetKind.normal,
        memberships: memberships,
        folders: [folder('f1')],
      ),
      isNull,
    );
    expect(
      initialPresetFolderId(
        activeId: 'same',
        kind: PresetKind.agentic,
        memberships: memberships,
        folders: [folder('f1')],
      ),
      'f1',
    );
  });

  test('a preset filed into several folders opens the first listed one', () {
    final memberships = membershipsOf({
      'f2': [presetMemberKey('p1', PresetKind.normal)],
      'f1': [presetMemberKey('p1', PresetKind.normal)],
    });

    // `folders` arrives in the order the folder section renders it, so the
    // choice is the folder the user sees first — not whichever membership row
    // happened to be written first.
    expect(
      initialPresetFolderId(
        activeId: 'p1',
        kind: PresetKind.normal,
        memberships: memberships,
        folders: [folder('f1'), folder('f2')],
      ),
      'f1',
    );
    expect(
      initialPresetFolderId(
        activeId: 'p1',
        kind: PresetKind.normal,
        memberships: memberships,
        folders: [folder('f2'), folder('f1')],
      ),
      'f2',
    );
  });

  test('a membership pointing at a deleted folder opens the top level', () {
    final folderId = initialPresetFolderId(
      activeId: 'p1',
      kind: PresetKind.normal,
      memberships: membershipsOf({
        'gone': [presetMemberKey('p1', PresetKind.normal)],
      }),
      folders: [folder('f1')],
    );

    expect(folderId, isNull);
  });
}
