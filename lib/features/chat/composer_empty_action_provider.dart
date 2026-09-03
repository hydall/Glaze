import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/shared_prefs_provider.dart';
import 'composer_pins_provider.dart';

/// What the send button does while the composer is empty.
///
/// With nothing typed the button has never sent anything — it impersonated the
/// user. That is one guess out of a dozen at what the only button the thumb
/// already rests on should do, so the slot is the user's to assign: in the
/// drawer's edit mode any card or pinned button dragged onto the send button
/// lands here, and the button takes that item's glyph and tap whenever the
/// composer is empty. Null is the built-in impersonation.
///
/// Unlike [composerPinsProvider] this is an override of one button's idle
/// state rather than a home of its own, so whatever is assigned keeps the place
/// it already had: a tool dropped here still has its card in the Tools tab.
/// Filtering it out would hide it behind a slot that is itself invisible the
/// moment the composer has text in it.
///
/// A single encoded [ComposerPin], stored under its own key rather than folded
/// into the pins list: it is one slot, and a list would have to carry a
/// position that means nothing here.
class ComposerEmptyActionNotifier extends AsyncNotifier<ComposerPin?> {
  static const storageKey = 'composer_empty_action_v1';

  @override
  Future<ComposerPin?> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final saved = prefs.getString(storageKey);
    // An id this build cannot parse falls back to impersonation rather than to
    // a dead button, on the same terms a stale pin is dropped from the row.
    return saved == null ? null : ComposerPin.decode(saved);
  }

  /// Assigns [pin] to the empty composer, replacing whatever was there.
  Future<void> assign(ComposerPin pin) async {
    state = AsyncData(pin);
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString(storageKey, pin.encode());
  }

  /// Gives the button its impersonation back.
  Future<void> reset() async {
    state = const AsyncData(null);
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.remove(storageKey);
  }
}

final composerEmptyActionProvider =
    AsyncNotifierProvider<ComposerEmptyActionNotifier, ComposerPin?>(
      ComposerEmptyActionNotifier.new,
    );
