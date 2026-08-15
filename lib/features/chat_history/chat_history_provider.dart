import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/repositories/character_repo.dart' show CharacterRepo;
import '../../core/models/chat_message.dart';
import '../../core/state/character_provider.dart'
    show revealHiddenCharactersProvider;
import '../../core/state/db_provider.dart';
import '../../core/utils/sync_deletion_tracker.dart';
import '../../shared/utils/time_formatter.dart';
import '../chat/chat_provider.dart';
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

  /// This session's own variation avatar.
  final String? avatarPath;

  /// Avatar of the group's original. The collapsed group header stands for the
  /// whole character rather than for one of its variations, so it uses this and
  /// its face stops changing with whichever variation you chatted with last.
  final String? groupAvatarPath;

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
    this.groupAvatarPath,
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
    groupAvatarPath: groupAvatarPath,
    lastMessage: lastMessage,
    lastMessageTime: lastMessageTime,
    messageCount: messageCount,
    sessionIndex: sessionIndex,
    sessionName: name,
  );
}

/// Preview line and sort key for one session row.
///
/// While the origin event (branch/creation) is the most recent thing to have
/// happened, it *is* the preview: a freshly branched or created chat rises to
/// the top with a "Branched on …" / "Created on …" line instead of a stale
/// copied message.
///
/// Shared so the chat list and the session pickers cannot drift apart — they
/// are the same list of the same rows, just scoped differently.
({String preview, int time}) sessionPreviewAndTime(SessionMetadata m) {
  if (m.originKind != null &&
      m.originTimestamp > 0 &&
      m.originTimestamp >= m.lastMessageTimestamp) {
    return (
      preview: formatOriginPreview(m.originKind!, m.originTimestamp),
      time: m.originTimestamp,
    );
  }
  return (preview: m.lastMessageContent, time: m.lastMessageTimestamp);
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
    // Keyed by group, not by session character: a group's original may have no
    // chats of its own, so it can be missing from [charMap] entirely.
    final groupAvatars = await charRepo.getGroupAvatars();

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
      final row = sessionPreviewAndTime(m);
      final lastMessage = row.preview;
      final lastMessageTime = row.time;
      result.add(
        ChatSessionInfo(
          sessionId: m.sessionId,
          characterId: m.characterId,
          characterName: baseName,
          variantGroupId: variantGroupId,
          variantName: (variant != null && variant.isNotEmpty) ? variant : null,
          avatarPath: char?.avatarPath,
          groupAvatarPath: groupAvatars[variantGroupId] ?? char?.avatarPath,
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
          ai.groupAvatarPath != bi.groupAvatarPath ||
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
    final charId = _characterIdOf(sessionId);
    await ref.read(sessionDeletionRepoProvider).deleteSession(sessionId);
    ChatSessionService.clearCache();
    // The chat screen may still be bound to the row that just went away. Left
    // alone it keeps serving the deleted session, and its next write recreates
    // the row it was deleted from (`commitDeleteMessages` ends in a full
    // `ChatRepo.put`). Rebuilding picks the next surviving session, or a fresh
    // one when this was the last.
    if (charId != null) ref.invalidate(chatProvider(charId));
    await SyncDeletionTracker.record('chat', sessionId);
    await SyncDeletionTracker.record('memory_book', sessionId);
    await SyncDeletionTracker.record('tracker_value', sessionId);
    await SyncDeletionTracker.record('tracker_snapshot', sessionId);
    await SyncDeletionTracker.record('reconciliation_state', sessionId);
    if (studioConfig != null) {
      await SyncDeletionTracker.record('studio_config', sessionId);
    }
  }

  /// Character a session belongs to. Read from the loaded list when possible;
  /// otherwise derived from the id, which is always `${charId}_$sessionIndex`
  /// (character ids never end in `_<digits>`). Null when neither resolves.
  String? _characterIdOf(String sessionId) {
    for (final info in state.value ?? const <ChatSessionInfo>[]) {
      if (info.sessionId == sessionId) return info.characterId;
    }
    final separator = sessionId.lastIndexOf('_');
    if (separator <= 0) return null;
    final suffix = sessionId.substring(separator + 1);
    if (suffix.isEmpty || int.tryParse(suffix) == null) return null;
    return sessionId.substring(0, separator);
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
