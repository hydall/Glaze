import '../../../core/models/memory_book.dart';

/// Applies a completed request to the current draft with [draftId].
///
/// The ID lookup is intentionally performed on the post-await book. Returning
/// `null` means the draft was deleted while generation was in flight.
MemoryBook? applyGeneratedMemoryDraft(
  MemoryBook currentBook, {
  required String draftId,
  required MemoryDraft generated,
}) {
  final index = currentBook.pendingDrafts.indexWhere((d) => d.id == draftId);
  if (index < 0) return null;

  final drafts = [...currentBook.pendingDrafts];
  final current = drafts[index];
  drafts[index] = current.copyWith(
    content: generated.content,
    keys: generated.keys,
    keyParagraphs: generated.keyParagraphs,
    ledgerRange: generated.ledgerRange,
    status: 'pending_approval',
    generatedAt: generated.generatedAt,
    updatedAt: generated.updatedAt,
    error: null,
  );
  return currentBook.copyWith(pendingDrafts: drafts);
}

/// Records a retryable generation error without discarding existing content.
MemoryBook? applyFailedMemoryDraftGeneration(
  MemoryBook currentBook, {
  required String draftId,
  required String error,
  required int updatedAt,
}) {
  final index = currentBook.pendingDrafts.indexWhere((d) => d.id == draftId);
  if (index < 0) return null;

  final drafts = [...currentBook.pendingDrafts];
  drafts[index] = drafts[index].copyWith(
    status: 'needs_regeneration',
    error: error,
    updatedAt: updatedAt,
  );
  return currentBook.copyWith(pendingDrafts: drafts);
}
