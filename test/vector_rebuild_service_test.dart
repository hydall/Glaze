import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_repo.dart';
import 'package:glaze_flutter/core/llm/chat_message_embedding_service.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/lorebook_embedding_service.dart';
import 'package:glaze_flutter/core/llm/memory_embedding_service.dart';
import 'package:glaze_flutter/core/llm/vector_rebuild_service.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';

void main() {
  group('vectorRebuildDelayForRate', () {
    test('returns zero delay when rate limit is disabled', () {
      expect(vectorRebuildDelayForRate(0), Duration.zero);
      expect(vectorRebuildDelayForRate(-5), Duration.zero);
    });

    test('converts vectors per minute into inter-task delay', () {
      expect(vectorRebuildDelayForRate(60), const Duration(seconds: 1));
      expect(vectorRebuildDelayForRate(30), const Duration(seconds: 2));
    });
  });

  test(
    'constructor-injected service completes when repositories are empty',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      final embeddingRepo = EmbeddingRepo(db);
      final embeddingService = EmbeddingService();
      final service = VectorRebuildService(
        ChatRepo(db),
        container.read(memoryBookRepoProvider),
        LorebookRepo(db),
        embeddingRepo,
        MemoryEmbeddingService(embeddingRepo, embeddingService),
        LorebookEmbeddingService(embeddingRepo, embeddingService),
        ChatMessageEmbeddingService(embeddingRepo, embeddingService),
        const EmbeddingConfig(endpoint: 'http://localhost/v1', model: 'test'),
      );

      final result = await service.rebuild(
        const VectorRebuildRequest(
          sources: {
            VectorRebuildSource.memoryBooks,
            VectorRebuildSource.lorebooks,
            VectorRebuildSource.rawChat,
          },
          vectorsPerMinute: 0,
        ),
      );

      expect(result.total, 0);
      expect(result.cancelled, isFalse);
      expect(result.failed, 0);
    },
  );

  test("clearExisting deletes only the selected sources' vectors", () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final embeddingRepo = EmbeddingRepo(db);
    final embeddingService = EmbeddingService();
    const config = EmbeddingConfig(endpoint: 'http://localhost/v1', model: 't');
    final service = VectorRebuildService(
      ChatRepo(db),
      container.read(memoryBookRepoProvider),
      LorebookRepo(db),
      embeddingRepo,
      MemoryEmbeddingService(embeddingRepo, embeddingService),
      LorebookEmbeddingService(embeddingRepo, embeddingService),
      ChatMessageEmbeddingService(embeddingRepo, embeddingService),
      config,
    );
    // Orphans: their lorebook and memory book no longer exist.
    for (final (id, type) in [
      ('orphan_lore', 'lorebook_entry'),
      ('orphan_mem', 'memory_entry'),
    ]) {
      await embeddingRepo.putEmbeddingVector(
        entryId: id,
        sourceType: type,
        vectors: const [
          [0.1, 0.2],
        ],
        textHash: 'h',
        retrievalMetadata: embeddingMetadataForConfig(config, const [
          [0.1, 0.2],
        ]),
      );
    }

    // A forced rebuild keeps vectors it has no entry for.
    await service.rebuild(
      const VectorRebuildRequest(
        sources: {VectorRebuildSource.lorebooks},
        vectorsPerMinute: 0,
        forceReindex: true,
      ),
    );
    expect(await embeddingRepo.getByEntryId('orphan_lore'), isNotNull);

    await service.rebuild(
      const VectorRebuildRequest(
        sources: {VectorRebuildSource.lorebooks},
        vectorsPerMinute: 0,
        clearExisting: true,
      ),
    );
    expect(await embeddingRepo.getByEntryId('orphan_lore'), isNull);
    expect(await embeddingRepo.getByEntryId('orphan_mem'), isNotNull);
  });

  group('embedding stale metadata', () {
    test(
      'counts rows whose embedding signature differs from current config',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = EmbeddingRepo(db);
        const oldConfig = EmbeddingConfig(
          endpoint: 'http://old/v1',
          model: 'old-embed',
        );
        const newConfig = EmbeddingConfig(
          endpoint: 'http://new/v1',
          model: 'new-embed',
        );

        await repo.putEmbeddingVector(
          entryId: 'e1',
          sourceType: 'memory_entry',
          vectors: const [
            [0.1, 0.2],
          ],
          textHash: 'h1',
          retrievalMetadata: embeddingMetadataForConfig(oldConfig, const [
            [0.1, 0.2],
          ]),
        );
        await repo.putEmbeddingVector(
          entryId: 'e2',
          sourceType: 'lorebook_entry',
          vectors: const [
            [0.3, 0.4],
          ],
          textHash: 'h2',
          retrievalMetadata: embeddingMetadataForConfig(newConfig, const [
            [0.3, 0.4],
          ]),
        );

        final stats = await repo.getStaleStats(
          embeddingModelSignature(newConfig),
        );
        expect(stats.total, 2);
        expect(stats.stale, 1);
        expect(stats.bySource['memory_entry'], 1);
      },
    );
  });
}
