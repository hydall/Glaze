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

  group('sortRegexScripts', () {
    final scripts = [
      _script('1', name: 'beta'),
      _script('2', name: 'Alpha'),
      _script('3', name: 'gamma'),
    ];

    test('manual is the run order, even with a stored manual order', () {
      final sorted = sortRegexScripts(
        scripts,
        const PresetSortState(manualOrder: ['3', '1', '2']),
      );
      expect(sorted.map((s) => s.id), ['1', '2', '3']);
    });

    test('alphabetical ignores case', () {
      final sorted = sortRegexScripts(
        scripts,
        const PresetSortState(mode: PresetSortMode.alphabetical),
      );
      expect(sorted.map((s) => s.name), ['Alpha', 'beta', 'gamma']);
    });

    test('date added puts the last appended first', () {
      final sorted = sortRegexScripts(
        scripts,
        const PresetSortState(mode: PresetSortMode.dateAdded),
      );
      expect(sorted.map((s) => s.id), ['3', '2', '1']);
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
