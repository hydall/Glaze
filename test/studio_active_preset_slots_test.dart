import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/state/active_studio_preset_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `studioPresetProvider` feeds the Agents tab, which reads and writes the API
/// slot bindings (`cheapApiConfigId` and friends). Generation resolves those
/// slots from the ACTIVE preset via `StudioTurnConfigResolver`, so the provider
/// has to resolve the same row.
///
/// Regression: it used to return `getDefault()` unconditionally. With any
/// non-default preset selected, the tab then edited `default`'s slots while the
/// turn read the active preset's empty ones and fell back to the chat's own
/// connection — and because the model override is global, that override was
/// still applied, sending a model from one provider to another provider's
/// endpoint ("model not found"). Only "Automatic" survived, because it takes
/// the model from whatever connection the turn ended up on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ProviderContainer container;

  Future<void> boot({required String activePresetId}) async {
    SharedPreferences.setMockInitialValues(
      activePresetId.isEmpty
          ? <String, Object>{}
          : <String, Object>{activeStudioPresetKey: activePresetId},
    );
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);

    final repo = container.read(studioPresetRepoProvider);
    await repo.upsert(
      const StudioPreset(
        id: 'default',
        name: 'Default Studio Preset',
        cheapApiConfigId: 'connection-default',
      ),
    );
    await repo.upsert(
      const StudioPreset(
        id: 'custom',
        name: 'Custom Studio Preset',
        cheapApiConfigId: 'connection-custom',
      ),
    );
  }

  test('resolves the active preset, not the default one', () async {
    await boot(activePresetId: 'custom');

    final preset = await container.read(studioPresetProvider.future);

    expect(preset?.id, 'custom');
    expect(preset?.cheapApiConfigId, 'connection-custom');
  });

  test('falls back to the default preset when no active id is stored', () async {
    await boot(activePresetId: '');

    final preset = await container.read(studioPresetProvider.future);

    expect(preset?.id, 'default');
    expect(preset?.cheapApiConfigId, 'connection-default');
  });

  test('falls back to the default preset when the active id is stale', () async {
    await boot(activePresetId: 'deleted-preset');

    final preset = await container.read(studioPresetProvider.future);

    expect(preset?.id, 'default');
    expect(preset?.cheapApiConfigId, 'connection-default');
  });
}
