import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/preset_folder.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/state/preset_folder_provider.dart';
import 'package:glaze_flutter/features/presets/preset_entry.dart';
import 'package:glaze_flutter/features/presets/preset_sort.dart';

Preset _plain(String id, int createdAt) =>
    Preset(id: id, name: id, createdAt: createdAt);

StudioPreset _agentic(String id, {int updatedAt = 0}) =>
    StudioPreset(id: id, name: id, updatedAt: updatedAt);

List<String> _ids(List<PresetItem> items) => [for (final e in items) e.id];

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
  group('mergePresetItems', () {
    test('agentic presets interleave by age instead of trailing every plain '
        'one', () {
      final merged = mergePresetItems([
        _plain('old', 10),
        _plain('new', 30),
      ], [_agentic('studio_20')]);

      expect(_ids(merged), ['old', 'studio_20', 'new']);
    });

    test('each store keeps its own order when its stamps do not ascend', () {
      // The plain list carries a legacy manual order of its own, so its
      // timestamps can run backwards. A merge must interleave, never re-sort.
      final merged = mergePresetItems([
        _plain('a', 100),
        _plain('b', 1),
        _plain('c', 50),
      ], [_agentic('studio_200')]);

      expect(_ids(merged).where((id) => id != 'studio_200').toList(), [
        'a',
        'b',
        'c',
      ]);
    });

    test('an equal stamp leaves the plain preset in front', () {
      final merged = mergePresetItems([
        _plain('p', 40),
      ], [_agentic('studio_40')]);

      expect(_ids(merged), ['p', 'studio_40']);
    });

    test('either store being empty is the other one unchanged', () {
      expect(_ids(mergePresetItems([_plain('p', 1)], const [])), ['p']);
      expect(_ids(mergePresetItems(const [], [_agentic('studio_1')])), [
        'studio_1',
      ]);
    });

    test('the built-in agentic preset leads instead of sinking to the '
        'bottom', () {
      // `default` is seeded at install and re-stamped on every save, so reading
      // its updatedAt as a creation time pinned it below every plain preset —
      // and floated it to the top of "newest first" whenever it was edited.
      final merged = mergePresetItems([
        _plain('featured', 1),
      ], [_agentic('default', updatedAt: 9999)]);

      expect(_ids(merged), ['default', 'featured']);
    });

    test('the merged order survives a manual sort nobody has dragged yet', () {
      // The regression this whole helper exists for: the manual mode ranks only
      // the rows the user dragged and leaves the rest in the incoming order.
      final merged = mergePresetItems([
        _plain('old', 10),
        _plain('new', 30),
      ], [_agentic('studio_20')]);

      expect(_ids(sortPresetItems(merged, const PresetSortState())), [
        'old',
        'studio_20',
        'new',
      ]);
    });
  });

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
