import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/features/presets/preset_entry.dart';
import 'package:glaze_flutter/features/presets/preset_sort.dart';

PresetItem _plain(String id, String name, int createdAt) =>
    PresetItem(preset: Preset(id: id, name: name, createdAt: createdAt));

PresetItem _agentic(String id, String name, {int updatedAt = 0}) =>
    PresetItem(studioPreset: StudioPreset(id: id, name: name, updatedAt: updatedAt));

List<String> _ids(List<PresetItem> items) => [for (final e in items) e.id];

void main() {
  group('sortPresetItems', () {
    final items = <PresetItem>[
      _plain('b', 'beta', 30),
      _plain('c', 'Alpha', 10),
      _agentic('studio_20', 'gamma'),
    ];

    test('alphabetical ignores case and covers both kinds', () {
      final sorted = sortPresetItems(
        items,
        const PresetSortState(mode: PresetSortMode.alphabetical),
      );
      expect(_ids(sorted), ['c', 'b', 'studio_20']);
    });

    test('date added is newest first, agentic stamps read from the id', () {
      final sorted = sortPresetItems(
        items,
        const PresetSortState(mode: PresetSortMode.dateAdded),
      );
      expect(_ids(sorted), ['b', 'studio_20', 'c']);
    });

    test('manual follows the stored order, unknown presets keep theirs', () {
      final sorted = sortPresetItems(
        items,
        const PresetSortState(
          mode: PresetSortMode.manual,
          manualOrder: ['agentic:studio_20'],
        ),
      );
      // The listed one leads; 'b' and 'c' stay in the order they came in.
      expect(_ids(sorted), ['studio_20', 'b', 'c']);
    });

    test('an empty manual order leaves the incoming order untouched', () {
      final sorted = sortPresetItems(items, const PresetSortState());
      expect(_ids(sorted), ['b', 'c', 'studio_20']);
    });

    test('a stale manual order ignores presets that no longer exist', () {
      final sorted = sortPresetItems(
        items,
        const PresetSortState(
          mode: PresetSortMode.manual,
          manualOrder: ['normal:gone', 'normal:c', 'normal:b'],
        ),
      );
      expect(_ids(sorted), ['c', 'b', 'studio_20']);
    });
  });
}
