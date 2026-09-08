import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Multi-select state for the My Characters grid. While [active], tapping a
/// card toggles its membership instead of opening it; the selection bar at the
/// bottom of [CharacterListScreen] exposes the bulk actions.
class CharacterSelectionState {
  final bool active;
  final Set<String> ids;

  const CharacterSelectionState({this.active = false, this.ids = const {}});

  int get count => ids.length;
  bool contains(String id) => ids.contains(id);
}

class CharacterSelectionNotifier extends Notifier<CharacterSelectionState> {
  @override
  CharacterSelectionState build() => const CharacterSelectionState();

  /// Enters selection mode with [id] selected.
  void start(String id) {
    state = CharacterSelectionState(active: true, ids: {id});
  }

  /// Toggles [id]; exits selection mode when the last item is removed.
  void toggle(String id) {
    final next = {...state.ids};
    if (!next.remove(id)) next.add(id);
    state = next.isEmpty
        ? const CharacterSelectionState()
        : CharacterSelectionState(active: true, ids: next);
  }

  void clear() => state = const CharacterSelectionState();
}

final characterSelectionProvider =
    NotifierProvider<CharacterSelectionNotifier, CharacterSelectionState>(
      CharacterSelectionNotifier.new,
    );

/// Ids whose cards should be playing the iOS "crumble to dust" delete animation
/// right now. The bulk-delete flow marks every selected id at once so all
/// visible cards disintegrate together (rather than one-by-one); each
/// [CharacterCard] listens for its own id, plays its dust animation, and the
/// screen batch-removes the rows once the sweep has had time to run.
class CharacterDisintegrationNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void mark(Set<String> ids) => state = {...state, ...ids};
  void clear() => state = const {};
}

final characterDisintegrationProvider =
    NotifierProvider<CharacterDisintegrationNotifier, Set<String>>(
      CharacterDisintegrationNotifier.new,
    );
