import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  ChatSwipeController({
    required this._ref,
    required this._charId,
    required this._setState,
    required this._getState,
    required this._invalidateHistory,
  });

  ChatMessageService get _messageSvc => ChatMessageService(_ref);

  Future<void> setSwipe(int messageIndex, int swipeId) async {
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final updated = await _messageSvc.commitMessageMutation(
      current.session!,
      messageIndex,
      (latest, latestIndex) =>
          _messageSvc.setSwipe(latest, latestIndex, swipeId),
    );
    _invalidateHistory();
    _setState(AsyncData(current.copyWith(session: updated)));
  }

  Future<void> setAgentSwipe(int messageIndex, int agentSwipeId) async {
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final updated = await _messageSvc.commitMessageMutation(
      current.session!,
      messageIndex,
      (latest, latestIndex) =>
          _messageSvc.setAgentSwipe(latest, latestIndex, agentSwipeId),
    );
    _invalidateHistory();
    _setState(AsyncData(current.copyWith(session: updated)));
  }

  Future<void> deleteActiveSwipe(int messageIndex) async {
    await _deleteVariation(messageIndex, deleteAgentSwipe: false);
  }

  Future<void> deleteActiveAgentSwipe(int messageIndex) async {
    await _deleteVariation(messageIndex, deleteAgentSwipe: true);
  }

  Future<void> _deleteVariation(
    int messageIndex, {
    required bool deleteAgentSwipe,
  }) async {
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
    _invalidateHistory();
    _setState(AsyncData(current.copyWith(session: updated)));
  }

  Future<void> changeSwipe(
    int messageIndex,
    int dir, {
    bool fromSwipe = false,
  }) async {
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
      // This will be handled by the parent provider calling regenerateLastAssistant
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
      _invalidateHistory();
      _setState(AsyncData(current.copyWith(session: result)));
    }
  }

  /// Navigate blue sub-swipes (agentSwipes). Right-edge on the last message
  /// → needsRegen, which the caller resolves via a full regeneration.
  Future<void> changeAgentSwipe(
    int messageIndex,
    int dir, {
    bool fromSwipe = false,
  }) async {
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
      _invalidateHistory();
      _setState(AsyncData(current.copyWith(session: result)));
    }
  }

  Future<void> setGreeting(int messageIndex, int direction) async {
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
    _invalidateHistory();
    _setState(AsyncData(current.copyWith(session: updated)));
  }
}
