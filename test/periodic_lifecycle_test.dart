// Tests for the app-lifecycle pause/resume behaviour of
// `PeriodicTriggerScheduler`.
//
// The scheduler registers itself as a `WidgetsBindingObserver` so it
// can pause periodic ticks when the app is backgrounded. We drive the
// observer directly via `debugLifecycleState` so the tests don't need
// a real Flutter binding.
//
// Invariants pinned here:
//   1. On `paused` / `inactive` / `hidden` / `detached`, the
//      scheduler drops every active timer.
//   2. On `resumed`, the scheduler rebuilds timers from the current
//      active preset, so a long backgrounding period does NOT
//      produce a burst of catch-up ticks.
//   3. The scheduler is defensive when the extensions toggle is off
//      and the app is paused at the same time: it must not throw.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/extensions_settings.dart';
import 'package:glaze_flutter/features/extensions/providers/extension_presets_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/extensions_settings_provider.dart';
import 'package:glaze_flutter/features/extensions/services/extension_post_gen_service.dart';
import 'package:glaze_flutter/features/extensions/services/periodic_trigger_scheduler.dart';

AppDatabase _testDb() => AppDatabase.forTesting(NativeDatabase.memory());

class _FakePostGen extends ExtensionPostGenService {
  _FakePostGen(super.ref);

  final List<String> tickBlockIds = [];
  final Completer<void> _firstTick = Completer<void>();
  bool _signalled = false;

  @override
  Future<String?> runJsBlock({
    required String charId,
    required String sessionId,
    required BlockConfig block,
    required List<ChatMessage> contextMessages,
    bool Function()? isAuthorized,
  }) async {
    tickBlockIds.add(block.id);
    if (!_signalled) {
      _signalled = true;
      _firstTick.complete();
    }
    return null;
  }

  Future<void> waitForFirstTick() => _firstTick.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late CharacterRepo characterRepo;

  setUp(() async {
    db = _testDb();
    characterRepo = CharacterRepo(db);
    await characterRepo.put(Character(id: 'c1', name: 'Alice'));
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await db.close();
  });

  test('scheduler pauses on paused lifecycle and resumes on resumed',
      () async {
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWith((ref) => db),
        extensionPostGenServiceProvider.overrideWith((ref) => _FakePostGen(ref)),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(extensionsSettingsProvider.notifier)
        .update(const ExtensionsSettings(enabled: true, activePresetId: 'p1'));
    final preset = ExtensionPreset(
      id: 'p1',
      name: 'Tick',
      blocks: [
        BlockConfig(
          id: 'b1',
          name: 'Tick',
          type: BlockType.jsRunner,
          enabled: true,
          trigger: BlockTrigger.periodic,
          prompt: '// js',
          periodicIntervalSeconds: 1,
        ),
      ],
    );
    await container.read(extensionPresetsProvider.notifier).add(preset);

    final scheduler = container.read(periodicTriggerSchedulerProvider);
    expect(scheduler.activeTimerCount, 1,
        reason: 'timer is created when the app is resumed');
    expect(scheduler.currentLifecycle, AppLifecycleState.resumed);

    scheduler.debugLifecycleState(AppLifecycleState.paused);
    expect(scheduler.activeTimerCount, 0,
        reason: 'paused lifecycle cancels all timers');

    scheduler.debugLifecycleState(AppLifecycleState.inactive);
    expect(scheduler.activeTimerCount, 0,
        reason: 'inactive lifecycle also cancels all timers');

    scheduler.debugLifecycleState(AppLifecycleState.hidden);
    expect(scheduler.activeTimerCount, 0,
        reason: 'hidden lifecycle also cancels all timers');

    scheduler.debugLifecycleState(AppLifecycleState.resumed);
    expect(scheduler.activeTimerCount, 1,
        reason: 'resumed lifecycle rebuilds timers from the current preset');
  });

  test('scheduler does not rebuild timers while not resumed', () async {
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWith((ref) => db),
        extensionPostGenServiceProvider.overrideWith((ref) => _FakePostGen(ref)),
      ],
    );
    addTearDown(container.dispose);

    // Settings disabled: no timers should ever be created, even on
    // a synthetic resumed → paused → resumed cycle.
    await container
        .read(extensionsSettingsProvider.notifier)
        .update(const ExtensionsSettings(enabled: false, activePresetId: 'p2'));
    final preset = ExtensionPreset(
      id: 'p2',
      name: 'Tick',
      blocks: [
        BlockConfig(
          id: 'b1',
          name: 'Tick',
          type: BlockType.jsRunner,
          enabled: true,
          trigger: BlockTrigger.periodic,
          prompt: '// js',
          periodicIntervalSeconds: 1,
        ),
      ],
    );
    await container.read(extensionPresetsProvider.notifier).add(preset);

    final scheduler = container.read(periodicTriggerSchedulerProvider);
    expect(scheduler.activeTimerCount, 0);
    scheduler.debugLifecycleState(AppLifecycleState.paused);
    expect(scheduler.activeTimerCount, 0);
    scheduler.debugLifecycleState(AppLifecycleState.resumed);
    expect(scheduler.activeTimerCount, 0,
        reason: 'settings.enabled=false still blocks the timer set');
  });

  test('scheduler survives a paused → detached → resumed cycle', () async {
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWith((ref) => db),
        extensionPostGenServiceProvider.overrideWith((ref) => _FakePostGen(ref)),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(extensionsSettingsProvider.notifier)
        .update(const ExtensionsSettings(enabled: true, activePresetId: 'p3'));
    final preset = ExtensionPreset(
      id: 'p3',
      name: 'Tick',
      blocks: [
        BlockConfig(
          id: 'b1',
          name: 'Tick',
          type: BlockType.jsRunner,
          enabled: true,
          trigger: BlockTrigger.periodic,
          prompt: '// js',
          periodicIntervalSeconds: 60,
        ),
      ],
    );
    await container.read(extensionPresetsProvider.notifier).add(preset);

    final scheduler = container.read(periodicTriggerSchedulerProvider);
    expect(scheduler.activeTimerCount, 1);

    scheduler.debugLifecycleState(AppLifecycleState.paused);
    expect(scheduler.activeTimerCount, 0);
    scheduler.debugLifecycleState(AppLifecycleState.detached);
    expect(scheduler.activeTimerCount, 0);
    scheduler.debugLifecycleState(AppLifecycleState.resumed);
    expect(scheduler.activeTimerCount, 1);
  });
}
