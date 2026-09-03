import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/embedding_types.dart';
import 'package:glaze_flutter/core/llm/lorebook_embedding_service.dart';
import 'package:glaze_flutter/core/llm/lorebook_vector_search.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

class _BlockingEmbeddingService extends EmbeddingService {
  final release = Completer<void>();
  int calls = 0;
  int active = 0;
  int maxActive = 0;

  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    CancelToken? cancelToken,
    captureContext,
  }) async {
    calls++;
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await release.future;
      return [
        for (final text in texts)
          EmbeddingChunk(text: text, vector: const [1, 0]),
      ];
    } finally {
      active--;
    }
  }
}

class _RecordingEmbeddingService extends EmbeddingService {
  final queries = <String>[];

  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    CancelToken? cancelToken,
    captureContext,
  }) async {
    queries.addAll(texts);
    return [
      for (final text in texts)
        EmbeddingChunk(text: text, vector: const [1, 0]),
    ];
  }
}

class _RecordingEmbeddingRepo extends EmbeddingRepo {
  int sourceIdsCalls = 0;
  Set<String> requestedSourceIds = {};

  _RecordingEmbeddingRepo(super.db);

  @override
  Future<List<EmbeddingRow>> getBySourceIds(
    String sourceType,
    Iterable<String> sourceIds,
  ) {
    sourceIdsCalls++;
    requestedSourceIds = sourceIds.toSet();
    return super.getBySourceIds(sourceType, sourceIds);
  }
}

Future<void> _indexEntry(
  EmbeddingRepo repo,
  String lorebookId,
  LorebookEntry entry, {
  String? sessionId,
  EmbeddingConfig config = const EmbeddingConfig(
    endpoint: 'test',
    model: 'test',
  ),
}) async {
  final fingerprint = LorebookEmbeddingService.buildEmbeddingFingerprint(
    entry,
    entry.content,
  );
  await repo.putEmbeddingVector(
    entryId: sessionId == null
        ? '${lorebookId}_${entry.id}'
        : '$sessionId:$lorebookId:${entry.id}',
    sourceType: sessionId == null ? 'lorebook_entry' : 'session_lorebook_entry',
    sourceId: sessionId ?? lorebookId,
    vectors: const [
      [1, 0],
    ],
    textHash: computeHash(fingerprint),
    retrievalMetadata: embeddingMetadataForConfig(config, const [
      [1, 0],
    ]),
  );
}

void main() {
  testWidgets('shares focused query embedding across vector pools', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = EmbeddingRepo(db);
    final embeddings = _BlockingEmbeddingService();
    final search = LorebookVectorSearch(repo, embeddings);

    const mainEntry = LorebookEntry(
      id: 'main',
      content: 'main content',
      keys: ['main'],
      vectorSearch: true,
    );
    const keylessEntry = LorebookEntry(
      id: 'keyless',
      content: 'keyless content',
    );
    const lorebook = Lorebook(
      id: 'lb',
      name: 'Test',
      entries: [mainEntry, keylessEntry],
    );

    for (final entry in lorebook.entries) {
      final fingerprint = LorebookEmbeddingService.buildEmbeddingFingerprint(
        entry,
        entry.content,
      );
      await repo.putEmbeddingVector(
        entryId: 'lb_${entry.id}',
        sourceType: 'lorebook_entry',
        sourceId: 'lb',
        vectors: const [
          [1, 0],
        ],
        textHash: computeHash(fingerprint),
        retrievalMetadata: embeddingMetadataForConfig(
          const EmbeddingConfig(endpoint: 'test', model: 'test'),
          const [
            [1, 0],
          ],
        ),
      );
    }

    final pending = search.search(
      const [],
      'focused query',
      const [lorebook],
      const LorebookGlobalSettings(
        searchType: 'vector',
        vectorThreshold: 0,
        fallbackThreshold: 0,
      ),
      const EmbeddingConfig(endpoint: 'test', model: 'test'),
    );

    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(embeddings.calls, 1);
    expect(embeddings.maxActive, 1);

    embeddings.release.complete();
    await tester.pump();
    final results = await pending;
    expect(results.map((r) => r.entryId).toSet(), {'main', 'keyless'});
  });

  test('keeps same entry id from different lorebooks', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = _RecordingEmbeddingRepo(db);
    final embeddings = _RecordingEmbeddingService();
    final search = LorebookVectorSearch(repo, embeddings);

    const first = LorebookEntry(
      id: 'shared',
      content: 'first',
      vectorSearch: true,
    );
    const second = LorebookEntry(
      id: 'shared',
      content: 'second',
      vectorSearch: true,
    );
    await _indexEntry(repo, 'one', first);
    await _indexEntry(repo, 'two', second);
    await _indexEntry(repo, 'inactive', first);

    final results = await search.search(
      const [],
      'query',
      const [
        Lorebook(id: 'one', name: 'One', entries: [first]),
        Lorebook(id: 'two', name: 'Two', entries: [second]),
      ],
      const LorebookGlobalSettings(
        searchType: 'vector',
        vectorThreshold: 0,
        vectorTopK: 2,
      ),
      const EmbeddingConfig(endpoint: 'test', model: 'test'),
    );

    expect(results, hasLength(2));
    expect(results.map((r) => r.lorebookId).toSet(), {'one', 'two'});
    expect(repo.sourceIdsCalls, 1);
    expect(repo.requestedSourceIds, {'one', 'two'});
  });

  test('uses vector scan depth and does not duplicate current text', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = EmbeddingRepo(db);
    final embeddings = _RecordingEmbeddingService();
    final search = LorebookVectorSearch(repo, embeddings);
    const entry = LorebookEntry(
      id: 'entry',
      content: 'content',
      vectorSearch: true,
    );
    await _indexEntry(repo, 'lb', entry);

    await search.search(
      const [
        ChatMessageForSearch(role: 'user', content: 'stale topic'),
        ChatMessageForSearch(role: 'assistant', content: 'recent answer'),
        ChatMessageForSearch(role: 'user', content: 'current topic'),
      ],
      'current topic',
      const [
        Lorebook(
          id: 'lb',
          name: 'Book',
          entries: [entry],
          settings: LorebookSettings(vectorScanDepth: 2),
        ),
      ],
      const LorebookGlobalSettings(searchType: 'vector', vectorThreshold: 0),
      const EmbeddingConfig(endpoint: 'test', model: 'test'),
    );

    expect(embeddings.queries, isNotEmpty);
    expect(embeddings.queries.every((q) => !q.contains('stale topic')), isTrue);
    expect(
      embeddings.queries.every(
        (q) => RegExp('current topic').allMatches(q).length == 1,
      ),
      isTrue,
    );
  });

  test('overlay target never falls back to a global vector', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = EmbeddingRepo(db);
    final embeddings = _RecordingEmbeddingService();
    final search = LorebookVectorSearch(repo, embeddings);
    const globalEntry = LorebookEntry(
      id: 'entry',
      content: 'global content',
      vectorSearch: true,
    );
    const effectiveEntry = LorebookEntry(
      id: 'entry',
      content: 'session content',
      vectorSearch: true,
    );
    await _indexEntry(repo, 'book', globalEntry);

    final withoutSessionVector = await search.search(
      const [],
      'query',
      const [
        Lorebook(id: 'book', name: 'Book', entries: [effectiveEntry]),
      ],
      const LorebookGlobalSettings(searchType: 'vector', vectorThreshold: 0),
      const EmbeddingConfig(endpoint: 'test', model: 'test'),
      chatId: 'session',
      sessionOverlayTargets: const {(lorebookId: 'book', entryId: 'entry')},
    );
    expect(withoutSessionVector, isEmpty);
    expect(embeddings.queries, isEmpty);

    await _indexEntry(repo, 'book', effectiveEntry, sessionId: 'session');
    final withSessionVector = await search.search(
      const [],
      'query',
      const [
        Lorebook(id: 'book', name: 'Book', entries: [effectiveEntry]),
      ],
      const LorebookGlobalSettings(searchType: 'vector', vectorThreshold: 0),
      const EmbeddingConfig(endpoint: 'test', model: 'test'),
      chatId: 'session',
      sessionOverlayTargets: const {(lorebookId: 'book', entryId: 'entry')},
    );
    expect(withSessionVector.single.entryId, 'entry');
  });

  test('rejects vectors from a different embedding signature', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = EmbeddingRepo(db);
    final embeddings = _RecordingEmbeddingService();
    final search = LorebookVectorSearch(repo, embeddings);
    const entry = LorebookEntry(
      id: 'entry',
      content: 'content',
      vectorSearch: true,
    );
    await _indexEntry(
      repo,
      'book',
      entry,
      config: const EmbeddingConfig(
        endpoint: 'https://old.example',
        model: 'model',
      ),
    );

    final results = await search.search(
      const [],
      'query',
      const [
        Lorebook(id: 'book', name: 'Book', entries: [entry]),
      ],
      const LorebookGlobalSettings(searchType: 'vector', vectorThreshold: 0),
      const EmbeddingConfig(endpoint: 'https://new.example', model: 'model'),
    );
    expect(results, isEmpty);
    expect(embeddings.queries, isEmpty);
  });
}
