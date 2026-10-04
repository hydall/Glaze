import 'dart:async';

/// Serializes every durable session write issued by one chat's controllers.
///
/// Message deletion publishes the shortened list optimistically and commits in
/// the background (`ChatMessageOpsController.deleteMessages`). Every other
/// mutation — swipe/agent-swipe switch, greeting switch, edit, move, hide —
/// commits through `ChatRepo.mutateMessages`, which re-reads the *durable* row
/// inside its transaction. With one queue per operation kind those two run
/// concurrently, and the mutation reads the pre-delete row: it writes back the
/// messages the delete had already taken off screen, so deleted messages come
/// back the moment you flip a variation.
///
/// One queue shared by all of them keeps the durable row moving in UI order:
/// a mutation enqueued after a delete only starts once that delete's
/// transaction has committed, so it reads the post-delete message list.
///
/// Never call [run] from inside an operation that is already running on this
/// queue — the inner call would wait on its own enclosing operation.
class ChatSessionWriteQueue {
  Future<void> _tail = Future<void>.value();

  int _publishSeq = 0;

  /// Claims the right to publish the next session snapshot, invalidating every
  /// claim made before it. Call it *synchronously*, before the first await, so
  /// the order of claims is the order the user tapped in.
  ///
  /// Ordering the writes is not enough on its own: a commit re-reads the
  /// durable row as it was when its turn came up, which is older than whatever
  /// a later operation has already painted optimistically. Publishing it would
  /// undo that paint — a variation switch that commits after a delete was
  /// optimistically applied would put the deleted bubbles back on screen even
  /// though the delete's own transaction lands right after. The later claim
  /// wins; the older commit still writes, it just doesn't repaint.
  int beginPublication() => ++_publishSeq;

  /// Whether [token] is still the newest claim.
  bool isCurrentPublication(int token) => token == _publishSeq;

  /// Runs [operation] after every write enqueued before it has settled.
  /// Returns the operation's own future, so callers still see its result and
  /// its errors; a failed write does not poison the queue for later ones.
  Future<T> run<T>(Future<T> Function() operation) {
    final previous = _tail;
    final next = () async {
      try {
        await previous;
      } catch (_) {
        // A failed write must not permanently block the queue.
      }
      return operation();
    }();
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// Waits until every write enqueued before or during the wait has settled.
  ///
  /// Generation uses this as a durability barrier after an optimistic message
  /// deletion: its prompt must not read canon state before the delete's
  /// multi-table rollback transaction has completed.
  Future<void> settle() async {
    while (true) {
      final pending = _tail;
      await pending;
      if (identical(pending, _tail)) return;
    }
  }
}
