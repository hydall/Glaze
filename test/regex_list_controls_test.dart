import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/regex/regex_list_controls.dart';

PresetRegex _script(
  String id, {
  String? name,
  bool disabled = false,
  List<int> placement = const [1, 2],
}) => PresetRegex(
  id: id,
  name: name ?? id,
  regex: '',
  disabled: disabled,
  placement: placement,
);

void main() {
  group('reanchorOrder', () {
    test('moves a row within an unfiltered list', () {
      expect(reanchorOrder(['a', 'b', 'c'], ['a', 'b', 'c'], 0, 2), [
        'b',
        'c',
        'a',
      ]);
      expect(reanchorOrder(['a', 'b', 'c'], ['a', 'b', 'c'], 2, 0), [
        'c',
        'a',
        'b',
      ]);
    });

    test('keeps rows hidden from view where they were', () {
      // x and y are filed in a folder (or filtered out) and not on screen.
      final full = ['a', 'x', 'b', 'y', 'c'];
      // c lands right after a, the row it now follows.
      expect(reanchorOrder(full, ['a', 'b', 'c'], 2, 1), [
        'a',
        'c',
        'x',
        'b',
        'y',
      ]);
      expect(reanchorOrder(full, ['a', 'b', 'c'], 2, 0), [
        'c',
        'a',
        'x',
        'b',
        'y',
      ]);
    });

    test('leaves the order alone when nothing moved', () {
      expect(reanchorOrder(['a', 'b'], ['a', 'b'], 1, 1), ['a', 'b']);
    });
  });

  group('preset folders', () {
    final preset = Preset(
      id: 'p',
      name: 'P',
      regexFolders: const [PresetRegexFolder(id: 'f1', name: 'Format')],
      regexes: [
        _script('a'),
        _script('b').copyWith(folderId: 'f1'),
        _script('c').copyWith(folderId: 'gone'),
        _script('d').copyWith(folderId: 'f1'),
      ],
    );

    test('the top level holds unfiled scripts and dangling references', () {
      expect(presetScriptsIn(preset, null).map((r) => r.id), ['a', 'c']);
      expect(presetScriptsIn(preset, 'f1').map((r) => r.id), ['b', 'd']);
    });

    test('moving scripts keeps their run order', () {
      final moved = movePresetScripts(preset, {'a', 'd'}, null);
      expect(moved.regexes.map((r) => r.id), ['a', 'b', 'c', 'd']);
      expect(presetScriptsIn(moved, 'f1').map((r) => r.id), ['b']);
    });

    test('deleting a folder sends its scripts to the top level', () {
      final left = deletePresetRegexFolder(preset, 'f1');
      expect(left.regexFolders, isEmpty);
      expect(left.regexes.where((r) => r.folderId == 'f1'), isEmpty);
      expect(left.regexes.map((r) => r.id), ['a', 'b', 'c', 'd']);
    });
  });

  group('RegexListFilters', () {
    test('no filter matches everything and counts nothing', () {
      const filters = RegexListFilters();
      expect(filters.isActive, isFalse);
      expect(filters.matches(_script('a', disabled: true)), isTrue);
    });

    test('status narrows to enabled or disabled scripts', () {
      const enabled = RegexListFilters(enabledOnly: true);
      const disabled = RegexListFilters(disabledOnly: true);
      expect(enabled.matches(_script('a')), isTrue);
      expect(enabled.matches(_script('b', disabled: true)), isFalse);
      expect(disabled.matches(_script('a')), isFalse);
      expect(disabled.matches(_script('b', disabled: true)), isTrue);
    });

    test('placements match a script that affects any of them', () {
      const filters = RegexListFilters(placements: {5, 6});
      expect(filters.activeCount, 2);
      expect(filters.matches(_script('a', placement: const [1, 2])), isFalse);
      expect(filters.matches(_script('b', placement: const [2, 6])), isTrue);
    });
  });
}
