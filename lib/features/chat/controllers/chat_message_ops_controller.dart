import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/utils/time_helpers.dart';
import '../chat_message_service.dart';
import '../chat_session_service.dart';
import '../chat_state.dart';
import '../state/token_breakdown_cache.dart';
import '../state/cached_token_breakdown.dart';
import '../../../core/llm/regex_service.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../extensions/state/message_variables_notifier.dart';
import '../../personas/persona_list_provider.dart';

class ChatMessageOpsController {
  final Ref _ref;
  final String _charId;
  final void Function(AsyncValue<ChatState>) _setState;
  final AsyncValue<ChatState> Function() _getState;
  final void Function() _invalidateHistory;

  ChatMessageOpsController({
    required this._ref,
    required this._charId,
    required this._setState,
    required this._getState,
    required this._invalidateHistory,
  });

  ChatMessageService get _messageSvc => ChatMessageService(_ref);

  /// Tail of the in-flight delete commits. Publishing the shortened list before
  /// the write makes it easy to fire a second delete while the first is still
  /// in its transaction; unserialized, the two session writes interleave and
  /// whichever lands last wins — which can put back messages the later delete
  /// already took off screen. Chaining keeps the DB in UI order.
  Future<void> _deleteCommits = Future<void>.value();

  Future<void> editMessage(
    int index,
    String newContent, {
    String? tagStart,
    String? tagEnd,
  }) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null ||
        current.session == null ||
        current.isGenerating ||
        current.isGeneratingImage ||
        current.isPostGenRunning) {
      return;
    }
    if (index < 0 || index >= current.session!.messages.length) return;
    var edited = _messageSvc.editMessage(
      current.session!,
      index,
      newContent,
      tagStart: tagStart,
      tagEnd: tagEnd,
    );
    edited = await _applyRunOnEditRegexes(edited, index);
    final updated = await _messageSvc.commitMessageMutation(
      current.session!,
      index,
      (latest, latestIndex) {
        var result = _messageSvc.editMessage(
          latest,
          latestIndex,
          newContent,
          tagStart: tagStart,
          tagEnd: tagEnd,
        );
        final regexContent = edited.messages[index].content;
        if (result.messages[latestIndex].content != regexContent) {
          result = _messageSvc.editMessage(result, latestIndex, regexContent);
        }
        return result;
      },
    );
    if (!_ref.mounted) return;
    _invalidateHistory();
    TokenBreakdownCache.invalidate();
    _ref.read(cachedTokenBreakdownProvider(_charId).notifier).state = null;
    _ref.read(lastVectorLoreTokensProvider(_charId).notifier).state = 0;
    _setState(AsyncData(current.copyWith(session: updated)));
  }

  Future<ChatSession> _applyRunOnEditRegexes(
    ChatSession session,
    int index,
  ) async {
    if (index < 0 || index >= session.messages.length) return session;
    final scripts = await _ref.read(activeRegexesProvider.future);
    final editScripts = scripts.where((r) => r.runOnEdit).toList();
    if (editScripts.isEmpty) return session;

    final char = await _ref.read(characterRepoProvider).getById(_charId);
    final msg = session.messages[index];
    final placement = msg.role == 'user' ? 1 : 2;
    final personas = _ref.read(personaListProvider).value ?? [];
    final persona = getEffectivePersona(
      personas,
      _charId,
      session.id,
      _ref.read(activePersonaIdProvider),
      _ref.read(personaConnectionsProvider),
    );
    final depth = session.messages.length - 1 - index;
    final ctx = RegexApplyContext(char: char, persona: persona, depth: depth);
    final content = applyRegexes(
      msg.content,
      placement,
      1,
      editScripts,
      ctx,
      isMarkdown: true,
    );
    if (content == msg.content) return session;
    final newMessages = List<ChatMessage>.from(session.messages);
    newMessages[index] = msg.copyWith(content: content);
    return session.copyWith(
      messages: newMessages,
      updatedAt: currentTimestampSeconds(),
    );
  }

  Future<void> moveMessage(int fromIndex, int toIndex) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    if (fromIndex < 0 || fromIndex >= current.session!.messages.length) return;
    if (toIndex < 0 || toIndex >= current.session!.messages.length) return;
    final updated = await _messageSvc.commitMessagesMutation(current.session!, (
      latest,
    ) {
      final movedId = current.session!.messages[fromIndex].id;
      final currentIndex = latest.messages.indexWhere((m) => m.id == movedId);
      if (currentIndex < 0) return latest;
      return _messageSvc.moveMessage(latest, currentIndex, toIndex);
    });
    _invalidateHistory();
    _setState(AsyncData(current.copyWith(session: updated)));
  }

  Future<void> deleteMessage(int index) async {
    await deleteMessages({index});
  }

  Future<void> deleteMessages(Set<int> indices) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    final original = current?.session;
    if (current == null || original == null) return;

    final svc = _messageSvc;
    final plan = svc.planDeleteMessages(original, indices);
    if (plan == null) return;

    // Optimistic: drop the bubbles on the frame of the tap. The commit below
    // runs a multi-table transaction (knowledge rollback, memory, snapshots,
    // ledger, embedding index) plus a full session re-encode, which is long
    // enough on a big chat to read as an unresponsive Delete button.
    ChatSessionService.updateCache(plan.session);
    _setState(AsyncData(current.copyWith(session: plan.session)));
    _invalidateHistory();

    final commit = _deleteCommits.then(
      (_) => svc.commitDeleteMessages(original, plan),
    );
    // Keep the chain usable after a failed commit.
    _deleteCommits = commit.then<void>((_) {}, onError: (Object _) {});

    try {
      await commit;
    } catch (e) {
      debugPrint('[ChatMessageOps] delete failed, restoring messages: $e');
      if (!_ref.mounted) return;
      final after = _getState().value;
      // Only undo the optimistic write when nothing else has touched the
      // session since — a newer edit/generation owns the state by then, and
      // restoring the pre-delete session would resurrect more than the failure.
      if (after != null && identical(after.session, plan.session)) {
        ChatSessionService.updateCache(original);
        _setState(AsyncData(after.copyWith(session: original)));
        _invalidateHistory();
      }
      GlazeToast.showWithoutContext(
        'Failed to delete message: $e',
        isError: true,
        duration: 5000,
      );
      return;
    }
    if (!_ref.mounted) return;
    _invalidateHistory();
  }

  Future<void> toggleMessageHidden(int index) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final updated = await _messageSvc.commitMessageMutation(
      current.session!,
      index,
      _messageSvc.toggleMessageHidden,
    );
    _invalidateHistory();
    _setState(AsyncData(current.copyWith(session: updated)));
  }

  /// Eye button on an image attachment: flips whether the image is sent to
  /// the model. Attachments start visible.
  Future<void> toggleImageHidden(int index) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final updated = await _messageSvc.commitMessageMutation(
      current.session!,
      index,
      _messageSvc.toggleImageHidden,
    );
    if (identical(updated, current.session)) return;
    _invalidateHistory();
    _setState(AsyncData(current.copyWith(session: updated)));
  }

  Future<void> unhideAllMessages() async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final updated = await _messageSvc.commitMessagesMutation(
      current.session!,
      _messageSvc.unhideAllMessages,
    );
    _invalidateHistory();
    _setState(AsyncData(current.copyWith(session: updated)));
  }

  Future<void> hideTopMessages(int count) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final updated = await _messageSvc.commitMessagesMutation(
      current.session!,
      (latest) => _messageSvc.hideTopMessages(latest, count),
    );
    _invalidateHistory();
    _setState(AsyncData(current.copyWith(session: updated)));
  }

  Future<void> clearChat() async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final cleared = await ChatSessionService(
      _ref,
    ).clearChat(_charId, current.session!);
    if (!_ref.mounted) return;
    _ref.read(messageVariablesProvider.notifier).clearSession(cleared.id);
    _invalidateHistory();
    _setState(AsyncData(ChatState(session: cleared)));
  }
}
