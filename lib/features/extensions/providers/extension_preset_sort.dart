import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../shared/state/preset_sort.dart';

/// How the External Blocks preset switcher is ordered, stored separately from the
/// API presets' own sort so dragging one list never reorders the other.
final extensionPresetSortProvider =
    AsyncNotifierProvider<PresetSortNotifier, PresetSortState>(
      () => PresetSortNotifier(
        modeKey: 'extensionPresetListSortMode',
        orderKey: 'extensionPresetListManualOrder',
      ),
    );

/// Whether the switcher has dragging armed. Ephemeral — the sheet arms it while
/// it is open and drops it on close.
final extensionPresetReorderArmedProvider = StateProvider<bool>((ref) => false);
