import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/state/preset_sort.dart' as shared;
import 'preset_entry.dart';

// The sort vocabulary and persistence are shared by every preset list in the
// app — see `lib/shared/state/preset_sort.dart`. This file only supplies the
// Presets list's own stored instance and the [PresetItem] adapter, so the
// screen and the other lists can never drift apart.
export '../../shared/state/preset_sort.dart'
    show PresetSortMode, PresetSortModeInfo, PresetSortState;

final presetSortProvider =
    AsyncNotifierProvider<shared.PresetSortNotifier, shared.PresetSortState>(
      () => shared.PresetSortNotifier(
        modeKey: 'presetListSortMode',
        orderKey: 'presetListManualOrder',
      ),
    );

/// Sorts [items] according to [state], leaving the caller's list untouched.
///
/// A [PresetItem]'s manual order is keyed by its [PresetItem.memberKey]
/// (`kind:id`), so the same preset never collides with the other store's row of
/// the same numeric id.
List<PresetItem> sortPresetItems(
  List<PresetItem> items,
  shared.PresetSortState state,
) => shared.sortPresetItems(
  items,
  state,
  idOf: (e) => e.memberKey,
  nameOf: (e) => e.name,
  createdAtOf: (e) => e.createdAt,
);
