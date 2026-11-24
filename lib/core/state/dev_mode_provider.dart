import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shared_prefs_provider.dart';

/// Whether developer mode (hidden dev tools / settings) is unlocked.
/// Persisted across launches so the chosen state is remembered.
///
/// Off by default on **every** channel — including `nightly` and local
/// developer builds. The only way in is the 7-tap easter egg on the version
/// badge in About (`lib/features/menu/about_screen.dart`).
///
/// Installs that ran a build from back when `nightly` turned this on
/// by default have the stale `true` cleared once at startup by
/// `resetLegacyDevModeFlag` (`lib/core/services/dev_mode_flag_migration.dart`).
final devModeProvider = NotifierProvider<DevModeNotifier, bool>(
  DevModeNotifier.new,
);

class DevModeNotifier extends Notifier<bool> {
  /// Public so the startup migration can clear the same key.
  static const prefsKey = 'devModeEnabled';

  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider).value;
    return prefs?.getBool(prefsKey) ?? false;
  }

  Future<void> set(bool value) async {
    state = value;
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(prefsKey, value);
  }

  Future<void> toggle() => set(!state);
}
