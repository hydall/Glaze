import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/app_version.dart';
import '../constants/build_channel.dart';
import 'shared_prefs_provider.dart';

/// Whether developer mode (hidden dev tools / settings) is unlocked.
/// Persisted across launches so the chosen state is remembered.
///
/// Defaults to on for the `staging` and `nightly` channels and off for
/// `stable`; see [devToolingEnabledByDefault]. The version-badge easter egg
/// still unlocks it on a stable build.
final devModeProvider = NotifierProvider<DevModeNotifier, bool>(
  DevModeNotifier.new,
);

class DevModeNotifier extends Notifier<bool> {
  static const _prefsKey = 'devModeEnabled';

  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider).value;
    return prefs?.getBool(_prefsKey) ?? devToolingEnabledByDefault;
  }

  Future<void> set(bool value) async {
    state = value;
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(_prefsKey, value);
  }

  Future<void> toggle() => set(!state);
}

/// Dev setting: hide the build-date watermark pinned to the bottom-right
/// corner of the screen.
///
/// Visible by default on the `staging` and `nightly` channels, hidden by
/// default on `stable` — production builds ship without the build stamp. A
/// user who unlocks dev mode can still turn it back on for diagnostics.
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
