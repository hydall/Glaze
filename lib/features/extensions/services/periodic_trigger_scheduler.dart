import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/generation_notification_service.dart';
import '../models/block_config.dart';
import '../models/extension_preset.dart';
import '../providers/extension_presets_provider.dart';
import '../providers/extensions_settings_provider.dart';
import 'extension_post_gen_service.dart';

/// In-process scheduler for `BlockTrigger.periodic` blocks.
///
/// The scheduler watches:
///   * `extensionPresetsProvider` — to discover new/updated/changed blocks.
///   * `extensionsSettingsProvider` — to pause/resume with the master
///     extensions toggle and the active preset selection.
///
/// For each enabled block with `trigger == BlockTrigger.periodic` the
/// scheduler starts a per-block [Timer.periodic]. The tick handler
/// delegates to [ExtensionPostGenService.runJsBlock] which already
/// prefers the headless engine and falls back to the visual bridge.
///
/// Lifecycle:
///   * One scheduler per app (singleton).
///   * `start()` is idempotent.
///   * `dispose()` cancels all timers and removes the binding observer.
///   * The scheduler pauses on `paused` / `inactive` / `hidden` and
///     resumes on `resumed`. When resuming, the elapsed wall-clock
///     time during the pause is *not* carried over — the next tick is
///     scheduled `periodicIntervalSeconds` after resume so a long
///     backgrounding period never produces a burst of catch-up ticks.
class PeriodicTriggerScheduler with WidgetsBindingObserver {
  PeriodicTriggerScheduler(this._ref);

  final Ref _ref;
  final Map<String, Timer> _timers = {};
  ProviderSubscription<List<ExtensionPreset>>? _presetSub;
  ProviderSubscription<dynamic>? _settingsSub;
  bool _started = false;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  final bool _isLifecycleListener = true;

  /// Starts the scheduler. Idempotent.
  void start() {
    if (_started) return;
    _started = true;

    if (_isLifecycleListener) {
      WidgetsBinding.instance.addObserver(this);
    }

    // Rebuild the timer set whenever the preset list OR the settings
    // change. Both providers are watched via subscriptions so the
    // scheduler itself doesn't need to be a Riverpod consumer.
    _presetSub = _ref.listen<List<ExtensionPreset>>(
      extensionPresetsProvider,
      (_, _) => _rebuildTimers(),
      fireImmediately: true,
    );
    _settingsSub = _ref.listen<dynamic>(
      extensionsSettingsProvider,
      (_, _) => _rebuildTimers(),
      fireImmediately: true,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    switch (state) {
      case AppLifecycleState.resumed:
        // Resume: rebuild timers so any that were paused are
        // recreated (we re-read the active preset). The next tick
        // fires `periodicIntervalSeconds` from now, not from when
        // the timer was first scheduled — the previous timers were
        // cancelled on pause.
        _rebuildTimers();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // Pause: drop every active timer. Rebuilding on resume will
        // recreate them. We don't run any "catch-up" tick when the
        // app comes back to the foreground — periodic scripts are
        // side-effect-only, and a long pause (e.g. overnight) must
        // not produce a flood of catch-up ticks.
        _cancelAll();
    }
  }

  @visibleForTesting
  AppLifecycleState get currentLifecycle => _lifecycle;

  /// Visible for tests: drive a synthetic lifecycle state without
  /// touching the binding observer. The production path uses
  /// [didChangeAppLifecycleState] from the binding.
  @visibleForTesting
  void debugLifecycleState(AppLifecycleState state) {
    didChangeAppLifecycleState(state);
  }

  void _rebuildTimers() {
    if (_lifecycle != AppLifecycleState.resumed) return;
    final settings = _ref.read(extensionsSettingsProvider);
    final activeId = settings.activePresetId;
    if (!settings.enabled || activeId == null || activeId.isEmpty) {
      _cancelAll();
      return;
    }
    final presets = _ref.read(extensionPresetsProvider);
    final preset = presets.where((p) => p.id == activeId).firstOrNull;
    if (preset == null) {
      _cancelAll();
      return;
    }

    final activeBlocks = {
      for (final b in preset.blocks.where(
        (b) =>
            b.enabled &&
            b.type == BlockType.jsRunner &&
            b.trigger == BlockTrigger.periodic,
      ))
        b.id: b,
    };

    // Drop timers for removed/disabled blocks.
    for (final key in _timers.keys.toList()) {
      if (!activeBlocks.containsKey(key)) {
        _timers.remove(key)?.cancel();
      }
    }

    // Start or restart timers for current blocks. The interval may have
    // changed, so we always cancel-then-recreate.
    for (final entry in activeBlocks.entries) {
      final block = entry.value;
      final seconds = block.periodicIntervalSeconds <= 0
          ? 60
          : block.periodicIntervalSeconds;
      _timers.remove(entry.key)?.cancel();
      _timers[entry.key] = Timer.periodic(
        Duration(seconds: seconds),
        (_) => _tick(block),
      );
    }
  }

  Future<void> _tick(BlockConfig block) async {
    try {
      final authority = GenerationNotificationService.instance.activeChatContext;
      if (authority == null) return;
      final post = _ref.read(extensionPostGenServiceProvider);
      // `runJsBlock` is the existing entry point — it handles headless /
      // visual fallback and the cancel token. We don't need a
      // continuation on the returned future; periodic ticks are
      // fire-and-forget.
      unawaited(
        post.runJsBlock(
          charId: authority.charId,
          sessionId: authority.sessionId,
          block: block,
          contextMessages: const [],
          isAuthorized: () => GenerationNotificationService.instance
              .isCurrentActiveChatContext(authority),
        ),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[PeriodicTrigger] tick failed for ${block.name}: $e');
      }
    }
  }

  void _cancelAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }

  /// Visible for tests.
  int get activeTimerCount => _timers.length;

  @visibleForTesting
  Future<void> debugTick(BlockConfig block) => _tick(block);

  void dispose() {
    if (_isLifecycleListener) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _cancelAll();
    _presetSub?.close();
    _settingsSub?.close();
    _started = false;
  }
}

final periodicTriggerSchedulerProvider =
    Provider<PeriodicTriggerScheduler>((ref) {
  final scheduler = PeriodicTriggerScheduler(ref);
  scheduler.start();
  ref.onDispose(scheduler.dispose);
  return scheduler;
});
