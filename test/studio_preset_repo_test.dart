import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';

void main() {
  late AppDatabase db;
  late StudioPresetRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = StudioPresetRepo(db);
  });
  tearDown(() => db.close());

  test('round-trips execution mode and per-agent overrides', () async {
    const preset = StudioPreset(
      id: 'studio_direct_loom_v1',
      name: 'Direct Loom v1',
      executionMode: StudioExecutionMode.direct,
      agentEnabled: {'continuity': false, 'narrative': false, 'final': true},
    );

    await repo.upsert(preset);
    final restored = await repo.getById(preset.id);

    expect(restored?.executionMode, StudioExecutionMode.direct);
    expect(restored?.agentEnabled, preset.agentEnabled);
  });

  test('unknown persisted execution mode safely falls back to legacy', () {
    expect(
      StudioExecutionMode.fromWireName('future-topology'),
      StudioExecutionMode.legacy,
    );
  });
}
