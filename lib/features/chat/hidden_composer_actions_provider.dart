import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/shared_prefs_provider.dart';
import 'composer_pins_provider.dart';

/// The insert actions the user has put away from the drawer's Actions tab.
///
/// The two pair-insert buttons are built-in, so they cannot be deleted the way
/// a quick reply can — the delete badge has nothing to remove. Hiding them is
/// the reversible alternative: a hidden action is dropped from the grid and
/// from the composer's pinned row, and the tab's "+" sheet offers it back.
/// Only [ComposerAction.isInsert] actions can be hidden; every other action is
/// a way into a feature and would leave a hole no button brings back.
///
/// Stored as a list of action ids, so an id this build no longer knows is
/// ignored on read exactly like a stale pin.
class HiddenComposerActionsNotifier extends AsyncNotifier<Set<String>> {
  static const storageKey = 'composer_hidden_actions_v1';

  @override
  Future<Set<String>> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final saved = prefs.getStringList(storageKey) ?? const [];
    return {
      for (final id in saved)
        if (ComposerAction.byId(id)?.isInsert ?? false) id,
    };
  }

  Future<void> hide(ComposerAction action) async {
    if (!action.isInsert) return;
    await _persist({...state.value ?? const <String>{}, action.id});
  }

  Future<void> show(ComposerAction action) async {
    await _persist({...state.value ?? const <String>{}}..remove(action.id));
  }

  Future<void> _persist(Set<String> next) async {
    state = AsyncData(next);
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setStringList(storageKey, next.toList());
  }
}

final hiddenComposerActionsProvider =
    AsyncNotifierProvider<HiddenComposerActionsNotifier, Set<String>>(
      HiddenComposerActionsNotifier.new,
    );
