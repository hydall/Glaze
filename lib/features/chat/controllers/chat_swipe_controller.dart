// Named public constructor arguments intentionally initialize private fields.
// ignore_for_file: prefer_initializing_formals

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/state/db_provider.dart';
import '../chat_message_service.dart';
import '../chat_session_service.dart';
import '../chat_state.dart';
import '../initial_message_builder.dart';
import '../state/chat_session_write_queue.dart';

class ChatSwipeController {
  final Ref _ref;
  final String _charId;
  final void Function(AsyncValue<ChatState>) _setState;
  final AsyncValue<ChatState> Function() _getState;
  final void Function() _invalidateHistory;

  /// Shared with `ChatMessageOpsController`. Every durable write runs through
  /// it so two taps (or a tap racing a swipe gesture) cannot interleave their
  /// commit cycles, and — more importantly — so a variation switch never
  /// commits while a message deletion is still in its transaction. The commit
  /// below re-reads the *durable* row; started early it would read the
  /// pre-delete message list and write it back, which is exactly how deleted
  /// messages came back the moment you flipped a variation.
  final ChatSessionWriteQueue _writes;

  ChatSwipeController({
    required Ref ref,
    required String charId,
    required void Function(AsyncValue<ChatState>) setState,
    required AsyncValue<ChatState> Function() getState,
    required void Function() invalidateHistory,
    required ChatSessionWriteQueue writes,
  }) : _ref = ref,
       _charId = charId,
       _setState = setState,
       _getState = getState,
       _invalidateHistory = invalidateHistory,
       _writes = writes;

  ChatMessageService get _messageSvc => ChatMessageService(_ref);

  /// Publishes [updated] on top of the *latest* state rather than the snapshot
  /// the operation started from, so flags another path flipped mid-await
  /// (generation, session switch) are not rolled back. Drops the write when the
  /// chat moved to a different session while the commit was in flight.
  void _publish(ChatSession updated, {bool invalidateHistory = true}) {
    final latest = _getState().value;
    if (latest == null || latest.session == null) return;
    if (latest.session!.id != updated.id) return;
    if (invalidateHistory) _invalidateHistory();
    _setState(AsyncData(latest.copyWith(session: updated)));
  }

  /// Paints [preview] now and commits it on the shared write queue.
  ///
  /// The commit is a Drift transaction plus a full session re-encode; on a long
  /// chat that is several frames, and awaiting it before publishing is what
  /// made the counter and the bubble lag a tap behind. The variation switch
  /// itself is computed synchronously, so the bubble can flip on the frame of
  /// the tap and reconcile with the durable row when it lands.
  Future<void> _switchVariation({
    required ChatSession snapshot,
    required int messageIndex,
    required ChatSession preview,
    required ChatSession Function(ChatSession latest, int latestIndex) mutate,
  }) {
    final token = _writes.beginPublication();
    // The optimistic paint changes nothing durable, so it must not churn the
    // chat list — only the committed row below does.
    _publish(preview, invalidateHistory: false);
    return _writes.run(() async {
      final durable = await _messageSvc.commitMessageMutation(
        snapshot,
        messageIndex,
        mutate,
      );
      // Something newer already owns the bubble — another switch, or a delete
      // that painted its shortened list. This row predates it, so publishing
      // would step the user backwards (and put deleted bubbles back).
      if (!_writes.isCurrentPublication(token)) return;
      _publish(durable);
    });
  }

  /// True when [current] cannot accept a variation switch right now.
  bool _switchBlocked(ChatState? current, int messageIndex) {
    return current == null ||
        current.session == null ||
        current.isGenerating ||
        current.isGeneratingImage ||
        current.isPostGenRunning ||
        messageIndex < 0 ||
        messageIndex >= current.messages.length;
  }

  Future<void> setSwipe(int messageIndex, int swipeId) {
    // Direct selection is not gated on the generation flags (unlike
    // [changeSwipe]) — it keeps the original contract of "apply it if the
    // message service accepts it", and bails out below when nothing moved.
    final snapshot = _getState().value?.session;
    if (snapshot == null) return Future<void>.value();
    final preview = _messageSvc.setSwipe(snapshot, messageIndex, swipeId);
    if (identical(preview, snapshot)) return Future<void>.value();
    return _switchVariation(
      snapshot: snapshot,
      messageIndex: messageIndex,
      preview: preview,
      mutate: (latest, latestIndex) =>
          _messageSvc.setSwipe(latest, latestIndex, swipeId),
    );
  }

  Future<void> setAgentSwipe(int messageIndex, int agentSwipeId) {
    final snapshot = _getState().value?.session;
    if (snapshot == null) return Future<void>.value();
    final preview = _messageSvc.setAgentSwipe(
      snapshot,
      messageIndex,
      agentSwipeId,
    );
    if (identical(preview, snapshot)) return Future<void>.value();
    return _switchVariation(
      snapshot: snapshot,
      messageIndex: messageIndex,
      preview: preview,
      mutate: (latest, latestIndex) =>
          _messageSvc.setAgentSwipe(latest, latestIndex, agentSwipeId),
    );
  }

  Future<void> deleteActiveSwipe(int messageIndex) {
    return _deleteVariation(messageIndex, deleteAgentSwipe: false);
  }

  Future<void> deleteActiveAgentSwipe(int messageIndex) {
    return _deleteVariation(messageIndex, deleteAgentSwipe: true);
  }

  Future<void> _deleteVariation(
    int messageIndex, {
    required bool deleteAgentSwipe,
  }) {
    final token = _writes.beginPublication();
    return _writes.run(() async {
      final current = _getState().value;
      if (_switchBlocked(current, messageIndex)) return;
      final snapshot = current!.session!;
      if (current.messages[messageIndex].role != 'assistant') return;
      final updated = deleteAgentSwipe
          ? await _messageSvc.deleteActiveAgentSwipe(snapshot, messageIndex)
          : await _messageSvc.deleteActiveSwipe(snapshot, messageIndex);
      if (identical(updated, snapshot)) return;
      if (!_writes.isCurrentPublication(token)) return;
      _publish(updated);
    });
  }

  Future<void> changeSwipe(
    int messageIndex,
    int dir, {
    bool fromSwipe = false,
  }) {
    final current = _getState().value;
    if (_switchBlocked(current, messageIndex)) return Future<void>.value();
    final snapshot = current!.session!;

    final isLast = messageIndex == current.messages.length - 1;
    final preview = _messageSvc.changeSwipe(
      snapshot,
      messageIndex,
      dir,
      fromSwipe: fromSwipe,
      isLastMessage: isLast,
    );

    // This will be handled by the parent provider calling
    // regenerateLastAssistant.
    if (preview.needsRegen || !preview.isUpdated) return Future<void>.value();

    return _switchVariation(
      snapshot: snapshot,
      messageIndex: messageIndex,
      preview: preview.session!,
      mutate: (latest, latestIndex) =>
          _messageSvc
              .changeSwipe(
                latest,
                latestIndex,
                dir,
                fromSwipe: fromSwipe,
                isLastMessage: latestIndex == latest.messages.length - 1,
              )
              .session ??
          latest,
    );
  }

  /// Navigate blue sub-swipes (agentSwipes). Right-edge on the last message
  /// → needsRegen, which the caller resolves via a full regeneration.
  Future<void> changeAgentSwipe(
    int messageIndex,
    int dir, {
    bool fromSwipe = false,
  }) {
    final current = _getState().value;
    if (_switchBlocked(current, messageIndex)) return Future<void>.value();
    final snapshot = current!.session!;

    final isLast = messageIndex == current.messages.length - 1;
    final preview = _messageSvc.changeAgentSwipe(
      snapshot,
      messageIndex,
      dir,
      fromSwipe: fromSwipe,
      isLastMessage: isLast,
    );

    if (preview.needsRegen || !preview.isUpdated) return Future<void>.value();

    return _switchVariation(
      snapshot: snapshot,
      messageIndex: messageIndex,
      preview: preview.session!,
      mutate: (latest, latestIndex) =>
          _messageSvc
              .changeAgentSwipe(
                latest,
                latestIndex,
                dir,
                fromSwipe: fromSwipe,
                isLastMessage: latestIndex == latest.messages.length - 1,
              )
              .session ??
          latest,
    );
  }

  Future<void> setGreeting(int messageIndex, int direction) {
    // Unlike a swipe switch this cannot be previewed synchronously — the
    // greeting list comes from the character row and the resolved persona — so
    // it stays entirely on the write queue.
    final token = _writes.beginPublication();
    return _writes.run(() async {
      final current = _getState().value;
      if (current == null ||
          current.session == null ||
          current.isGenerating ||
          current.isPostGenRunning) {
        return;
      }
      if (messageIndex != 0) return;
      if (messageIndex >= current.messages.length) return;
      final msg = current.messages[messageIndex];
      if (msg.role != 'assistant') return;

      final character = await _ref.read(characterRepoProvider).getById(_charId);
      if (character == null) return;
      final persona = await ChatSessionService(_ref).resolvePersona(_charId);
      final greetings = InitialMessageBuilder.resolveGreetings(
        character: character,
        persona: persona,
        sessionId: current.session!.id,
      );
      if (greetings.length <= 1) return;

      final currentIdx = msg.greetingIndex ?? 0;
      final updated = await _messageSvc.commitMessageMutation(
        current.session!,
        messageIndex,
        (latest, latestIndex) => _messageSvc.setGreeting(
          latest,
          latestIndex,
          currentIdx + direction,
          greetings,
        ),
      );
      if (!_writes.isCurrentPublication(token)) return;
      _publish(updated);
    });
  }
}
