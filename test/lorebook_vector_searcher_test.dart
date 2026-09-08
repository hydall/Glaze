import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/embedding_types.dart';
import 'package:glaze_flutter/core/llm/lorebook_vector_search.dart';
import 'package:glaze_flutter/core/llm/prompt/lorebook_vector_searcher.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_provider.dart';

class _StubVectorSearch extends LorebookVectorSearch {
  final Object? error;

  _StubVectorSearch(EmbeddingRepo repo, {this.error})
    : super(repo, EmbeddingService());

  @override
  Future<List<VectorSearchResult>> search(
    List<ChatMessageForSearch> history,
    String currentText,
    List<Lorebook> lorebooks,
    LorebookGlobalSettings settings,
    EmbeddingConfig config, {
    String? charWorld,
    Character? character,
    LorebookActivations? activations,
    String? chatId,
    int? overrideTopK,
    CancelToken? cancelToken,
  }) async {
    if (error != null) throw error!;
    return const [
      VectorSearchResult(entryId: 'entry', score: 0.9, lorebookId: 'book'),
    ];
  }
}

void main() {
  Future<({ProviderContainer container, AppDatabase db})> createContainer({
    Object? error,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = EmbeddingRepo(db);
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        lorebookSettingsProvider.overrideWith(
          (ref) => const LorebookGlobalSettings(searchType: 'vector'),
        ),
        embeddingConfigProvider.overrideWithValue(
          const EmbeddingConfig(endpoint: 'test', model: 'test'),
        ),
        lorebookVectorSearchProvider.overrideWithValue(
          _StubVectorSearch(repo, error: error),
        ),
      ],
    );
    await container
        .read(lorebookRepoProvider)
        .put(
          const Lorebook(
            id: 'book',
            name: 'Book',
            entries: [LorebookEntry(id: 'entry', content: 'content')],
          ),
        );
    return (container: container, db: db);
  }

  test(
    'returns mapped entries without emitting a diagnostic on success',
    () async {
      final fixture = await createContainer();
      addTearDown(fixture.container.dispose);
      addTearDown(fixture.db.close);
      final diagnostics = <LorebookVectorSearchDiagnostic>[];
      final searcherProvider = Provider(
        (ref) => LorebookVectorSearcher(ref, onDiagnostic: diagnostics.add),
      );

      final entries = await fixture.container
          .read(searcherProvider)
          .search(const [], 'query', null, null);

      expect(entries.single.id, 'entry');
      expect(entries.single.lorebookId, 'book');
      expect(entries.single.lorebookName, 'Book');
      expect(diagnostics, isEmpty);
    },
  );

  test('returns the empty fallback and emits the search failure', () async {
    final failure = StateError('embedding failed');
    final fixture = await createContainer(error: failure);
    addTearDown(fixture.container.dispose);
    addTearDown(fixture.db.close);
    final diagnostics = <LorebookVectorSearchDiagnostic>[];
    final searcherProvider = Provider(
      (ref) => LorebookVectorSearcher(ref, onDiagnostic: diagnostics.add),
    );

    final entries = await fixture.container
        .read(searcherProvider)
        .search(const [], 'query', null, null);

    expect(entries, isEmpty);
    expect(diagnostics, hasLength(1));
    expect(diagnostics.single.error, same(failure));
    expect(diagnostics.single.stackTrace, isNot(StackTrace.empty));
  });
}
