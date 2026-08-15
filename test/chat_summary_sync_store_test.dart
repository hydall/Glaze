import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/summary_repo.dart';
import 'package:glaze_flutter/features/cloud_sync/adapters/ext_blocks_sync_stores.dart';

void main() {
  test('cloud summary import preserves its updatedAt', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = SummaryRepo(db);
    final store = ChatSummarySyncStore(repo);
    final cloud = <String, dynamic>{
      'sessionId': 'session',
      'content': 'Cloud summary',
      'enabled': false,
      'messageCount': 12,
      'prompt': 'Keep this prompt',
      'updatedAt': 1234,
    };

    await store.putRaw(cloud);

    expect(await store.getBySessionId('session'), cloud);
  });
}
