import 'dart:async';

import '../db/app_db.dart';
import '../db/repositories/embedding_repo.dart';
import '../db/repositories/lorebook_repo.dart';
import '../db/repositories/session_lorebook_embedding_job_repo.dart';
import '../db/repositories/session_lorebook_evolution_repo.dart';
import '../models/lorebook.dart';
import '../utils/cast_helpers.dart';
import 'embedding_service.dart';
import 'lorebook_embedding_service.dart';

class SessionLorebookEmbeddingWorker {
  SessionLorebookEmbeddingWorker({
    required AppDatabase db,
    required SessionLorebookEmbeddingJobRepo jobRepo,
    required SessionLorebookEvolutionRepo evolutionRepo,
    required LorebookRepo lorebookRepo,
    required EmbeddingRepo embeddingRepo,
    required EmbeddingService embeddingService,
    required EmbeddingConfig Function() readConfig,
  }) : this._(
         db,
         jobRepo,
         evolutionRepo,
         lorebookRepo,
         embeddingRepo,
         embeddingService,
         readConfig,
       );

  SessionLorebookEmbeddingWorker._(
    this._db,
    this._jobRepo,
    this._evolutionRepo,
    this._lorebookRepo,
    this._embeddingRepo,
    this._embeddingService,
    this._readConfig,
  );

  final AppDatabase _db;
  final SessionLorebookEmbeddingJobRepo _jobRepo;
  final SessionLorebookEvolutionRepo _evolutionRepo;
  final LorebookRepo _lorebookRepo;
  final EmbeddingRepo _embeddingRepo;
  final EmbeddingService _embeddingService;
  final EmbeddingConfig Function() _readConfig;

  Future<void>? _activeDrain;

  Future<void> recoverAndDrain() async {
    await _jobRepo.recoverInterrupted();
    await drain();
  }

  Future<void> drain() {
    final active = _activeDrain;
    if (active != null) return active;
    final work = _drain();
    _activeDrain = work;
    return work.whenComplete(() {
      if (identical(_activeDrain, work)) _activeDrain = null;
    });
  }

  Future<void> _drain() async {
    while (true) {
      final config = _readConfig();
      if (config.endpoint.trim().isEmpty) return;
      final job = await _jobRepo.claimNext();
      if (job == null) return;
      await _process(job, config);
    }
  }

  Future<void> _process(
    SessionLorebookEmbeddingJobRow job,
    EmbeddingConfig config,
  ) async {
    if (job.operation == 'delete') {
      await _db.transaction(() async {
        if (!await _isCurrent(job)) return;
        await _embeddingRepo.deleteByEntryId(_embeddingId(job));
        await _jobRepo.finish(
          id: job.id,
          expectedCheckpointId: job.checkpointId,
          expectedContentHash: job.expectedContentHash,
          succeeded: true,
        );
      });
      return;
    }

    final overlay = await _evolutionRepo.getByTarget(
      sessionId: job.chatSessionId,
      lorebookId: job.lorebookId,
      entryId: job.entryId,
    );
    if (overlay == null || overlay.contentHash != job.expectedContentHash) {
      await _supersede(job, 'overlayChanged');
      return;
    }
    final book = await _lorebookRepo.getById(job.lorebookId);
    final sourceEntry = book?.entries
        .where((entry) => entry.id == job.entryId)
        .firstOrNull;
    if (book == null || sourceEntry == null) {
      await _supersede(job, 'sourceEntryMissing');
      return;
    }
    final entry = sourceEntry.copyWith(content: overlay.content);
    if (!_isIndexable(entry)) {
      await _db.transaction(() async {
        if (!await _isCurrent(job)) return;
        await _embeddingRepo.deleteByEntryId(_embeddingId(job));
        await _jobRepo.finish(
          id: job.id,
          expectedCheckpointId: job.checkpointId,
          expectedContentHash: job.expectedContentHash,
          succeeded: true,
        );
      });
      return;
    }

    final text = book.settings?.embeddingTarget == 'keys'
        ? entry.keys.join(', ')
        : entry.content;
    final hints = LorebookEmbeddingService.extractRetrievalHints(entry);
    final textHash = computeHash(
      LorebookEmbeddingService.buildEmbeddingFingerprint(entry, text),
    );
    if (text.trim().isEmpty) {
      await _fail(job, 'emptyText');
      return;
    }

    try {
      final chunks = await _embeddingService.getEmbeddingsWithChunks([
        text,
      ], config);
      final vectors = chunks.map((chunk) => chunk.vector).toList();
      await _db.transaction(() async {
        final currentOverlay = await _evolutionRepo.getByTarget(
          sessionId: job.chatSessionId,
          lorebookId: job.lorebookId,
          entryId: job.entryId,
        );
        if (!await _isCurrent(job) ||
            currentOverlay?.contentHash != job.expectedContentHash) {
          return;
        }
        await _embeddingRepo.putEmbeddingVector(
          entryId: _embeddingId(job),
          sourceType: 'session_lorebook_entry',
          sourceId: job.chatSessionId,
          vectors: vectors,
          textHash: textHash,
          retrievalMetadata: embeddingMetadataForConfig(
            config,
            vectors,
            hints: hints,
          ),
        );
        await _jobRepo.finish(
          id: job.id,
          expectedCheckpointId: job.checkpointId,
          expectedContentHash: job.expectedContentHash,
          succeeded: true,
        );
      });
    } catch (error) {
      await _fail(job, error.toString());
    }
  }

  Future<bool> _isCurrent(SessionLorebookEmbeddingJobRow expected) async {
    final current = await _jobRepo.getById(expected.id);
    return current?.status == 'running' &&
        current?.checkpointId == expected.checkpointId &&
        current?.expectedContentHash == expected.expectedContentHash;
  }

  Future<void> _supersede(
    SessionLorebookEmbeddingJobRow job,
    String reason,
  ) async {
    await _jobRepo.supersede(
      id: job.id,
      expectedCheckpointId: job.checkpointId,
      expectedContentHash: job.expectedContentHash,
      reason: reason,
    );
  }

  Future<void> _fail(SessionLorebookEmbeddingJobRow job, String error) async {
    await _jobRepo.finish(
      id: job.id,
      expectedCheckpointId: job.checkpointId,
      expectedContentHash: job.expectedContentHash,
      succeeded: false,
      error: error,
    );
  }

  bool _isIndexable(LorebookEntry entry) =>
      entry.enabled &&
      !entry.constant &&
      !entry.excludeFromVectorization &&
      (entry.vectorSearch ||
          (entry.keys.isEmpty && entry.secondaryKeys.isEmpty));

  String _embeddingId(SessionLorebookEmbeddingJobRow job) =>
      '${job.chatSessionId}:${job.lorebookId}:${job.entryId}';
}
