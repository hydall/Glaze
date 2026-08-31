import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_serialization.dart';

void main() {
  test('local storage carries settings and global regex collections', () {
    expect(
      SyncSerialization.localStoragePayload(
        pipelineSettings: '{"cleaner":true}',
        activeStudioPresetId: 'studio_loom_causal_direct_v1',
        globalRegexScripts: '[{"id":"global"}]',
        studioRegexScripts: '[{"script":{"id":"studio"}}]',
        appSettings: const {'enterToSend': false},
      ),
      {
        '__localStorage': true,
        'pipelineSettings': '{"cleaner":true}',
        'activeStudioPresetId': 'studio_loom_causal_direct_v1',
        'gz_global_regex_scripts': '[{"id":"global"}]',
        'gz_studio_regex_scripts': '[{"script":{"id":"studio"}}]',
        'appSettings': {'enterToSend': false},
      },
    );
  });

  test('Studio preset JSON preserves block order and authored fields', () {
    const preset = StudioPreset(
      id: 'studio_loom_causal_direct_v1',
      name: 'Loom Direct',
      agentEnabled: {'final': true, 'narrative': false},
      blocks: [
        StudioPresetBlock(
          id: 'anime',
          title: 'Anime-Style Story',
          section: 'final',
          content: '<loomstyle>anime</loomstyle>',
        ),
        StudioPresetBlock(
          id: 'bratty',
          title: 'Bratty Ass Narrative',
          section: 'final',
          enabled: false,
          content: '<loomstyle>bratty</loomstyle>',
        ),
      ],
    );

    final wireJson = jsonDecode(jsonEncode(preset.toJson()));
    final blocks = wireJson['blocks'] as List<dynamic>;
    expect(blocks.first, containsPair('type', 'instruction'));
    expect(blocks.first, isNot(contains('kind')));
    expect(StudioPreset.fromJson(wireJson as Map<String, dynamic>), preset);
  });

  test('Studio config hash ignores sync timestamps', () {
    const first = StudioConfig(
      sessionId: 'session-1',
      enabled: true,
      createdAt: 100,
      updatedAt: 200,
    );
    const second = StudioConfig(
      sessionId: 'session-1',
      enabled: true,
      createdAt: 300,
      updatedAt: 400,
    );

    expect(
      SyncSerialization.computeStudioConfigHash(first.toJson()),
      SyncSerialization.computeStudioConfigHash(second.toJson()),
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
