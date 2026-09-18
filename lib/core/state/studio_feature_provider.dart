import 'dart:async';

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
/// External Blocks has an equivalent master flag inside `ExtensionsSettings.enabled`;
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

  final _loaded = Completer<void>();

  /// Completes once the stored flag (and the one-time migration probe behind
  /// it) has been read. The state starts at `false` because a [StateNotifier]
  /// cannot be async, so anything that *branches* on the switch — rather than
  /// merely rendering it — must await this first, or it decides during the
  /// window where an enabled Studio still reads as off.
  Future<void> get ready => _loaded.future;

  /// The switch once [ready] has settled. Readers want this rather than
  /// `await ready` followed by a read of the provider: the flip out of the
  /// loading window rebuilds every watcher, so a `ref` touched after that
  /// await belongs to a build that is already gone.
  Future<bool> get settled async {
    await _loaded.future;
    return state;
  }

  /// Reads the stored flag, completing [ready] whichever way it goes — a throw
  /// on the way out must not leave every awaiting reader hanging.
  Future<void> _load() async {
    try {
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
        migrated = await _ref
            .read(studioConfigRepoProvider)
            .hasAnyEnabledConfig();
      } catch (_) {
        migrated = false;
      }
      if (!mounted) return;
      state = migrated;
      await prefs.setBool(_storageKey, migrated);
    } finally {
      if (!_loaded.isCompleted) _loaded.complete();
    }
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    // [studioFeatureSettledProvider] deliberately does not watch this value —
    // see the note there — so a toggle has to announce itself. It cannot
    // invalidate that provider directly either: the provider depends on this
    // notifier, which makes invalidating it from here a dependency cycle.
    _ref.read(studioFeatureRevisionProvider.notifier).state++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_storageKey, enabled);
  }

  Future<void> enable() async => setEnabled(true);
}

/// Bumped by [StudioFeatureEnabledNotifier.setEnabled], so that a runtime
/// toggle — and only a runtime toggle — re-resolves
/// [studioFeatureSettledProvider].
final studioFeatureRevisionProvider = StateProvider<int>((ref) => 0);

/// The master switch, settled — see [StudioFeatureEnabledNotifier.settled].
///
/// It watches the notifier and **not** the switch's value, on purpose.
/// Watching the value invalidates this provider from inside its own loading
/// window, the moment the flag flips out of the `false` it starts at; nothing
/// is listening to the provider itself at that point (a reader holds only its
/// future), so the rebuild is never scheduled and that future stays pending
/// forever. The revision above carries a toggle instead, and it never moves
/// during the load.
final studioFeatureSettledProvider = FutureProvider<bool>((ref) {
  ref.watch(studioFeatureRevisionProvider);
  return ref.watch(studioFeatureEnabledProvider.notifier).settled;
});
