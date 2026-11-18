import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat/chat_session_service.dart';
import '../models/chat_message.dart';
import 'db_provider.dart';

class ChatSessionOps extends AsyncNotifier<List<ChatSession>> {
  @override
  Future<List<ChatSession>> build() async {
    return ref.read(chatRepoProvider).getAllSessions();
  }

  Future<void> saveSession(ChatSession session) async {
    await ref.read(chatRepoProvider).put(session);
    ChatSessionService.updateCache(session);
    ref.invalidateSelf();
  }

  Future<ChatSession?> getSession(String sessionId) async {
    return ref.read(chatRepoProvider).getById(sessionId);
  }

  Future<List<ChatSession>> getSessionsByCharacter(String charId) async {
    return ref.read(chatRepoProvider).getByCharacterId(charId);
  }

  /// Lightweight session listing for pickers — only indexes/counts, no full
  /// message decoding. Far faster than [getSessionsByCharacter] for large
  /// histories.
  Future<List<SessionMetadata>> getSessionMetadataByCharacter(
    String charId,
  ) async {
    return ref.read(chatRepoProvider).getMetadataByCharacterId(charId);
  }
}

final chatSessionOpsProvider = AsyncNotifierProvider<ChatSessionOps, List<ChatSession>>(
  ChatSessionOps.new,
);
