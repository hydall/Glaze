import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_serialization.dart';

void main() {
  test('local storage carries settings and global regex collections', () {
    expect(
      SyncSerialization.localStoragePayload(
        pipelineSettings: '{"cleaner":true}',
        globalRegexScripts: '[{"id":"global"}]',
        studioRegexScripts: '[{"script":{"id":"studio"}}]',
        appSettings: const {'enterToSend': false},
      ),
      {
        '__localStorage': true,
        'pipelineSettings': '{"cleaner":true}',
        'gz_global_regex_scripts': '[{"id":"global"}]',
        'gz_studio_regex_scripts': '[{"script":{"id":"studio"}}]',
        'appSettings': {'enterToSend': false},
      },
    );
  });

  test('computeMemoryBookHash ignores device-local fields', () {
    final base = MemoryBook(
      id: 'memorybook_s1',
      sessionId: 's1',
      updatedAt: 1000,
      lastProcessedMessageCount: 42,
    ).toJson();
    final withLocalFields = MemoryBook(
      id: 'memorybook_s1',
      sessionId: 's1',
      updatedAt: 999999,
      lastProcessedMessageCount: 99,
    ).toJson();

    final fromMake = MemoryBook(
      id: 'memorybook_s1',
      sessionId: 's1',
      updatedAt: 1000,
    ).toJson();

    final baseHash = SyncSerialization.computeMemoryBookHash(base);
    expect(
      SyncSerialization.computeMemoryBookHash(withLocalFields),
      equals(baseHash),
    );
    expect(SyncSerialization.computeMemoryBookHash(fromMake), equals(baseHash));

    final cloudJson = jsonDecode(jsonEncode(base)) as Map<String, dynamic>;
    expect(
      SyncSerialization.computeMemoryBookHash(cloudJson),
      equals(baseHash),
    );
  });
}
