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
