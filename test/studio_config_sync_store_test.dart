import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/studio_config_repo.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_serialization.dart';

void main() {
  test('sync import preserves Studio config timestamps and hash', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = StudioConfigRepo(db);
    const cloudConfig = StudioConfig(
      sessionId: 'session-1',
      enabled: true,
      createdAt: 100,
      updatedAt: 200,
    );

    await store.put(cloudConfig);

    final imported = await store.getById(cloudConfig.sessionId);
    expect(imported, cloudConfig);
    expect(
      SyncSerialization.computeStudioConfigHash(imported!.toJson()),
      SyncSerialization.computeStudioConfigHash(cloudConfig.toJson()),
    );
  });
}
