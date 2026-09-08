import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/features/cloud_sync/adapters/ext_blocks_sync_stores.dart';

void main() {
  test(
    'character knowledge sync round-trips facts, baseline, and tombstones',
    () async {
      final source = AppDatabase.forTesting(NativeDatabase.memory());
      final target = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await source.close();
        await target.close();
      });

      await source.customStatement(
        '''INSERT INTO character_knowledge_fact_rows (
        id, chat_session_id, knower_key, subject_key, fact_class, predicate,
        object, epistemic_state, lifecycle, source_message_id, created_at,
        updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          'fact-1',
          'session-1',
          'lucy',
          'danvi',
          'relationship',
          'trusts',
          'Danvi after the rescue',
          'confirmed',
          'retracted',
          'message-1',
          10,
          11,
        ],
      );
      await source.customStatement(
        '''INSERT INTO character_session_baseline_rows (
        chat_session_id, character_id, baseline_card_json, baseline_hash,
        source_hash_last_seen, card_update_policy, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          'session-1',
          'lucy-id',
          '{"name":"Lucy"}',
          'base-hash',
          'source-hash',
          'pinned_baseline',
          1,
          2,
        ],
      );

      final payload = await CharacterKnowledgeSyncStore(
        source,
      ).getBySessionId('session-1');
      expect(payload, isNotNull);
      expect(payload!['facts'], hasLength(1));

      final targetStore = CharacterKnowledgeSyncStore(target);
      await targetStore.applyBySessionId('session-1', payload);
      final restored = await targetStore.getBySessionId('session-1');

      expect(restored!['facts'], hasLength(1));
      expect((restored['facts'] as List).single['lifecycle'], 'retracted');
      expect((restored['baseline'] as Map)['baselineHash'], 'base-hash');

      await targetStore.deleteBySessionId('session-1');
      expect(await targetStore.getBySessionId('session-1'), isNull);
    },
  );
}
