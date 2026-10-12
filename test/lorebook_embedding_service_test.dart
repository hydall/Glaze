import 'package:drift/native.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/lorebook_embedding_service.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

class _FakeEmbeddingService extends EmbeddingService {
  final List<String> requestedTexts = [];
  final List<LlmCaptureContext?> contexts = [];

  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    CancelToken? cancelToken,
    captureContext,
  }) async {
    requestedTexts.addAll(texts);
    contexts.add(captureContext);
    return [
      for (final text in texts)
        EmbeddingChunk(text: text, vector: const [1, 0]),
    ];
  }
}

void main() {
  test('one indexing pass is one capture run with a call per entry', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final embeddingService = _FakeEmbeddingService();
    final service = LorebookEmbeddingService(EmbeddingRepo(db), embeddingService);

    await service.indexLorebookEntries(
      'book',
      const [
        LorebookEntry(id: 'a', content: 'first', vectorSearch: true),
        LorebookEntry(id: 'b', content: 'second', vectorSearch: true),
      ],
      const EmbeddingConfig(endpoint: 'http://localhost/v1', model: 'test'),
    );

    final contexts = embeddingService.contexts.whereType<LlmCaptureContext>();
    expect(contexts, hasLength(2));
    expect(contexts.map((c) => c.stage).toSet(), {'embedding.lorebook_index'});
    expect(contexts.map((c) => c.pipelineRunId).toSet(), hasLength(1));
    expect(contexts.map((c) => c.callId).toSet(), hasLength(2));
    expect(contexts.every((c) => c.sessionId == null), isTrue);
  });

  test('keys embedding target indexes and fingerprints entry keys', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = EmbeddingRepo(db);
    final embeddingService = _FakeEmbeddingService();
    final service = LorebookEmbeddingService(repo, embeddingService);
    const entry = LorebookEntry(
      id: 'entry',
      keys: ['alpha', 'beta'],
      content: 'content must not be embedded',
      vectorSearch: true,
    );
    const config = EmbeddingConfig(
      endpoint: 'http://localhost/v1',
      model: 'test',
    );

    final result = await service.indexLorebookEntries(
      'book',
      const [entry],
      config,
      embeddingTarget: 'keys',
    );

    expect(result.indexed, 1);
    expect(embeddingService.requestedTexts, ['alpha, beta']);
    final row = await repo.getByEntryId('book_entry');
    expect(
      row?.textHash,
      computeHash(
        LorebookEmbeddingService.buildEmbeddingFingerprint(
          entry,
          'alpha, beta',
        ),
      ),
    );
  });

  test('matching text with a stale model signature is reindexed', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = EmbeddingRepo(db);
    final embeddingService = _FakeEmbeddingService();
    final service = LorebookEmbeddingService(repo, embeddingService);
    const entry = LorebookEntry(
      id: 'entry',
      content: 'content',
      vectorSearch: true,
    );
    final hash = computeHash(
      LorebookEmbeddingService.buildEmbeddingFingerprint(entry, entry.content),
    );
    await repo.putEmbeddingVector(
      entryId: 'book_entry',
      sourceType: 'lorebook_entry',
      sourceId: 'book',
      vectors: const [
        [1, 0],
      ],
      textHash: hash,
      retrievalMetadata: embeddingMetadataForConfig(
        const EmbeddingConfig(endpoint: 'https://old.example', model: 'model'),
        const [
          [1, 0],
        ],
      ),
    );

    final result = await service.indexLorebookEntries('book', const [
      entry,
    ], const EmbeddingConfig(endpoint: 'https://new.example', model: 'model'));
    expect(result.indexed, 1);
    expect(embeddingService.requestedTexts, ['content']);
  });
}
