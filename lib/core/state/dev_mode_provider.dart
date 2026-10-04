import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/app_version.dart';
import '../constants/build_channel.dart';
import 'shared_prefs_provider.dart';

/// Whether developer mode (hidden dev tools / settings) is unlocked.
/// Persisted across launches so the chosen state is remembered.
///
/// Off by default on **every** channel — including `nightly` and local
/// developer builds. The only way in is the 7-tap easter egg on the version
/// badge in About (`lib/features/menu/about_screen.dart`).
///
/// Installs that ran a build from back when `nightly`/`staging` turned this on
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

/// Dev setting: hide the build-date watermark pinned to the bottom-right
/// corner of the screen.
///
/// Visible by default everywhere except a `stable` build of a non-beta
/// version — while the app is on a `0.x` version even stable ships the build
/// stamp, because that is what makes a bug report identifiable. Hiding it is a
/// dev setting, so it takes unlocking dev mode in About first.
final hideBuildWatermarkProvider =
    NotifierProvider<HideBuildWatermarkNotifier, bool>(
  HideBuildWatermarkNotifier.new,
);

class HideBuildWatermarkNotifier extends Notifier<bool> {
  static const _prefsKey = 'hideBuildWatermark';

  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider).value;
    return prefs?.getBool(_prefsKey) ?? (isStableChannel && !isBetaVersion);
  }

  Future<void> set(bool value) async {
    state = value;
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(_prefsKey, value);
  }

  Future<void> toggle() => set(!state);
}
