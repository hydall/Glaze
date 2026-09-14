import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/lorebook_embedding_service.dart';
import 'package:glaze_flutter/core/llm/lorebook_embedding_text.dart';
import 'package:glaze_flutter/core/llm/lorebook_vector_search.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';

class _FakeEmbeddingService extends EmbeddingService {
  final List<String> requestedTexts = [];

  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    CancelToken? cancelToken,
    captureContext,
  }) async {
    requestedTexts.addAll(texts);
    return [
      for (final text in texts)
        EmbeddingChunk(text: text, vector: const [1, 0]),
    ];
  }
}

const _config = EmbeddingConfig(endpoint: 'test', model: 'test');

const _entry = LorebookEntry(
  id: 'entry',
  comment: 'The Tower',
  keys: ['tower', 'spire'],
  content: 'A black spire over the harbour.',
  vectorSearch: true,
);

Lorebook _book(String target, {bool vectorizeAll = false}) => Lorebook(
  id: 'lb',
  name: 'Test',
  entries: const [_entry],
  settings: LorebookSettings(
    embeddingTarget: target,
    vectorizeAllEntries: vectorizeAll,
  ),
);

void main() {
  group('lorebookEmbeddingText', () {
    test('resolves every target', () {
      expect(
        lorebookEmbeddingText(_entry, LorebookEmbeddingTarget.content),
        'A black spire over the harbour.',
      );
      expect(
        lorebookEmbeddingText(_entry, LorebookEmbeddingTarget.comment),
        'The Tower',
      );
      expect(
        lorebookEmbeddingText(_entry, LorebookEmbeddingTarget.keys),
        'tower, spire',
      );
      expect(
        lorebookEmbeddingText(_entry, LorebookEmbeddingTarget.both),
        'The Tower\nA black spire over the harbour.',
      );
    });

    test('an unset or unknown target embeds the content', () {
      expect(lorebookEmbeddingText(_entry, null), _entry.content);
      expect(lorebookEmbeddingText(_entry, 'nonsense'), _entry.content);
    });

    test('falls back to the content when the chosen field is empty', () {
      const untitled = LorebookEntry(id: 'e', content: 'body');
      expect(
        lorebookEmbeddingText(untitled, LorebookEmbeddingTarget.comment),
        'body',
      );
      expect(
        lorebookEmbeddingText(untitled, LorebookEmbeddingTarget.keys),
        'body',
      );
      expect(
        lorebookEmbeddingText(untitled, LorebookEmbeddingTarget.both),
        'body',
      );
    });
  });

  group('lorebookVectorPoolFor', () {
    test('sorts entries into the main and keyless pools', () {
      expect(
        lorebookVectorPoolFor(
          const LorebookEntry(id: 'a', content: 'x', vectorSearch: true),
        ),
        LorebookVectorPool.main,
      );
      expect(
        lorebookVectorPoolFor(const LorebookEntry(id: 'b', content: 'x')),
        LorebookVectorPool.fallback,
      );
      expect(
        lorebookVectorPoolFor(
          const LorebookEntry(id: 'c', content: 'x', keys: ['k']),
        ),
        LorebookVectorPool.none,
      );
    });

    test('vectorizeAll promotes every keyed entry into the main pool', () {
      expect(
        lorebookVectorPoolFor(
          const LorebookEntry(id: 'c', content: 'x', keys: ['k']),
          vectorizeAll: true,
        ),
        LorebookVectorPool.main,
      );
      expect(
        lorebookVectorPoolFor(
          const LorebookEntry(id: 'd', content: 'x'),
          vectorizeAll: true,
        ),
        LorebookVectorPool.main,
      );
    });

    test('opted-out, disabled and constant entries stay out', () {
      for (final entry in const [
        LorebookEntry(
          id: 'a',
          content: 'x',
          vectorSearch: true,
          excludeFromVectorization: true,
        ),
        LorebookEntry(
          id: 'b',
          content: 'x',
          vectorSearch: true,
          enabled: false,
        ),
        LorebookEntry(
          id: 'c',
          content: 'x',
          vectorSearch: true,
          constant: true,
        ),
      ]) {
        expect(
          lorebookVectorPoolFor(entry, vectorizeAll: true),
          LorebookVectorPool.none,
          reason: entry.id,
        );
      }
    });
  });

  group('index and search agree', () {
    // The indexer stores a hash of the embedded text and the search recomputes
    // it to decide whether the stored vector still describes the entry. If the
    // two build that text differently the entry silently drops out of the
    // vector pass, so every target is checked end to end.
    for (final target in LorebookEmbeddingTarget.values) {
      test('target "$target" survives the fingerprint check', () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = EmbeddingRepo(db);
        final embeddings = _FakeEmbeddingService();
        final book = _book(target);

        final indexed = await LorebookEmbeddingService(repo, embeddings)
            .indexLorebookEntries(
              'lb',
              book.entries,
              _config,
              embeddingTarget: target,
            );
        expect(indexed.indexed, 1);
        expect(
          embeddings.requestedTexts.single,
          lorebookEmbeddingText(_entry, target),
        );

        final results = await LorebookVectorSearch(repo, embeddings).search(
          const [],
          'a spire over the harbour',
          [book],
          const LorebookGlobalSettings(
            searchType: 'vector',
            vectorThreshold: 0,
          ),
          _config,
        );
        expect(results.map((r) => r.entryId), ['entry']);
      });
    }

    test('a changed target invalidates the stored vector', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = EmbeddingRepo(db);
      final embeddings = _FakeEmbeddingService();

      await LorebookEmbeddingService(repo, embeddings).indexLorebookEntries(
        'lb',
        [_entry],
        _config,
        embeddingTarget: LorebookEmbeddingTarget.content,
      );

      // The book now embeds the title, so the row written for the body no
      // longer describes the entry and must not be searched against.
      final results = await LorebookVectorSearch(repo, embeddings).search(
        const [],
        'the tower',
        [_book(LorebookEmbeddingTarget.comment)],
        const LorebookGlobalSettings(searchType: 'vector', vectorThreshold: 0),
        _config,
      );
      expect(results, isEmpty);
    });
  });

  group('vectorizeAllEntries', () {
    test('indexes and finds a keyed entry that never opted in', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = EmbeddingRepo(db);
      final embeddings = _FakeEmbeddingService();
      const keyword = LorebookEntry(
        id: 'keyword-only',
        keys: ['harbour'],
        content: 'The harbour freezes in winter.',
      );
      final book = Lorebook(
        id: 'lb',
        name: 'Test',
        entries: const [keyword],
        settings: const LorebookSettings(vectorizeAllEntries: true),
      );

      final indexed = await LorebookEmbeddingService(
        repo,
        embeddings,
      ).indexLorebookEntries('lb', book.entries, _config, vectorizeAll: true);
      expect(indexed.indexed, 1);

      final results = await LorebookVectorSearch(repo, embeddings).search(
        const [],
        'winter in the harbour',
        [book],
        const LorebookGlobalSettings(searchType: 'vector', vectorThreshold: 0),
        _config,
      );
      expect(results.map((r) => r.entryId), ['keyword-only']);
    });

    test('is off by default, matching SillyTavern', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = EmbeddingRepo(db);
      final embeddings = _FakeEmbeddingService();
      const keyword = LorebookEntry(
        id: 'keyword-only',
        keys: ['harbour'],
        content: 'The harbour freezes in winter.',
      );

      final indexed = await LorebookEmbeddingService(
        repo,
        embeddings,
      ).indexLorebookEntries('lb', const [keyword], _config);
      expect(indexed.indexed, 0);
      expect(const LorebookSettings().vectorizeAllEntries, isFalse);
    });
  });
}
