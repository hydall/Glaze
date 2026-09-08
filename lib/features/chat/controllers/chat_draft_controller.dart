import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/db_provider.dart';
import '../chat_session_service.dart';
import '../chat_state.dart';

class ChatDraftController {
  final Ref _ref;
  final void Function(AsyncValue<ChatState>) _setState;
  final AsyncValue<ChatState> Function() _getState;

  ChatDraftController({
    required this._ref,
    required this._setState,
    required this._getState,
  });

  Future<void> saveDraft(String draftText) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null || current.session == null) return;
    if (current.session!.draft == draftText) return;

    final updatedSession = await _ref
        .read(chatRepoProvider)
        .updateDraftIfMessageCount(
          sessionId: current.session!.id,
          draft: draftText,
          expectedMessageCount: current.session!.messages.length,
        );
    if (!_ref.mounted) return;
    if (updatedSession == null) return;
    ChatSessionService.updateCache(updatedSession);
    final latest = _getState().value ?? current;
    _setState(
      AsyncData(latest.copyWith(session: updatedSession)),
    );
  }
}
