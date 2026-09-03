import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/shared_prefs_provider.dart';
import 'composer_pins_provider.dart';

/// What the send button does while the composer is empty.
///
/// With nothing typed the button has never sent anything — it impersonated the
/// user. That is one guess out of a dozen at what the only button the thumb
/// already rests on should do, so the slot is the user's to assign: in the
/// drawer's edit mode a card dragged onto the send button lands here, and the
/// button takes that card's glyph and tap whenever the composer is empty. Null
/// is the built-in impersonation.
///
/// Only the Actions tab can fill it — see [isAssignable]. Unlike
/// [composerPinsProvider] this is an override of one button's idle state rather
/// than a home of its own, so whatever is assigned keeps the place it already
/// had: a quick reply assigned here still has its card in the Actions grid.
/// Filtering it out would hide it behind a slot that is itself invisible the
/// moment the composer has text in it.
///
/// A single encoded [ComposerPin], stored under its own key rather than folded
/// into the pins list: it is one slot, and a list would have to carry a
/// position that means nothing here.
class ComposerEmptyActionNotifier extends AsyncNotifier<ComposerPin?> {
  static const storageKey = 'composer_empty_action_v1';

  /// Whether [pin] may take the empty composer's button.
  ///
  /// Actions only — the tab's quick replies and the composer's own actions.
  /// A Tools card opens a sheet *about* the chat, which is not what a thumb
  /// resting on the send button is reaching for; the row below is where those
  /// belong. Enforced here rather than only at the drop, so a stored id
  /// cannot outlive the rule.
  static bool isAssignable(ComposerPin pin) =>
      pin.kind != ComposerPinKind.tool;

  @override
  Future<ComposerPin?> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final saved = prefs.getString(storageKey);
    if (saved == null) return null;
    // An id this build cannot parse — or no longer allows — falls back to
    // impersonation rather than to a dead button, on the same terms a stale
    // pin is dropped from the row.
    final pin = ComposerPin.decode(saved);
    return pin != null && isAssignable(pin) ? pin : null;
  }

  /// Assigns [pin] to the empty composer, replacing whatever was there. A pin
  /// [isAssignable] refuses is ignored; the UI declines the drop, and this is
  /// the backstop.
  Future<void> assign(ComposerPin pin) async {
    if (!isAssignable(pin)) return;
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
