// Named public constructor arguments intentionally initialize private fields.
// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/utils/time_helpers.dart';
import '../chat_message_service.dart';
import '../chat_session_service.dart';
import '../chat_state.dart';
import '../state/chat_session_write_queue.dart';
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

  /// Tail of the in-flight session writes, shared with [ChatSwipeController].
  /// Publishing the shortened list before the write makes it easy to fire a
  /// second delete — or a variation switch, or an edit — while the first is
  /// still in its transaction; unserialized, the two session writes interleave
  /// and whichever lands last wins, which puts back messages the delete
  /// already took off screen. Chaining keeps the durable row in UI order.
  final ChatSessionWriteQueue _writes;

  ChatMessageOpsController({
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
    final token = _writes.beginPublication();
    var edited = _messageSvc.editMessage(
      current.session!,
      index,
      newContent,
      tagStart: tagStart,
      tagEnd: tagEnd,
    );
    edited = await _applyRunOnEditRegexes(edited, index);
    final updated = await _writes.run(
      () => _messageSvc.commitMessageMutation(current.session!, index, (
        latest,
        latestIndex,
      ) {
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
      }),
    );
    if (!_ref.mounted) return;
    TokenBreakdownCache.invalidate();
    _ref.read(cachedTokenBreakdownProvider(_charId).notifier).state = null;
    _ref.read(lastVectorLoreTokensProvider(_charId).notifier).state = 0;
    _publish(updated, token: token);
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
    // `isMarkdown: false` on purpose: this pass writes its result back into the
    // session, and a `markdownOnly` script ("Only Format Display" in ST) must
    // never touch stored text. Running it here baked the rendered output into
    // the message — a card-rendering regex replaced its own `{TRK|…}` marker,
    // so after one edit there was nothing left for it to match.
    final content = applyRegexes(
      msg.content,
      placement,
      1,
      editScripts,
      ctx,
      isMarkdown: false,
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
    final token = _writes.beginPublication();
    final updated = await _writes.run(
      () => _messageSvc.commitMessagesMutation(current.session!, (latest) {
        final movedId = current.session!.messages[fromIndex].id;
        final currentIndex = latest.messages.indexWhere((m) => m.id == movedId);
        if (currentIndex < 0) return latest;
        return _messageSvc.moveMessage(latest, currentIndex, toIndex);
      }),
    );
    _publish(updated, token: token);
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
    _writes.beginPublication();
    ChatSessionService.updateCache(plan.session);
    _setState(AsyncData(current.copyWith(session: plan.session)));
    _invalidateHistory();

    try {
      await _writes.run(() => svc.commitDeleteMessages(original, plan));
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
    final token = _writes.beginPublication();
    final updated = await _writes.run(
      () => _messageSvc.commitMessageMutation(
        current.session!,
        index,
        _messageSvc.toggleMessageHidden,
      ),
    );
    _publish(updated, token: token);
  }

  /// Eye button on an image attachment: flips whether the image is sent to
  /// the model. Attachments start visible.
  Future<void> toggleImageHidden(int index) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final token = _writes.beginPublication();
    final updated = await _writes.run(
      () => _messageSvc.commitMessageMutation(
        current.session!,
        index,
        _messageSvc.toggleImageHidden,
      ),
    );
    if (identical(updated, current.session)) return;
    _publish(updated, token: token);
  }

  Future<void> unhideAllMessages() async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final token = _writes.beginPublication();
    final updated = await _writes.run(
      () => _messageSvc.commitMessagesMutation(
        current.session!,
        _messageSvc.unhideAllMessages,
      ),
    );
    _publish(updated, token: token);
  }

  Future<void> hideTopMessages(int count) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final token = _writes.beginPublication();
    final updated = await _writes.run(
      () => _messageSvc.commitMessagesMutation(
        current.session!,
        (latest) => _messageSvc.hideTopMessages(latest, count),
      ),
    );
    _publish(updated, token: token);
  }

  /// Publishes [updated] on top of the *latest* state instead of the snapshot
  /// the operation started from. These commits now queue behind any pending
  /// delete, so the flags another path flipped meanwhile (generation, session
  /// switch) must survive.
  ///
  /// Drops the write when the chat moved to a different session while the
  /// commit was in flight, or when [token] is no longer the newest claim —
  /// this row predates whatever is on screen (typically a delete that already
  /// painted its shortened list), and repainting it would undo that.
  void _publish(ChatSession updated, {required int token}) {
    if (!_ref.mounted) return;
    if (!_writes.isCurrentPublication(token)) return;
    final latest = _getState().value;
    if (latest == null || latest.session == null) return;
    if (latest.session!.id != updated.id) return;
    _invalidateHistory();
    _setState(AsyncData(latest.copyWith(session: updated)));
  }

  Future<void> clearChat() async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final token = _writes.beginPublication();
    final cleared = await _writes.run(
      () => ChatSessionService(_ref).clearChat(_charId, current.session!),
    );
    if (!_ref.mounted) return;
    if (!_writes.isCurrentPublication(token)) return;
    _ref.read(messageVariablesProvider.notifier).clearSession(cleared.id);
    _invalidateHistory();
    _setState(AsyncData(ChatState(session: cleared)));
  }
}
