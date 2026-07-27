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
    var updated = _messageSvc.editMessage(
      current.session!,
      index,
      newContent,
      tagStart: tagStart,
      tagEnd: tagEnd,
    );
    updated = await _applyRunOnEditRegexes(updated, index);
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
    final updated = session.copyWith(
      messages: newMessages,
      updatedAt: currentTimestampSeconds(),
    );
    await _ref.read(chatRepoProvider).put(updated);
    ChatSessionService.updateCache(updated);
    return updated;
  }

  Future<void> moveMessage(int fromIndex, int toIndex) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final updated = _messageSvc.moveMessage(
      current.session!,
      fromIndex,
      toIndex,
    );
    _invalidateHistory();
    _setState(AsyncData(current.copyWith(session: updated)));
  }

  Future<void> deleteMessage(int index) async {
    await deleteMessages({index});
  }

  Future<void> deleteMessages(Set<int> indices) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final updated = await _messageSvc.deleteMessages(current.session!, indices);
    if (!_ref.mounted) return;
    _invalidateHistory();
    _setState(AsyncData(current.copyWith(session: updated)));
  }

  Future<void> toggleMessageHidden(int index) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final updated = _messageSvc.toggleMessageHidden(current.session!, index);
    _invalidateHistory();
    _setState(AsyncData(current.copyWith(session: updated)));
  }

  /// Eye button on an image attachment: flips whether the image is sent to
  /// the model. Attachments start visible.
  Future<void> toggleImageHidden(int index) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final updated = _messageSvc.toggleImageHidden(current.session!, index);
    if (identical(updated, current.session)) return;
    _invalidateHistory();
    _setState(AsyncData(current.copyWith(session: updated)));
  }

  Future<void> unhideAllMessages() async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final updated = _messageSvc.unhideAllMessages(current.session!);
    _invalidateHistory();
    _setState(AsyncData(current.copyWith(session: updated)));
  }

  Future<void> hideTopMessages(int count) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    final updated = _messageSvc.hideTopMessages(current.session!, count);
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
    _invalidateHistory();
    _setState(AsyncData(ChatState(session: cleared)));
  }
}
