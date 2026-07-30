import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/repositories/character_repo.dart' show CharacterRepo;
import '../../core/models/chat_message.dart';
import '../../core/state/character_provider.dart'
    show revealHiddenCharactersProvider;
import '../../core/state/db_provider.dart';
import '../../core/utils/sync_deletion_tracker.dart';
import '../../shared/utils/time_formatter.dart';
import '../chat/chat_session_service.dart';
import '../extensions/state/message_variables_notifier.dart';

class ChatSessionInfo {
  final String sessionId;
  final String characterId;

  /// The character's own name — **without** any variation suffix. The variation
  /// travels separately in [variantName] so the list can render it as a chip
  /// that survives truncation, instead of gluing it onto the end of a string
  /// where the ellipsis eats exactly the part that tells two rows apart.
  final String characterName;

  /// Variation group of [characterId], used to keep a character's variations in
  /// one collapsible group instead of scattering them across the list as
  /// look-alike top-level entries.
  final String variantGroupId;

  /// Name of the variation this session belongs to, or null for the group's
  /// original/unnamed character row.
  final String? variantName;

  final String? avatarPath;
  final String lastMessage;
  final int lastMessageTime;
  final int messageCount;
  final int sessionIndex;
  final String? sessionName;

  const ChatSessionInfo({
    required this.sessionId,
    required this.characterId,
    required this.characterName,
    required this.variantGroupId,
    this.variantName,
    this.avatarPath,
    required this.lastMessage,
    required this.lastMessageTime,
    required this.messageCount,
    required this.sessionIndex,
    this.sessionName,
  });

  /// Full name for places that need one flat string (dialog copy, tooltips).
  String get fullCharacterName {
    final variant = variantName?.trim();
    return (variant != null && variant.isNotEmpty)
        ? '$characterName — $variant'
        : characterName;
  }

  /// This session with a new display name. Takes the name positionally so a
  /// null genuinely clears it, rather than being read as "leave unchanged".
  ChatSessionInfo withSessionName(String? name) => ChatSessionInfo(
    sessionId: sessionId,
    characterId: characterId,
    characterName: characterName,
    variantGroupId: variantGroupId,
    variantName: variantName,
    avatarPath: avatarPath,
    lastMessage: lastMessage,
    lastMessageTime: lastMessageTime,
    messageCount: messageCount,
    sessionIndex: sessionIndex,
    sessionName: name,
  );
}

final chatHistoryProvider =
    AsyncNotifierProvider<ChatHistoryNotifier, List<ChatSessionInfo>>(
      ChatHistoryNotifier.new,
    );

class ChatHistoryNotifier extends AsyncNotifier<List<ChatSessionInfo>> {
  StreamSubscription<dynamic>? _sub;
  StreamSubscription<dynamic>? _charactersSub;
  List<ChatSessionInfo>? _lastResult;

  /// Mirrors [revealHiddenCharactersProvider]: while false, sessions belonging
  /// to hidden characters are dropped from the history list. Watched in
  /// [build] so toggling reveal rebuilds the list.
  bool _revealHidden = false;

  @override
  Future<List<ChatSessionInfo>> build() async {
    _revealHidden = ref.watch(revealHiddenCharactersProvider);
    final chatRepo = ref.read(chatRepoProvider);
    final charRepo = ref.read(characterRepoProvider);
    await _sub?.cancel();
    await _charactersSub?.cancel();
    _sub = chatRepo.watchAllSessionMetadata().listen((allMeta) {
      _updateFromMetadata(allMeta, charRepo);
    });
    _charactersSub = charRepo.watchAll().listen((_) async {
      final allMeta = await chatRepo.getAllSessionMetadata();
      await _updateFromMetadata(allMeta, charRepo);
    });
    ref.onDispose(() {
      unawaited(_sub?.cancel());
      unawaited(_charactersSub?.cancel());
    });

    final allMeta = await chatRepo.getAllSessionMetadata();
    return _buildFromMetadata(allMeta, charRepo);
  }

  Future<List<ChatSessionInfo>> _buildFromMetadata(
    List<SessionMetadata> allMeta,
    CharacterRepo charRepo,
  ) async {
    final charIds = allMeta.map((m) => m.characterId).toSet();
    final charMap = await charRepo.getByIds(charIds);

    final result = <ChatSessionInfo>[];
    for (final m in allMeta) {
      final char = charMap[m.characterId];
      // Hidden characters take their chats with them: sessions drop out of the
      // history list while the character is hidden and reappear when it's
      // revealed (same gesture as the My Characters list). Orphan sessions
      // (no character row) are always kept.
      if (char != null && char.hidden && !_revealHidden) continue;
      final baseName = char?.displayName?.trim().isNotEmpty == true
          ? char!.displayName!.trim()
          : (char?.name ?? 'Unknown');
      // Variation identity is carried as its own field, not concatenated into
      // the name: the list renders it as a chip, and grouping keys off the
      // group id so a character's variations stay under one entry.
      final variant = char?.variantName?.trim();
      final variantGroupId = (char == null || char.variantGroupId.isEmpty)
          ? m.characterId
          : char.variantGroupId;
      // While the origin event (branch/creation) is the most recent thing to
      // have happened, surface it as the preview and sort key so a freshly
      // branched or created chat rises to the top with a "Branched on …" /
      // "Created on …" line instead of a stale copied message.
      var lastMessage = m.lastMessageContent;
      var lastMessageTime = m.lastMessageTimestamp;
      if (m.originKind != null &&
          m.originTimestamp > 0 &&
          m.originTimestamp >= m.lastMessageTimestamp) {
        lastMessage = formatOriginPreview(m.originKind!, m.originTimestamp);
        lastMessageTime = m.originTimestamp;
      }
      result.add(
        ChatSessionInfo(
          sessionId: m.sessionId,
          characterId: m.characterId,
          characterName: baseName,
          variantGroupId: variantGroupId,
          variantName: (variant != null && variant.isNotEmpty) ? variant : null,
          avatarPath: char?.avatarPath,
          lastMessage: lastMessage,
          lastMessageTime: lastMessageTime,
          messageCount: m.messageCount,
          sessionIndex: m.sessionIndex,
          sessionName: m.sessionName,
        ),
      );
    }

    result.sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
    return result;
  }

  Future<void> _updateFromMetadata(
    List<SessionMetadata> allMeta,
    CharacterRepo charRepo,
  ) async {
    final data = await _buildFromMetadata(allMeta, charRepo);
    if (_lastResult != null &&
        _lastResult!.length == data.length &&
        _listEquals(_lastResult!, data)) {
      return;
    }
    _lastResult = data;
    state = AsyncData(data);
  }

  static bool _listEquals(List<ChatSessionInfo> a, List<ChatSessionInfo> b) {
    for (int i = 0; i < a.length; i++) {
      final ai = a[i], bi = b[i];
      if (ai.sessionId != bi.sessionId ||
          ai.characterName != bi.characterName ||
          ai.variantName != bi.variantName ||
          ai.variantGroupId != bi.variantGroupId ||
          ai.avatarPath != bi.avatarPath ||
          ai.lastMessageTime != bi.lastMessageTime ||
          ai.messageCount != bi.messageCount ||
          ai.lastMessage != bi.lastMessage ||
          ai.sessionName != bi.sessionName) {
        return false;
      }
    }
    return true;
  }

  Future<void> deleteSession(String sessionId) async {
    final studioConfig = await ref
        .read(studioConfigRepoProvider)
        .getBySessionId(sessionId);
    await ref.read(sessionDeletionRepoProvider).deleteSession(sessionId);
    ChatSessionService.clearCache();
    await SyncDeletionTracker.record('chat', sessionId);
    await SyncDeletionTracker.record('memory_book', sessionId);
    await SyncDeletionTracker.record('tracker_value', sessionId);
    await SyncDeletionTracker.record('tracker_snapshot', sessionId);
    final studioProfileId = studioConfig?.profileId ?? '';
    if (studioConfig != null &&
        (studioProfileId.isEmpty || studioProfileId == sessionId)) {
      await SyncDeletionTracker.record('studio_config', sessionId);
    }
  }

  Future<void> clearChat(String sessionId) async {
    final clearedSession = await ref
        .read(sessionDeletionRepoProvider)
        .clearSession(sessionId: sessionId, replacementMessages: const []);
    if (clearedSession == null) return;
    ChatSessionService.updateCache(clearedSession);
    ref.invalidate(memoryBookProvider(sessionId));
    ref.read(messageVariablesProvider.notifier).clearSession(sessionId);
    await SyncDeletionTracker.recordSessionRuntimeClear(sessionId);
  }

  Future<void> renameSession(String sessionId, String newName) async {
    final chatRepo = ref.read(chatRepoProvider);
    final updated = await chatRepo.renameSession(
      sessionId: sessionId,
      name: newName,
    );
    if (updated == null) return;
    ChatSessionService.updateCache(updated);
    final durableName = updated.sessionVars['sessionName'];
    state = state.whenData(
      (sessions) => [
        for (final item in sessions)
          item.sessionId == sessionId
              ? item.withSessionName(durableName)
              : item,
      ],
    );
  }
}
