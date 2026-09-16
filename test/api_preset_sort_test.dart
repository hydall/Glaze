import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/features/settings/api_preset_sort.dart';

ApiConfig _config(String id, {String name = '', String model = ''}) =>
    ApiConfig(id: id, name: name, model: model);

List<String> _ids(List<ApiConfig> configs) => [for (final c in configs) c.id];

void main() {
  group('sortApiConfigs', () {
    // '20' and '10' are millisecond ids, the shape a preset created in the app
    // gets; 'imported' is what an import brings — no stamp to read.
    final configs = <ApiConfig>[
      _config('20', name: 'beta'),
      _config('10', name: 'Alpha'),
      _config('imported', model: 'gamma-3'),
    ];

    test('alphabetical ignores case and falls back to the model', () {
      final sorted = sortApiConfigs(
        configs,
        const ApiPresetSortState(mode: ApiPresetSortMode.alphabetical),
      );
      expect(_ids(sorted), ['10', '20', 'imported']);
    });

    test('date added is newest first, stamps read from the id', () {
      final sorted = sortApiConfigs(
        configs,
        const ApiPresetSortState(mode: ApiPresetSortMode.dateAdded),
      );
      // The imported preset has no stamp, so it falls behind the two that do.
      expect(_ids(sorted), ['20', '10', 'imported']);
    });

    test('manual follows the stored order, unknown presets keep theirs', () {
      final sorted = sortApiConfigs(
        configs,
        const ApiPresetSortState(manualOrder: ['imported']),
      );
      // The listed one leads; '20' and '10' stay in the order they came in.
      expect(_ids(sorted), ['imported', '20', '10']);
    });

    test('an empty manual order leaves the repository order untouched', () {
      final sorted = sortApiConfigs(configs, const ApiPresetSortState());
      expect(_ids(sorted), ['20', '10', 'imported']);
    });

    test('a stale manual order ignores presets that no longer exist', () {
      final sorted = sortApiConfigs(
        configs,
        const ApiPresetSortState(manualOrder: ['gone', '10', '20']),
      );
      expect(_ids(sorted), ['10', '20', 'imported']);
    });

    test('presets that compare equal keep the order they came in', () {
      final same = <ApiConfig>[
        _config('a', name: 'same'),
        _config('b', name: 'SAME'),
        _config('c', name: 'same'),
      ];
      expect(
        _ids(
          sortApiConfigs(
            same,
            const ApiPresetSortState(mode: ApiPresetSortMode.alphabetical),
          ),
        ),
        ['a', 'b', 'c'],
      );
      // None of these ids parse as a stamp, so date-added is a tie as well.
      expect(
        _ids(
          sortApiConfigs(
            same,
            const ApiPresetSortState(mode: ApiPresetSortMode.dateAdded),
          ),
        ),
        ['a', 'b', 'c'],
      );
    });

    test('sorting does not mutate the caller list', () {
      final input = List<ApiConfig>.from(configs);
      sortApiConfigs(
        input,
        const ApiPresetSortState(mode: ApiPresetSortMode.alphabetical),
      );
      expect(_ids(input), ['20', '10', 'imported']);
    });

    test('an unknown stored mode falls back to the manual order', () {
      expect(
        PresetSortModeInfo.fromWireName('defaultOrder'),
        ApiPresetSortMode.manual,
      );
      expect(PresetSortModeInfo.fromWireName(null), ApiPresetSortMode.manual);
      expect(
        PresetSortModeInfo.fromWireName('alphabetical'),
        ApiPresetSortMode.alphabetical,
      );
    });
  });
}
