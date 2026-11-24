import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shared_prefs_provider.dart';

/// Whether the build watermark — version, branch and build date pinned to the
/// bottom-right corner — is hidden.
///
/// Shown by default on every channel: a screenshot that carries the version is
/// what makes a bug report answerable without a round of "which build is
/// this?". Users can still hide it from Settings → Appearance, behind a
/// warning that says exactly that (`BuildWatermarkToggle`).
///
/// Stored as "hide" under the key the old dev-only switch used, so an install
/// that already turned it off keeps it off.
final hideBuildWatermarkProvider =
    NotifierProvider<HideBuildWatermarkNotifier, bool>(
  HideBuildWatermarkNotifier.new,
);

class HideBuildWatermarkNotifier extends Notifier<bool> {
  static const _prefsKey = 'hideBuildWatermark';

  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider).value;
    return prefs?.getBool(_prefsKey) ?? false;
  }

  Future<void> set(bool value) async {
    state = value;
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setBool(_prefsKey, value);
  }
}
