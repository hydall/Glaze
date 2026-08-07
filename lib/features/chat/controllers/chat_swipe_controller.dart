import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/state/db_provider.dart';
import '../chat_message_service.dart';
import '../chat_session_service.dart';
import '../chat_state.dart';
import '../initial_message_builder.dart';

class ChatSwipeController {
  final Ref _ref;
  final String _charId;
  final void Function(AsyncValue<ChatState>) _setState;
  final AsyncValue<ChatState> Function() _getState;
  final void Function() _invalidateHistory;

  /// Tail of the variation-switch queue. Every public method runs through
  /// [_serialize] so two taps (or a tap racing a swipe gesture) cannot
  /// interleave their read → commit → publish cycles: the second one would
  /// read the state the first has not published yet, and whichever `_setState`
  /// landed last would win — leaving the counter or the bubble one step behind
  /// the durable session, which is exactly the "stuck variation" symptom.
  Future<void> _queue = Future<void>.value();

  ChatSwipeController({
    required this._ref,
    required this._charId,
    required this._setState,
    required this._getState,
    required this._invalidateHistory,
  });

  ChatMessageService get _messageSvc => ChatMessageService(_ref);

  Future<void> _serialize(Future<void> Function() operation) {
    final previous = _queue;
    final next = () async {
      try {
        await previous;
      } catch (_) {
        // A failed switch must not permanently poison the queue.
      }
      await operation();
    }();
    _queue = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// Publishes [updated] on top of the *latest* state rather than the snapshot
  /// the operation started from, so flags another path flipped mid-await
  /// (generation, session switch) are not rolled back. Drops the write when the
  /// chat moved to a different session while the commit was in flight.
  void _publish(ChatSession updated) {
    final latest = _getState().value;
    if (latest == null || latest.session == null) return;
    if (latest.session!.id != updated.id) return;
    _invalidateHistory();
    _setState(AsyncData(latest.copyWith(session: updated)));
  }

  Future<void> setSwipe(int messageIndex, int swipeId) {
    return _serialize(() async {
      final current = _getState().value;
      if (current == null || current.session == null) return;
      final updated = await _messageSvc.commitMessageMutation(
        current.session!,
        messageIndex,
        (latest, latestIndex) =>
            _messageSvc.setSwipe(latest, latestIndex, swipeId),
      );
      _publish(updated);
    });
  }

  Future<void> setAgentSwipe(int messageIndex, int agentSwipeId) {
    return _serialize(() async {
      final current = _getState().value;
      if (current == null || current.session == null) return;
      final updated = await _messageSvc.commitMessageMutation(
        current.session!,
        messageIndex,
        (latest, latestIndex) =>
            _messageSvc.setAgentSwipe(latest, latestIndex, agentSwipeId),
      );
      _publish(updated);
    });
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
    return _serialize(() async {
      final current = _getState().value;
      if (current == null ||
          current.session == null ||
          current.isGenerating ||
          current.isGeneratingImage ||
          current.isPostGenRunning ||
          messageIndex < 0 ||
          messageIndex >= current.messages.length ||
          current.messages[messageIndex].role != 'assistant') {
        return;
      }
      final updated = deleteAgentSwipe
          ? await _messageSvc.deleteActiveAgentSwipe(
              current.session!,
              messageIndex,
            )
          : await _messageSvc.deleteActiveSwipe(current.session!, messageIndex);
      if (identical(updated, current.session)) return;
      _publish(updated);
    });
  }

  Future<void> changeSwipe(
    int messageIndex,
    int dir, {
    bool fromSwipe = false,
  }) {
    return _serialize(() async {
      final current = _getState().value;
      if (current == null ||
          current.session == null ||
          current.isGenerating ||
          current.isGeneratingImage ||
          current.isPostGenRunning) {
        return;
      }
      if (messageIndex < 0 || messageIndex >= current.messages.length) return;

      final isLast = messageIndex == current.messages.length - 1;
      final preview = _messageSvc.changeSwipe(
        current.session!,
        messageIndex,
        dir,
        fromSwipe: fromSwipe,
        isLastMessage: isLast,
      );

      if (preview.needsRegen) {
        // This will be handled by the parent provider calling
        // regenerateLastAssistant
        return;
      }
      if (preview.isUpdated) {
        final result = await _messageSvc.commitMessageMutation(
          current.session!,
          messageIndex,
          (latest, latestIndex) =>
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
        _publish(result);
      }
    });
  }

  /// Navigate blue sub-swipes (agentSwipes). Right-edge on the last message
  /// → needsRegen, which the caller resolves via a full regeneration.
  Future<void> changeAgentSwipe(
    int messageIndex,
    int dir, {
    bool fromSwipe = false,
  }) {
    return _serialize(() async {
      final current = _getState().value;
      if (current == null ||
          current.session == null ||
          current.isGenerating ||
          current.isGeneratingImage ||
          current.isPostGenRunning) {
        return;
      }
      if (messageIndex < 0 || messageIndex >= current.messages.length) return;

      final isLast = messageIndex == current.messages.length - 1;
      final preview = _messageSvc.changeAgentSwipe(
        current.session!,
        messageIndex,
        dir,
        fromSwipe: fromSwipe,
        isLastMessage: isLast,
      );

      if (preview.needsRegen) {
        return;
      }
      if (preview.isUpdated) {
        final result = await _messageSvc.commitMessageMutation(
          current.session!,
          messageIndex,
          (latest, latestIndex) =>
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
        _publish(result);
      }
    });
  }

  Future<void> setGreeting(int messageIndex, int direction) {
    return _serialize(() async {
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
      _publish(updated);
    });
  }
}
