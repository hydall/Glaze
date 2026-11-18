import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/preset_folder.dart';
import 'package:glaze_flutter/core/state/preset_folder_provider.dart';
import 'package:glaze_flutter/features/presets/preset_entry.dart';

PresetFolder _folder(String id) =>
    PresetFolder(id: id, name: id, createdAt: 0, sortOrder: 0);

PresetFolderMemberships _memberships(Map<String, List<String>> byFolder) {
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

void main() {
  group('initialPresetFolderId', () {
    final folders = [_folder('f1'), _folder('f2')];

    test('opens on the folder the active preset lives in', () {
      final id = initialPresetFolderId(
        activeId: 'p1',
        kind: PresetKind.normal,
        folders: folders,
        memberships: _memberships({
          'f2': [presetMemberKey('p1', PresetKind.normal)],
        }),
      );

      expect(id, 'f2');
    });

    test('stays at the top level when the active preset is in no folder', () {
      final id = initialPresetFolderId(
        activeId: 'p1',
        kind: PresetKind.normal,
        folders: folders,
        memberships: PresetFolderMemberships.empty,
      );

      expect(id, isNull);
    });

    test('the two kinds never read each other membership', () {
      // Plain and Studio ids can collide, which is why membership is keyed by
      // kind — an agentic preset must not open the folder of the plain one
      // that happens to share its id.
      final memberships = _memberships({
        'f1': [presetMemberKey('shared', PresetKind.normal)],
      });

      expect(
        initialPresetFolderId(
          activeId: 'shared',
          kind: PresetKind.agentic,
          folders: folders,
          memberships: memberships,
        ),
        isNull,
      );
      expect(
        initialPresetFolderId(
          activeId: 'shared',
          kind: PresetKind.normal,
          folders: folders,
          memberships: memberships,
        ),
        'f1',
      );
    });

    test('a preset in several folders always opens the same one', () {
      final memberships = _memberships({
        'f2': [presetMemberKey('p1', PresetKind.normal)],
        'f1': [presetMemberKey('p1', PresetKind.normal)],
      });

      // Folder-list order decides, not the (unordered) membership set.
      expect(
        initialPresetFolderId(
          activeId: 'p1',
          kind: PresetKind.normal,
          folders: folders,
          memberships: memberships,
        ),
        'f1',
      );
    });

    test('no active preset means no folder', () {
      expect(
        initialPresetFolderId(
          activeId: null,
          kind: PresetKind.normal,
          folders: folders,
          memberships: _memberships({
            'f1': [presetMemberKey('p1', PresetKind.normal)],
          }),
        ),
        isNull,
      );
    });
  });
}
