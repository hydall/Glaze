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
import 'package:glaze_flutter/core/services/generation_notification_service.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/extensions/models/extensions_settings.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/providers/extension_presets_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/extensions_settings_provider.dart';
import 'package:glaze_flutter/features/extensions/services/extension_post_gen_service.dart';
import 'package:glaze_flutter/features/extensions/services/periodic_trigger_scheduler.dart';

AppDatabase _testDb() => AppDatabase.forTesting(NativeDatabase.memory());

class _FakePostGen extends ExtensionPostGenService {
  _FakePostGen(super.ref);

  final List<String> tickBlockIds = [];
  final List<(String charId, String sessionId)> tickContexts = [];
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
    tickContexts.add((charId, sessionId));
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
    GenerationNotificationService.instance
      ..updateLifecycleState(AppLifecycleState.resumed)
      ..setActiveContext(null, null);
  });

  tearDown(() async {
    await db.close();
  });

  test(
      'scheduler starts a timer for the enabled periodic jsRunner and ticks it',
      () async {
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWith((ref) => db),
        extensionPostGenServiceProvider.overrideWith((ref) => _FakePostGen(ref)),
      ],
    );
    addTearDown(container.dispose);

    // Seed settings (enabled + active preset). SharedPreferences is the
    // real platform plugin; we rely on it to persist across both tests
    // and on setUp's pre-cleared state to keep them isolated. Use the
    // notifier's API directly.
    await container
        .read(extensionsSettingsProvider.notifier)
        .update(const ExtensionsSettings(enabled: true, activePresetId: 'p1'));

    // Seed preset with one periodic + one afterAssistant jsRunner + one
    // infoblock (which the scheduler must ignore).
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
        BlockConfig(
          id: 'b2',
          name: 'After assistant',
          type: BlockType.jsRunner,
          enabled: true,
          trigger: BlockTrigger.afterAssistant,
          prompt: '// not run on tick',
        ),
        BlockConfig(
          id: 'b3',
          name: 'Infoblock',
          type: BlockType.infoblock,
          enabled: true,
          trigger: BlockTrigger.periodic,
          prompt: '// infoblock, not jsRunner — ignored',
        ),
      ],
    );
    await container.read(extensionPresetsProvider.notifier).add(preset);
    GenerationNotificationService.instance.setActiveContext('c1', 's1');

    // Touch the scheduler — reading the provider forces `start()`.
    final scheduler = container.read(periodicTriggerSchedulerProvider);
    expect(scheduler.activeTimerCount, 1,
        reason: 'only the enabled periodic jsRunner should have a timer');

    // Read the fake from the container so we can wait for the first tick.
    final fake = container.read(extensionPostGenServiceProvider) as _FakePostGen;
    await fake.waitForFirstTick().timeout(const Duration(seconds: 5));
    expect(fake.tickBlockIds, contains('b1'),
        reason: 'periodic jsRunner should be dispatched at least once');
    expect(fake.tickContexts, contains(('c1', 's1')),
        reason: 'periodic execution uses the active chat character and session');
  });

  test('scheduler drops timers when extensions are disabled', () async {
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWith((ref) => db),
        extensionPostGenServiceProvider.overrideWith((ref) => _FakePostGen(ref)),
      ],
    );
    addTearDown(container.dispose);

    // Seed preset but leave settings disabled.
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
    expect(scheduler.activeTimerCount, 0,
        reason: 'scheduler must not start timers when extensions are off');
  });

  test('scheduler executes only for active chat authority', () async {
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWith((ref) => db),
        extensionPostGenServiceProvider.overrideWith((ref) => _FakePostGen(ref)),
      ],
    );
    addTearDown(container.dispose);
    final scheduler = container.read(periodicTriggerSchedulerProvider);
    final block = BlockConfig(
      id: 'b1',
      name: 'Tick',
      type: BlockType.jsRunner,
      enabled: true,
      trigger: BlockTrigger.periodic,
      prompt: '// js',
    );
    final fake = container.read(extensionPostGenServiceProvider) as _FakePostGen;

    await scheduler.debugTick(block);
    expect(fake.tickBlockIds, isEmpty);

    GenerationNotificationService.instance.setActiveContext('c1', 's1');
    await scheduler.debugTick(block);
    expect(fake.tickBlockIds, ['b1']);
    expect(fake.tickContexts, [('c1', 's1')]);
  });
}
