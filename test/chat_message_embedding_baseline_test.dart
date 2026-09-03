// Run headlessly: flutter test test/chat_message_embedding_baseline_test.dart
//
// This is a deterministic reconciliation baseline: timings are logged for
// comparison, while operation counts and stored-row state are asserted.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/llm/chat_message_embedding_service.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

class _FakeEmbeddingService extends EmbeddingService {
  int requests = 0;
  int texts = 0;

  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> input,
    EmbeddingConfig config, {
    cancelToken,
    captureContext,
  }) async {
    requests++;
    texts += input.length;
    return [
      for (final text in input)
        EmbeddingChunk(text: text, vector: const [1, 0]),
    ];
  }

  void reset() {
    requests = 0;
    texts = 0;
  }
}

class _CountingEmbeddingRepo extends EmbeddingRepo {
  _CountingEmbeddingRepo(super.db);

  int sourceLoads = 0;
  int vectorWrites = 0;
  int bulkDeleteCalls = 0;
  int bulkDeletedEntryIds = 0;

  @override
  Future<List<EmbeddingRow>> getBySource(String sourceType, String sourceId) {
    sourceLoads++;
    return super.getBySource(sourceType, sourceId);
  }

  @override
  Future<void> putEmbeddingVector({
    required String entryId,
    required String sourceType,
    String? sourceId,
    required List<List<double>> vectors,
    required String textHash,
    List<String>? retrievalHints,
    Map<String, dynamic>? retrievalMetadata,
  }) {
    vectorWrites++;
    return super.putEmbeddingVector(
      entryId: entryId,
      sourceType: sourceType,
      sourceId: sourceId,
      vectors: vectors,
      textHash: textHash,
      retrievalHints: retrievalHints,
      retrievalMetadata: retrievalMetadata,
    );
  }

  @override
  Future<void> deleteBySourceAndEntryIds(
    String sourceType,
    String sourceId,
    Iterable<String> entryIds,
  ) {
    final ids = entryIds.toSet();
    bulkDeleteCalls++;
    bulkDeletedEntryIds += ids.length;
    return super.deleteBySourceAndEntryIds(sourceType, sourceId, ids);
  }

  void reset() {
    sourceLoads = 0;
    vectorWrites = 0;
    bulkDeleteCalls = 0;
    bulkDeletedEntryIds = 0;
  }
}

class _OperationCounts {
  const _OperationCounts({
    required this.sourceLoads,
    required this.vectorWrites,
    required this.embeddingRequests,
    required this.embeddedTexts,
    required this.bulkDeleteCalls,
    required this.bulkDeletedEntryIds,
  });

  final int sourceLoads;
  final int vectorWrites;
  final int embeddingRequests;
  final int embeddedTexts;
  final int bulkDeleteCalls;
  final int bulkDeletedEntryIds;

  @override
  String toString() =>
      'loads=$sourceLoads writes=$vectorWrites requests=$embeddingRequests '
      'texts=$embeddedTexts deleteCalls=$bulkDeleteCalls '
      'deletedIds=$bulkDeletedEntryIds';
}

void main() {
  const config = EmbeddingConfig(endpoint: 'test');
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

  List<ChatMessage> messages(int count) => [
    for (var index = 0; index < count; index++)
      ChatMessage(
        id: 'message-$index',
        role: index.isEven ? 'user' : 'assistant',
        content: 'baseline message $index',
      ),
  ];

  _OperationCounts counts() => _OperationCounts(
    sourceLoads: repo.sourceLoads,
    vectorWrites: repo.vectorWrites,
    embeddingRequests: embeddingService.requests,
    embeddedTexts: embeddingService.texts,
    bulkDeleteCalls: repo.bulkDeleteCalls,
    bulkDeletedEntryIds: repo.bulkDeletedEntryIds,
  );

  Future<void> reconcile({
    required String label,
    required String sessionId,
    required List<ChatMessage> input,
  }) async {
    repo.reset();
    embeddingService.reset();
    final stopwatch = Stopwatch()..start();
    await service.indexSessionMessages(
      sessionId: sessionId,
      messages: input,
      config: config,
    );
    stopwatch.stop();
    // Informational only: operation counters below are the test oracle.
    // ignore: avoid_print
    print(
      'embedding baseline [$label]: ${stopwatch.elapsedMilliseconds}ms; '
      '${counts()}',
    );
  }

  test('reconciles representative chat sizes with stable operation counts', () async {
    for (final messageCount in [25, 100]) {
      final sessionId = 'baseline-$messageCount';
      final original = messages(messageCount);
      final chunkCount = messageCount ~/ ChatMessageEmbeddingService.defaultChunkSize;

      await reconcile(
        label: '$messageCount initial',
        sessionId: sessionId,
        input: original,
      );
      expect(
        counts(),
        isA<_OperationCounts>()
            .having((value) => value.sourceLoads, 'source loads', 1)
            .having((value) => value.vectorWrites, 'vector writes', chunkCount)
            .having(
              (value) => value.embeddingRequests,
              'embedding requests',
              chunkCount,
            )
            .having((value) => value.embeddedTexts, 'embedded texts', chunkCount)
            .having((value) => value.bulkDeleteCalls, 'bulk delete calls', 0),
      );

      await reconcile(
        label: '$messageCount warm',
        sessionId: sessionId,
        input: original,
      );
      expect(counts().sourceLoads, 1);
      expect(counts().vectorWrites, 0);
      expect(counts().embeddingRequests, 0);
      expect(counts().bulkDeleteCalls, 0);

      for (final index in [0, messageCount ~/ 2, messageCount - 1]) {
        final modified = List<ChatMessage>.of(original);
        modified[index] = modified[index].copyWith(
          content: '${modified[index].content} (changed)',
        );

        await reconcile(
          label: '$messageCount modified-$index',
          sessionId: sessionId,
          input: modified,
        );
        expect(counts().sourceLoads, 1);
        expect(counts().vectorWrites, 1);
        expect(counts().embeddingRequests, 1);
        expect(counts().embeddedTexts, 1);
        expect(counts().bulkDeleteCalls, 0);

        // Restore the same baseline before measuring the next position.
        await reconcile(
          label: '$messageCount restore-$index',
          sessionId: sessionId,
          input: original,
        );
        expect(counts().vectorWrites, 1);
        expect(counts().embeddingRequests, 1);
      }

      final truncatedCount = messageCount - 5;
      await reconcile(
        label: '$messageCount truncated-$truncatedCount',
        sessionId: sessionId,
        input: original.take(truncatedCount).toList(),
      );
      final remainingChunks = truncatedCount ~/ ChatMessageEmbeddingService.defaultChunkSize;
      expect(counts().sourceLoads, 1);
      expect(counts().vectorWrites, 0);
      expect(counts().embeddingRequests, 0);
      expect(counts().bulkDeleteCalls, 1);
      expect(counts().bulkDeletedEntryIds, chunkCount - remainingChunks);
      expect(
        (await repo.getBySource('chat_message', sessionId))
            .map((row) => row.entryId)
            .toSet(),
        {
          for (var index = 0; index < remainingChunks; index++)
            '${sessionId}_$index',
        },
      );
    }
  });
}
