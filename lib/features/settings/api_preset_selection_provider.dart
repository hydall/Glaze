import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Multi-select state for the API presets sheet. While [active], tapping a row
/// toggles its membership instead of switching to that connection, and the
/// sheet header trades the sort chip for the bulk actions. Mirrors the Presets
/// list's own selection mode, keyed by [ApiConfig.id].
class ApiPresetSelectionState {
  final bool active;
  final Set<String> ids;

  const ApiPresetSelectionState({this.active = false, this.ids = const {}});

  int get count => ids.length;

  bool contains(String configId) => ids.contains(configId);
}

class ApiPresetSelectionNotifier extends Notifier<ApiPresetSelectionState> {
  @override
  ApiPresetSelectionState build() => const ApiPresetSelectionState();

  /// Enters selection mode with one preset selected.
  void start(String configId) {
    state = ApiPresetSelectionState(active: true, ids: {configId});
  }

  /// Toggles a preset; exits selection mode when the last one is removed.
  void toggle(String configId) {
    final next = {...state.ids};
    if (!next.remove(configId)) next.add(configId);
    state = next.isEmpty
        ? const ApiPresetSelectionState()
        : ApiPresetSelectionState(active: true, ids: next);
  }

  void clear() => state = const ApiPresetSelectionState();
}

final apiPresetSelectionProvider =
    NotifierProvider<ApiPresetSelectionNotifier, ApiPresetSelectionState>(
      ApiPresetSelectionNotifier.new,
    );
