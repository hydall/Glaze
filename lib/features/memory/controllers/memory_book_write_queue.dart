import '../../../core/models/memory_book.dart';

/// Serializes MemoryBook persistence for the sheet's own edits.
///
/// [saveLatest] deliberately reads the book only after earlier writes finish,
/// so two edits made in quick succession are written in order rather than as
/// competing snapshots. Draft generation does not come through here at all —
/// it outlives the sheet, so it writes its one draft through the repository's
/// own transaction (`MemoryBookRepo.mutateDraft`).
class MemoryBookWriteQueue {
  final MemoryBook? Function() readLatest;
  final Future<void> Function(MemoryBook book) persist;

  Future<void> _tail = Future<void>.value();

  MemoryBookWriteQueue({required this.readLatest, required this.persist});

  Future<void> saveLatest() => _enqueue(() async {
    final latest = readLatest();
    if (latest != null) await persist(latest);
  });

  Future<void> runDurableOperation(Future<void> Function() operation) =>
      _enqueue(operation);
  Future<void> _enqueue(Future<void> Function() operation) {
    final previous = _tail;
    final next = () async {
      try {
        await previous;
      } catch (_) {
        // One failed write must not poison subsequent queued operations.
      }
      await operation();
    }();
    _tail = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }
}
