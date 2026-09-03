import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/message_recall_service.dart';

class _FakeEmbeddingService extends EmbeddingService {
  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    cancelToken,
    captureContext,
  }) async {
    return const [
      EmbeddingChunk(text: 'query', vector: [1, 0]),
    ];
  }
}

void main() {
  group('MessageRecallService', () {
    late AppDatabase db;
    late EmbeddingRepo repo;
    late MessageRecallService service;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = EmbeddingRepo(db);
      service = MessageRecallService(repo, _FakeEmbeddingService());
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> putChunk({
      required String entryId,
      String sourceType = 'chat_message',
      String sourceId = 's1',
      required List<String> messageIds,
      required String text,
      required List<double> vector,
    }) {
      return repo.putEmbeddingVector(
        entryId: entryId,
        sourceType: sourceType,
        sourceId: sourceId,
        vectors: [vector],
        textHash: entryId,
        retrievalMetadata: {
          'messageIds': messageIds,
          'chunks': [
            {'index': 0, 'text': text},
          ],
        },
      );
    }

    test('excludes chunks overlapping visible message ids', () async {
      await putChunk(
        entryId: 'visible',
        messageIds: ['m10'],
        text: 'visible chunk',
        vector: [1, 0],
      );
      await putChunk(
        entryId: 'older',
        messageIds: ['m1'],
        text: 'older chunk',
        vector: [0.9, 0.1],
      );

      final result = await service.recall(
        sessionId: 's1',
        currentText: 'query',
        config: const EmbeddingConfig(endpoint: 'test'),
        visibleMessageIds: {'m10'},
        threshold: 0,
      );

      expect(result.matches.map((m) => m.entryId), ['older']);
    });

    test('keeps non-overlapping chunks', () async {
      await putChunk(
        entryId: 'older',
        messageIds: ['m1'],
        text: 'older chunk',
        vector: [1, 0],
      );

      final result = await service.recall(
        sessionId: 's1',
        currentText: 'query',
        config: const EmbeddingConfig(endpoint: 'test'),
        visibleMessageIds: {'m10'},
        threshold: 0,
      );

      expect(result.matches.single.entryId, 'older');
      expect(result.matches.single.messageIds, ['m1']);
    });

    test('isolates recall rows by source type and session', () async {
      await putChunk(
        entryId: 'current-session',
        messageIds: ['m1'],
        text: 'current session chunk',
        vector: [1, 0],
      );
      await putChunk(
        entryId: 'other-session',
        sourceId: 's2',
        messageIds: ['m2'],
        text: 'other session chunk',
        vector: [1, 0],
      );
      await putChunk(
        entryId: 'other-source',
        sourceType: 'memory_entry',
        messageIds: ['m3'],
        text: 'other source chunk',
        vector: [1, 0],
      );

      final result = await service.recall(
        sessionId: 's1',
        currentText: 'query',
        config: const EmbeddingConfig(endpoint: 'test'),
        threshold: 0,
      );

      expect(result.matches.map((match) => match.entryId), ['current-session']);
    });
  });
}
