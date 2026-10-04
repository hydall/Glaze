import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/memory_book.dart';
import 'db_provider.dart';

class _MemoryBookOps {
  final Ref ref;
  _MemoryBookOps(this.ref);

  Future<MemoryBook> ensureForSession(String sessionId) async {
    return ref.read(memoryBookRepoProvider).ensureForSession(sessionId);
  }

  Future<void> saveMemoryBook(MemoryBook book) async {
    await ref.read(memoryBookRepoProvider).put(book);
  }

  Future<MemoryBook?> approveDraft(
    String sessionId,
    String draftId,
    MemoryDraft expected,
  ) => ref
      .read(memoryBookRepoProvider)
      .approveDraft(sessionId, draftId, expected);

  Future<MemoryEntry?> reviseEntry({
    required String sessionId,
    required MemoryEntry expected,
    required MemoryEntry proposed,
    String reason = 'manual_edit',
  }) => ref
      .read(memoryBookRepoProvider)
      .reviseEntry(
        sessionId: sessionId,
        expected: expected,
        proposed: proposed,
        reason: reason,
      );

  Future<MemoryEntry?> restoreEntryRevision({
    required String sessionId,
    required MemoryEntry expected,
    required String revisionId,
  }) => ref
      .read(memoryBookRepoProvider)
      .restoreEntryRevision(
        sessionId: sessionId,
        expected: expected,
        revisionId: revisionId,
      );

  Future<void> updateSettings(
    String sessionId,
    MemoryBookSettings settings,
  ) async {
    await ref.read(memoryBookRepoProvider).updateSettings(sessionId, settings);
  }

  Future<void> deleteEmbeddingEntry(String entryId) async {
    await ref.read(embeddingRepoProvider).deleteByEntryId(entryId);
  }
}

final memoryBookOpsProvider = Provider((ref) => _MemoryBookOps(ref));
