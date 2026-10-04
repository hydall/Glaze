import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/db_provider.dart';
import '../chat_session_service.dart';
import '../chat_state.dart';
import '../state/chat_session_write_queue.dart';

class ChatDraftController {
  final Ref _ref;
  final void Function(AsyncValue<ChatState>) _setState;
  final AsyncValue<ChatState> Function() _getState;

  /// The same queue every other durable session write goes through. A draft
  /// write is a write to the session row, and the row's `draft` column is
  /// cleared by the send's append — so the two must not be left to race. On
  /// the queue the ordering is the order the user acted in: a draft saved
  /// before Send commits first and the append clears it, and a draft typed
  /// during a slow send commits after the append instead of being dropped by
  /// the message-count guard below.
  final ChatSessionWriteQueue _writes;

  int _saveEpoch = 0;

  ChatDraftController({
    required this._ref,
    required this._setState,
    required this._getState,
    required this._writes,
  });

  /// Persists the composer's contents as this session's draft.
  ///
  /// The epoch is claimed synchronously, before the queue wait, so the newest
  /// debounce is the one that lands however long the queue takes to reach it.
  Future<void> saveDraft(String draftText) {
    final epoch = ++_saveEpoch;
    return _writes.run(() => _commitDraft(draftText, epoch));
  }

  Future<void> _commitDraft(String draftText, int epoch) async {
    if (!_ref.mounted) return;
    if (epoch != _saveEpoch) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;

    final sessionId = current.session!.id;
    // Read inside the operation, not before the queue wait: the count has to
    // describe the row this write is about to land on. A draft typed while a
    // send was still encoding used to carry the pre-append count and be
    // rejected outright, which lost the user's next message.
    final expectedMessageCount = current.session!.messages.length;
    // Deliberately not skipped when the in-memory draft already equals
    // [draftText]. `ChatState`'s copy is not evidence about the column: the
    // guard below abandons the publish when the message list moved under the
    // write, so state can believe the draft is empty while the row still
    // holds text. Skipping on that comparison is what let a sent message's
    // text survive in the column with nothing left to clear it.
    final updatedSession = await _ref
        .read(chatRepoProvider)
        .updateDraftIfMessageCount(
          sessionId: sessionId,
          draft: draftText,
          expectedMessageCount: expectedMessageCount,
        );
    if (!_ref.mounted) return;
    if (epoch != _saveEpoch) return;
    if (updatedSession == null) return;
    final latest = _getState().value;
    // A draft completion belongs only to the exact session snapshot that
    // started it. Never let a delayed debounce switch the UI back to an old
    // session or replace a newer optimistic/durable message list.
    if (latest?.session?.id != sessionId ||
        latest!.session!.messages.length != expectedMessageCount) {
      return;
    }
    final sessionWithDraft = latest.session!.copyWith(
      draft: updatedSession.draft,
    );
    ChatSessionService.updateCache(sessionWithDraft);
    _setState(AsyncData(latest.copyWith(session: sessionWithDraft)));
  }
}
