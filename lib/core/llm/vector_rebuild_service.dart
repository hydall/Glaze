import 'package:flutter/foundation.dart';

import '../db/repositories/chat_repo.dart';
import '../db/repositories/embedding_repo.dart';
import '../db/repositories/lorebook_repo.dart';
import '../db/repositories/memory_book_repo.dart';
import '../models/chat_message.dart';
import 'chat_message_embedding_service.dart';
import 'embedding_service.dart';
import 'lorebook_embedding_service.dart';
import 'memory_embedding_service.dart';

enum VectorRebuildSource { memoryBooks, lorebooks, rawChat }

class VectorRebuildRequest {
  final Set<VectorRebuildSource> sources;
  final int vectorsPerMinute;
  final int batchSize;
  final bool forceReindex;

  const VectorRebuildRequest({
    required this.sources,
    this.vectorsPerMinute = 30,
    this.batchSize = 10,
    this.forceReindex = false,
  });
}

class VectorRebuildResult {
  final int total;
  final int indexed;
  final int skipped;
  final int failed;
  final bool cancelled;

  const VectorRebuildResult({
    required this.total,
    required this.indexed,
    required this.skipped,
    required this.failed,
    this.cancelled = false,
  });
}

class VectorRebuildService {
  final ChatRepo _chatRepo;
  final MemoryBookRepo _memoryBookRepo;
  final LorebookRepo _lorebookRepo;
  final EmbeddingRepo _embeddingRepo;
  final MemoryEmbeddingService _memoryEmbeddingService;
  final LorebookEmbeddingService _lorebookEmbeddingService;
  final ChatMessageEmbeddingService _chatMessageEmbeddingService;
  final EmbeddingConfig _config;

  const VectorRebuildService(
    this._chatRepo,
    this._memoryBookRepo,
    this._lorebookRepo,
    this._embeddingRepo,
    this._memoryEmbeddingService,
    this._lorebookEmbeddingService,
    this._chatMessageEmbeddingService,
    this._config,
  );

  Future<VectorRebuildResult> rebuild(
    VectorRebuildRequest request, {
    bool Function()? isCancelled,
    Future<void> Function()? waitIfPaused,
    void Function(int total)? onPrepared,
    void Function(int current, String label, String sourceLabel)? onTaskStarted,
    void Function(int current, VectorRebuildResult result)? onTaskCompleted,
  }) async {
    final tasks = await _buildTasks(request);
    onPrepared?.call(tasks.length);
    var indexed = 0;
    var skipped = 0;
    var failed = 0;
    final delay = vectorRebuildDelayForRate(request.vectorsPerMinute);
    final batchSize = request.batchSize < 1 ? 1 : request.batchSize;

    for (var i = 0; i < tasks.length; i++) {
      if (isCancelled?.call() == true) {
        return VectorRebuildResult(
          total: tasks.length,
          indexed: indexed,
          skipped: skipped,
          failed: failed,
          cancelled: true,
        );
      }
      await waitIfPaused?.call();
      if (isCancelled?.call() == true) {
        return VectorRebuildResult(
          total: tasks.length,
          indexed: indexed,
          skipped: skipped,
          failed: failed,
          cancelled: true,
        );
      }

      final task = tasks[i];
      onTaskStarted?.call(i, task.label, task.sourceLabel);
      try {
        final result = await task.run();
        indexed += result.indexed;
        skipped += result.skipped;
        failed += result.failed;
      } catch (e) {
        debugPrint('[VectorRebuild] failed task=${task.label}: $e');
        failed++;
      }

      final current = i + 1;
      onTaskCompleted?.call(
        current,
        VectorRebuildResult(
          total: tasks.length,
          indexed: indexed,
          skipped: skipped,
          failed: failed,
        ),
      );
      if (current < tasks.length && delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      if (current % batchSize == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    return VectorRebuildResult(
      total: tasks.length,
      indexed: indexed,
      skipped: skipped,
      failed: failed,
    );
  }

  Future<List<_VectorRebuildTask>> _buildTasks(
    VectorRebuildRequest request,
  ) async {
    final tasks = <_VectorRebuildTask>[];

    if (request.sources.contains(VectorRebuildSource.memoryBooks)) {
      final sessions = await _chatRepo.getAllSessions();
      final charBySession = {
        for (final session in sessions) session.id: session.characterId,
      };
      final books = await _memoryBookRepo.getAll();
      for (final book in books) {
        final charId = charBySession[book.sessionId];
        if (charId == null) continue;
        for (final entry in book.entries) {
          if (entry.status != 'active') continue;
          tasks.add(
            _VectorRebuildTask(
              sourceLabel: 'MemoryBook',
              label: entry.title.isNotEmpty ? entry.title : entry.id,
              run: () async {
                if (request.forceReindex) {
                  await _embeddingRepo.deleteByEntryId(entry.id);
                }
                await _memoryEmbeddingService.indexMemoryEntry(
                  entry,
                  charId: charId,
                  sessionId: book.sessionId,
                  config: _config,
                );
                return const _VectorTaskResult(indexed: 1);
              },
            ),
          );
        }
      }
    }

    if (request.sources.contains(VectorRebuildSource.lorebooks)) {
      final lorebooks = await _lorebookRepo.getAll();
      for (final lorebook in lorebooks) {
        for (final entry in lorebook.entries) {
          if (!entry.enabled || entry.constant) continue;
          if (entry.excludeFromVectorization) continue;
          if (!entry.vectorSearch &&
              (entry.keys.isNotEmpty || entry.secondaryKeys.isNotEmpty)) {
            continue;
          }
          tasks.add(
            _VectorRebuildTask(
              sourceLabel: 'Lorebook',
              label:
                  '${lorebook.name}: ${entry.comment.isNotEmpty ? entry.comment : entry.id}',
              run: () async {
                final result = await _lorebookEmbeddingService
                    .indexLorebookEntries(
                      lorebook.id,
                      [entry],
                      _config,
                      forceReindex: request.forceReindex,
                      embeddingTarget:
                          lorebook.settings?.embeddingTarget ?? 'content',
                    );
                return _VectorTaskResult(
                  indexed: result.indexed,
                  skipped: result.skipped,
                  failed: result.failed,
                );
              },
            ),
          );
        }
      }
    }

    if (request.sources.contains(VectorRebuildSource.rawChat)) {
      final sessions = await _chatRepo.getAllSessions();
      for (final session in sessions) {
        final eligibleCount = session.messages
            .where(_isEmbeddableMessage)
            .length;
        if (eligibleCount < ChatMessageEmbeddingService.defaultChunkSize) {
          continue;
        }
        tasks.add(
          _VectorRebuildTask(
            sourceLabel: 'Raw chat',
            label: 'Session ${session.sessionIndex}',
            run: () async {
              if (request.forceReindex) {
                await _embeddingRepo.deleteBySourceId(session.id);
              }
              await _chatMessageEmbeddingService.indexSessionMessages(
                sessionId: session.id,
                messages: session.messages,
                config: _config,
              );
              return const _VectorTaskResult(indexed: 1);
            },
          ),
        );
      }
    }

    return tasks;
  }
}

Duration vectorRebuildDelayForRate(int vectorsPerMinute) {
  if (vectorsPerMinute <= 0) return Duration.zero;
  return Duration(milliseconds: (60000 / vectorsPerMinute).round());
}

bool _isEmbeddableMessage(ChatMessage message) {
  return !message.isTyping &&
      !message.isHidden &&
      !message.isError &&
      message.id.isNotEmpty &&
      message.content.trim().isNotEmpty &&
      (message.role == 'user' || message.role == 'assistant');
}

class _VectorRebuildTask {
  final String sourceLabel;
  final String label;
  final Future<_VectorTaskResult> Function() run;

  const _VectorRebuildTask({
    required this.sourceLabel,
    required this.label,
    required this.run,
  });
}

class _VectorTaskResult {
  final int indexed;
  final int skipped;
  final int failed;

  const _VectorTaskResult({
    this.indexed = 0,
    this.skipped = 0,
    this.failed = 0,
  });
}
