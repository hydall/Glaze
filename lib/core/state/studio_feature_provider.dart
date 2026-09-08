import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'db_provider.dart';

/// Global master switch for the **Studio** experimental feature.
///
/// Studio is otherwise a per-session setting ([StudioConfig.enabled]). This
/// provider is the app-wide gate exposed from Settings → Experimental Features:
///
/// * When `false` (the default), Studio never runs in chat — the generation
///   pipeline treats every session's Studio config as disabled — and the Studio
///   card is hidden from the magic drawer (Quick Access / Tools).
/// * When `true`, Studio behaves as before, honouring each session's own
///   [StudioConfig.enabled] flag.
///
/// Ext Blocks has an equivalent master flag inside `ExtensionsSettings.enabled`;
/// this provider covers Studio, which had no global on/off before.
final studioFeatureEnabledProvider =
    StateNotifierProvider<StudioFeatureEnabledNotifier, bool>(
      (ref) => StudioFeatureEnabledNotifier(ref),
    );

class StudioFeatureEnabledNotifier extends StateNotifier<bool> {
  StudioFeatureEnabledNotifier(this._ref) : super(false) {
    _load();
  }

  final Ref _ref;

  static const _storageKey = 'feature_studio_enabled';

  Future<void> _load() async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      // Keep the feature default-deny when preferences are unavailable.
      return;
    }
    if (!mounted) return;
    final stored = prefs.getBool(_storageKey);
    if (stored != null) {
      state = stored;
      return;
    }

    // First launch after the Experimental Features update: the flag has never
    // been written. Preserve behaviour for users who were already using Studio
    // (any session/profile with Studio enabled) by turning the master switch
    // on for them. Fresh installs have no enabled config and stay off. The
    // result is persisted so this one-time probe never runs again.
    var migrated = false;
    try {
      migrated = await _ref.read(studioConfigRepoProvider).hasAnyEnabledConfig();
    } catch (_) {
      migrated = false;
    }
    if (!mounted) return;
    state = migrated;
    await prefs.setBool(_storageKey, migrated);
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_storageKey, enabled);
  }
}
