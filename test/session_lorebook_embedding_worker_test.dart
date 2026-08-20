import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_canon_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_lorebook_embedding_job_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_lorebook_evolution_repo.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/lorebook_embedding_service.dart';
import 'package:glaze_flutter/core/llm/session_lorebook_embedding_worker.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

class _ControlledEmbeddingService extends EmbeddingService {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    CancelToken? cancelToken,
  }) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return [
      for (final text in texts)
        EmbeddingChunk(text: text, vector: const [1, 0]),
    ];
  }
}

void main() {
  late AppDatabase db;
  late EmbeddingRepo embeddings;
  late LorebookRepo lorebooks;
  late SessionLorebookEvolutionRepo evolution;
  late SessionLorebookEmbeddingJobRepo jobs;
  late String checkpointId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    embeddings = EmbeddingRepo(db);
    lorebooks = LorebookRepo(db);
    evolution = SessionLorebookEvolutionRepo(db);
    jobs = SessionLorebookEmbeddingJobRepo(db);
    await db
        .into(db.characterRevisionRows)
        .insert(
          CharacterRevisionRowsCompanion.insert(
            characterId: 'character',
            revision: 1,
            revisionHash: 'revision-hash',
            snapshotJson: '{}',
          ),
        );
    checkpointId =
        (await SessionCanonCheckpointRepo(db).appendRootInTransaction(
          sessionId: 'session',
          characterId: 'character',
          characterRevision: 1,
          characterRevisionHash: 'revision-hash',
        )).id;
    await lorebooks.put(
      const Lorebook(
        id: 'book',
        name: 'Book',
        entries: [
          LorebookEntry(
            id: 'entry',
            content: 'base content',
            vectorSearch: true,
          ),
        ],
      ),
    );
  });

  tearDown(() => db.close());

  Future<String> putOverlay(String content, {String? expectedHash}) async {
    final expected =
        expectedHash ?? CardCanonicalizer.scalarSha256('base content');
    final mutation = await evolution.applyPatchesWithResultInTransaction(
      sessionId: 'session',
      lorebookId: 'book',
      entryId: 'entry',
      baseContent: 'base content',
      expectedContentHash: expected,
      patches: [
        LorebookAnchoredPatch(
          anchor: expectedHash == null ? 'base content' : 'session content',
          anchorSha256: CardCanonicalizer.scalarSha256(
            expectedHash == null ? 'base content' : 'session content',
          ),
          value: content,
        ),
      ],
    );
    return mutation!.contentHash;
  }

  SessionLorebookEmbeddingWorker worker(EmbeddingService service) =>
      SessionLorebookEmbeddingWorker(
        db: db,
        jobRepo: jobs,
        evolutionRepo: evolution,
        lorebookRepo: lorebooks,
        embeddingRepo: embeddings,
        embeddingService: service,
        readConfig: () =>
            const EmbeddingConfig(endpoint: 'test', model: 'model'),
      );

  test('publishes a session-scoped vector and completes the job', () async {
    final hash = await putOverlay('session content');
    final job = await jobs.enqueueInTransaction(
      sessionId: 'session',
      checkpointId: checkpointId,
      lorebookId: 'book',
      entryId: 'entry',
      expectedContentHash: hash,
    );
    final service = _ControlledEmbeddingService();
    final drain = worker(service).drain();
    await service.started.future;
    service.release.complete();
    await drain;

    final row = await embeddings.getByEntryId('session:book:entry');
    expect(row?.sourceType, 'session_lorebook_entry');
    expect(row?.sourceId, 'session');
    expect(embeddings.decodeVectors(row!), isNotEmpty);
    expect((await jobs.getById(job.id))?.status, 'succeeded');
  });

  test('a superseded in-flight job cannot publish stale vectors', () async {
    final firstHash = await putOverlay('session content');
    final first = await jobs.enqueueInTransaction(
      sessionId: 'session',
      checkpointId: checkpointId,
      lorebookId: 'book',
      entryId: 'entry',
      expectedContentHash: firstHash,
    );
    final service = _ControlledEmbeddingService();
    final drain = worker(service).drain();
    await service.started.future;

    final secondHash = await putOverlay(
      'newer content',
      expectedHash: firstHash,
    );
    final second = await jobs.enqueueInTransaction(
      sessionId: 'session',
      checkpointId: checkpointId,
      lorebookId: 'book',
      entryId: 'entry',
      expectedContentHash: secondHash,
    );
    service.release.complete();
    await drain;

    final row = await embeddings.getByEntryId('session:book:entry');
    const effectiveEntry = LorebookEntry(
      id: 'entry',
      content: 'newer content',
      vectorSearch: true,
    );
    expect(
      row?.textHash,
      computeHash(
        LorebookEmbeddingService.buildEmbeddingFingerprint(
          effectiveEntry,
          effectiveEntry.content,
        ),
      ),
    );
    expect((await jobs.getById(first.id))?.status, 'superseded');
    expect((await jobs.getById(second.id))?.status, 'succeeded');
  });
}
