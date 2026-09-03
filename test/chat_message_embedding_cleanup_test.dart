import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/llm/chat_message_embedding_service.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

class _FakeEmbeddingService extends EmbeddingService {
  int requestCount = 0;

  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    cancelToken,
    captureContext,
  }) async {
    requestCount++;
    return [
      for (final text in texts)
        EmbeddingChunk(text: text, vector: const [1, 0]),
    ];
  }
}

class _CountingEmbeddingRepo extends EmbeddingRepo {
  _CountingEmbeddingRepo(super.db);

  int sourceLoads = 0;
  int entryLoads = 0;
  int bulkDeletes = 0;

  @override
  Future<List<EmbeddingRow>> getBySource(String sourceType, String sourceId) {
    sourceLoads++;
    return super.getBySource(sourceType, sourceId);
  }

  @override
  Future<EmbeddingRow?> getByEntryId(String entryId) {
    entryLoads++;
    return super.getByEntryId(entryId);
  }

  @override
  Future<void> deleteBySourceAndEntryIds(
    String sourceType,
    String sourceId,
    Iterable<String> entryIds,
  ) {
    bulkDeletes++;
    return super.deleteBySourceAndEntryIds(sourceType, sourceId, entryIds);
  }

  void resetCounts() {
    sourceLoads = 0;
    entryLoads = 0;
    bulkDeletes = 0;
  }
}

void main() {
  late AppDatabase db;
  late _CountingEmbeddingRepo repo;
  late _FakeEmbeddingService embeddingService;
  late ChatMessageEmbeddingService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = _CountingEmbeddingRepo(db);
    embeddingService = _FakeEmbeddingService();
    service = ChatMessageEmbeddingService(repo, embeddingService);
  });

  tearDown(() => db.close());

  Future<void> seedChunk(int index) {
    return repo.putEmbeddingVector(
      entryId: 's1_$index',
      sourceType: 'chat_message',
      sourceId: 's1',
      vectors: const [
        [1, 0],
      ],
      textHash: 'stale',
      retrievalMetadata: {'chunkIndex': index},
    );
  }

  List<ChatMessage> messages(int count) => [
    for (var i = 0; i < count; i++)
      ChatMessage(
        id: 'm$i',
        role: i.isEven ? 'user' : 'assistant',
        content: 'message $i',
      ),
  ];

  test('preloads once and does not re-embed unchanged chunks', () async {
    await service.indexSessionMessages(
      sessionId: 's1',
      messages: messages(10),
      config: const EmbeddingConfig(endpoint: 'test'),
    );
    expect(embeddingService.requestCount, 2);
    repo.resetCounts();
    embeddingService.requestCount = 0;

    await service.indexSessionMessages(
      sessionId: 's1',
      messages: messages(10),
      config: const EmbeddingConfig(endpoint: 'test'),
    );

    expect(embeddingService.requestCount, 0);
    expect(repo.sourceLoads, 1);
    expect(repo.entryLoads, 0);
    expect(repo.bulkDeletes, 0);
  });

  test('removes tail chunks after the chat shrinks', () async {
    await seedChunk(0);
    await seedChunk(1);

    await service.indexSessionMessages(
      sessionId: 's1',
      messages: messages(5),
      config: const EmbeddingConfig(endpoint: 'test'),
    );

    expect(await repo.getByEntryId('s1_0'), isNotNull);
    expect(await repo.getByEntryId('s1_1'), isNull);
  });

  test('removes every chunk when fewer than five messages remain', () async {
    await seedChunk(0);
    await seedChunk(1);

    await service.indexSessionMessages(
      sessionId: 's1',
      messages: messages(4),
      config: const EmbeddingConfig(endpoint: 'test'),
    );

    expect(await repo.getBySourceId('s1'), isEmpty);
  });

  test('bulk stale cleanup is scoped to session and source type', () async {
    await seedChunk(0);
    await seedChunk(1);
    await repo.putEmbeddingVector(
      entryId: 'memory-s1',
      sourceType: 'memory_entry',
      sourceId: 's1',
      vectors: const [
        [1, 0],
      ],
      textHash: 'memory',
    );
    await repo.putEmbeddingVector(
      entryId: 's2_1',
      sourceType: 'chat_message',
      sourceId: 's2',
      vectors: const [
        [1, 0],
      ],
      textHash: 'other-session',
    );
    repo.resetCounts();

    await service.indexSessionMessages(
      sessionId: 's1',
      messages: messages(4),
      config: const EmbeddingConfig(endpoint: 'test'),
    );

    expect(await repo.getByEntryId('s1_0'), isNull);
    expect(await repo.getByEntryId('s1_1'), isNull);
    expect(await repo.getByEntryId('memory-s1'), isNotNull);
    expect(await repo.getByEntryId('s2_1'), isNotNull);
    expect(repo.sourceLoads, 1);
    expect(repo.bulkDeletes, 1);
  });
}
