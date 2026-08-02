import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/preset_folder.dart';

/// Multi-select state for the Presets list. While [active], tapping a card
/// toggles its membership instead of activating the preset; the selection bar
/// at the bottom of the screen exposes the bulk actions (export, folder,
/// delete). Mirrors the chat's message-selection mode.
///
/// Ids are stored as [presetMemberKey]s so chat and Studio presets can be
/// selected together without their id spaces colliding.
class PresetSelectionState {
  final bool active;
  final Set<String> keys;

  const PresetSelectionState({this.active = false, this.keys = const {}});

  int get count => keys.length;

  bool contains(String presetId, PresetKind kind) =>
      keys.contains(presetMemberKey(presetId, kind));
}

class PresetSelectionNotifier extends Notifier<PresetSelectionState> {
  @override
  PresetSelectionState build() => const PresetSelectionState();

  /// Enters selection mode with one entry selected.
  void start(String presetId, PresetKind kind) {
    state = PresetSelectionState(
      active: true,
      keys: {presetMemberKey(presetId, kind)},
    );
  }

  /// Toggles an entry; exits selection mode when the last one is removed.
  void toggle(String presetId, PresetKind kind) {
    final key = presetMemberKey(presetId, kind);
    final next = {...state.keys};
    if (!next.remove(key)) next.add(key);
    state = next.isEmpty
        ? const PresetSelectionState()
        : PresetSelectionState(active: true, keys: next);
  }

  void clear() => state = const PresetSelectionState();
}

final presetSelectionProvider =
    NotifierProvider<PresetSelectionNotifier, PresetSelectionState>(
      PresetSelectionNotifier.new,
    );
