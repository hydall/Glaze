import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/models/api_config.dart';
import '../../shared/state/preset_sort.dart';

export '../../shared/state/preset_sort.dart';

/// The API presets sheet's slice of the shared preset sort. The names are kept
/// so the screen and its tests read the same as before the sort moved into
/// `lib/shared/state/preset_sort.dart`.
typedef ApiPresetSortMode = PresetSortMode;
typedef ApiPresetSortState = PresetSortState;

/// Whether the presets sheet has dragging armed, from the chip next to the sort
/// picker. Ephemeral UI state — the sheet arms it while it is open and drops it
/// on close, so a long press means "select" the rest of the time.
final apiPresetReorderArmedProvider = StateProvider<bool>((ref) => false);

final apiPresetSortProvider =
    AsyncNotifierProvider<PresetSortNotifier, PresetSortState>(
      () => PresetSortNotifier(
        modeKey: 'apiPresetListSortMode',
        orderKey: 'apiPresetListManualOrder',
      ),
    );

/// Text a preset is sorted by: its own name, or the model it talks to when it
/// has none — the same fallback the sheet uses to label the row.
String apiPresetSortName(ApiConfig config) =>
    config.name.isNotEmpty ? config.name : config.model;

/// When the preset was added, for "date added" sorting.
///
/// API presets carry no creation timestamp of their own, but one created in the
/// app gets `DateTime.now().millisecondsSinceEpoch` as its id — so that is its
/// creation time. Presets that arrived through an import bring ids of their own
/// with no stamp to read; they fall behind the timestamped ones, in the order
/// the repository returned them.
int _createdAt(ApiConfig config) => int.tryParse(config.id) ?? 0;

List<ApiConfig> sortApiConfigs(
  List<ApiConfig> configs,
  ApiPresetSortState state,
) => sortPresetItems(
  configs,
  state,
  idOf: (c) => c.id,
  nameOf: apiPresetSortName,
  createdAtOf: _createdAt,
);
