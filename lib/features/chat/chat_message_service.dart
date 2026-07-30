import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/llm/tokenizer.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/tracker_snapshot.dart';
import '../../core/utils/time_helpers.dart';
import '../../core/state/db_provider.dart';
import '../../shared/widgets/glaze_toast.dart';
import '../extensions/providers/info_blocks_provider.dart';
import 'chat_session_service.dart';

class ChatMessageService {
  final Ref _ref;

  ChatMessageService(this._ref);

  ChatSession editMessage(
    ChatSession session,
    int index,
    String newContent, {
    String? tagStart,
    String? tagEnd,
  }) {
    if (index < 0 || index >= session.messages.length) return session;
    final msg = session.messages[index];

    var text = newContent;
    String? newReasoning = msg.reasoning;
    bool isAllReasoning = msg.isAllReasoning;

    if (tagStart != null && tagEnd != null) {
      if (text.contains(tagStart)) {
        final startIdx = text.indexOf(tagStart);
        final endIdx = text.indexOf(tagEnd, startIdx + tagStart.length);
        if (endIdx != -1) {
          newReasoning = text
              .substring(startIdx + tagStart.length, endIdx)
              .trim();
          text =
              (text.substring(0, startIdx) +
                      text.substring(endIdx + tagEnd.length))
                  .trim();
          if (newReasoning.isEmpty) newReasoning = null;
        } else {
          newReasoning = text.substring(startIdx + tagStart.length).trim();
          text = '';
        }
        isAllReasoning =
            text.isEmpty && (newReasoning != null && newReasoning.isNotEmpty);
      } else {
        newReasoning = null;
        isAllReasoning = false;
      }
    }

    if (msg.content == text && msg.reasoning == newReasoning) return session;
    final newMessages = List<ChatMessage>.from(session.messages);
    final swipeIdx = msg.swipeId;
    final updatedSwipes =
        msg.swipes.isNotEmpty && swipeIdx >= 0 && swipeIdx < msg.swipes.length
        ? (List<String>.from(msg.swipes)..[swipeIdx] = text)
        : msg.swipes;
    final updatedSwipesMeta = List<Map<String, dynamic>>.from(msg.swipesMeta);
    if (swipeIdx >= 0 && swipeIdx < updatedSwipesMeta.length) {
      updatedSwipesMeta[swipeIdx] = {
        ...updatedSwipesMeta[swipeIdx],
        'reasoning': newReasoning,
      };
    }
    newMessages[index] = msg.copyWith(
      content: text,
      reasoning: newReasoning,
      isAllReasoning: isAllReasoning,
      swipes: updatedSwipes,
      swipesMeta: updatedSwipesMeta,
      tokens: estimateTokens(text),
    );
    return _persist(session, newMessages);
  }

  ChatSession moveMessage(ChatSession session, int fromIndex, int toIndex) {
    final msgs = session.messages;
    if (fromIndex < 0 || fromIndex >= msgs.length) return session;
    if (toIndex < 0 || toIndex >= msgs.length) return session;
    if (fromIndex == toIndex) return session;
    final newMessages = List<ChatMessage>.from(msgs);
    final moved = newMessages.removeAt(fromIndex);
    newMessages.insert(toIndex, moved);
    return _persist(session, newMessages);
  }

  Future<ChatSession> deleteMessage(ChatSession session, int index) {
    return deleteMessages(session, {index});
  }

  /// Deletes multiple messages with one session write and one cleanup pass.
  ///
  /// Convenience wrapper over [planDeleteMessages] + [commitDeleteMessages] for
  /// callers that do not need to paint the removal before the writes land. The
  /// chat UI uses the two halves directly so the bubbles disappear on the frame
  /// of the tap (see `ChatMessageOpsController.deleteMessages`).
  Future<ChatSession> deleteMessages(
    ChatSession session,
    Set<int> indices,
  ) async {
    final plan = planDeleteMessages(session, indices);
    if (plan == null) return session;
    return commitDeleteMessages(session, plan);
  }

  /// Synchronous half of a message deletion: the session as it will look once
  /// the delete lands, plus everything [commitDeleteMessages] needs to clean up
  /// the dependent tables. Returns null when [indices] selects nothing, so a
  /// caller can bail out before touching any state.
  ///
  /// Split out of [deleteMessages] so the UI can publish the shortened message
  /// list immediately — the commit below runs a multi-table transaction whose
  /// latency is visible as a stuck Delete button on long chats.
  MessageDeletionPlan? planDeleteMessages(
    ChatSession session,
    Set<int> indices,
  ) {
    final validIndices = indices
        .where((index) => index >= 0 && index < session.messages.length)
        .toSet();
    if (validIndices.isEmpty) return null;

    final earliestDeletedIndex = validIndices.reduce((a, b) => a < b ? a : b);
    final invalidatedMessageIds = session.messages
        .skip(earliestDeletedIndex)
        .map((message) => message.id)
        .where((id) => id.isNotEmpty)
        .toSet();
    final newMessages = <ChatMessage>[
      for (var i = 0; i < session.messages.length; i++)
        if (!validIndices.contains(i)) session.messages[i],
    ];

    // Track the running count of deleted messages so the chat statistics can
    // report it after the messages themselves are gone. Every per-message
    // delete path (single + bulk, native menu, selection mode) funnels through
    // here, so this is the single choke point. Chat deletion drops the whole
    // session and this counter with it, which is the one excluded case.
    final updatedVars = Map<String, String>.from(session.sessionVars)
      ..[ChatSessionX.deletedMessagesVarKey] =
          (session.deletedMessageCount + validIndices.length).toString();

    return MessageDeletionPlan(
      session: session.copyWith(
        messages: newMessages,
        sessionVars: updatedVars,
        updatedAt: currentTimestampSeconds(),
      ),
      deletedIndices: validIndices,
      earliestDeletedIndex: earliestDeletedIndex,
      invalidatedMessageIds: invalidatedMessageIds,
    );
  }

  /// Persists [plan] and rolls back everything anchored at or after the
  /// earliest deleted message. [session] is the *pre-delete* session — the
  /// snapshot search walks its surviving prefix to pick a rollback base.
  ///
  /// Throws whatever the transaction throws; the caller owns the decision to
  /// restore [session] in the UI.
  Future<ChatSession> commitDeleteMessages(
    ChatSession session,
    MessageDeletionPlan plan,
  ) async {
    final snapshotRepo = _ref.read(trackerSnapshotRepoProvider);
    final trackerRepo = _ref.read(trackerRepoProvider);
    final memoryBookRepo = _ref.read(memoryBookRepoProvider);
    final knowledgeRepo = _ref.read(characterKnowledgeFactRepoProvider);
    final checkpointRepo = _ref.read(
      ledgerReconciliationCheckpointRepoProvider,
    );
    final chatRepo = _ref.read(chatRepoProvider);
    final updated = plan.session;
    final invalidatedMessageIds = plan.invalidatedMessageIds;

    // Select the rollback base by chat order. Snapshot timestamps have
    // second-level precision and cannot reliably order adjacent turns.
    TrackerSnapshot? fallbackSnapshot;
    for (final message
        in session.messages.take(plan.earliestDeletedIndex).toList().reversed) {
      final candidate = await snapshotRepo.getByAnchor(
        sessionId: session.id,
        messageId: message.id,
        swipeId: message.swipeId,
        agentSwipeId: message.agentSwipeId,
      );
      if (candidate?.committed == true) {
        fallbackSnapshot = candidate;
        break;
      }
    }

    await chatRepo.transaction(() async {
      await knowledgeRepo.rollbackReconciliationCleanupForMessages(
        session.id,
        invalidatedMessageIds,
      );
      await knowledgeRepo.retractForMessages(session.id, invalidatedMessageIds);
      await memoryBookRepo.deleteForMessages(session.id, invalidatedMessageIds);
      await snapshotRepo.deleteForMessages(session.id, invalidatedMessageIds);
      await checkpointRepo.deleteBySessionId(session.id);
      await trackerRepo.replaceLedgerState(
        session.id,
        fallbackSnapshot?.trackers ?? const [],
      );
      await chatRepo.put(updated);
    });

    // Current chunk indices no longer map to the same message ranges. Drop the
    // session index now; post-generation indexing will rebuild current chunks.
    try {
      await _ref
          .read(embeddingRepoProvider)
          .deleteBySource('chat_message', session.id);
    } catch (e) {
      debugPrint('[ChatMessageService] failed to clear message index: $e');
    }

    ChatSessionService.updateCache(updated);
    return updated;
  }

  ChatSession toggleMessageHidden(ChatSession session, int index) {
    if (index < 0 || index >= session.messages.length) return session;
    final newMessages = List<ChatMessage>.from(session.messages);
    newMessages[index] = newMessages[index].copyWith(
      isHidden: !newMessages[index].isHidden,
    );
    return _persist(session, newMessages);
  }

  /// Flips [ChatMessage.imageHidden] for the message at [index]. The bubble
  /// keeps showing the attachment either way — only prompt inclusion changes
  /// (see `HistoryAssembler.assemble`). No-op when the message carries no
  /// image.
  ChatSession toggleImageHidden(ChatSession session, int index) {
    if (index < 0 || index >= session.messages.length) return session;
    final msg = session.messages[index];
    if (msg.imagePath == null || msg.imagePath!.isEmpty) return session;
    final newMessages = List<ChatMessage>.from(session.messages);
    newMessages[index] = msg.copyWith(imageHidden: !msg.imageHidden);
    return _persist(session, newMessages);
  }

  ChatSession unhideAllMessages(ChatSession session) {
    bool changed = false;
    final newMessages = session.messages.map((m) {
      if (m.isHidden) {
        changed = true;
        return m.copyWith(isHidden: false);
      }
      return m;
    }).toList();
    if (!changed) return session;
    return _persist(session, newMessages);
  }

  ChatSession hideTopMessages(ChatSession session, int count) {
    final visibleIndices = <int>[];
    for (int i = 0; i < session.messages.length; i++) {
      if (!session.messages[i].isHidden) visibleIndices.add(i);
    }
    final toHide = visibleIndices.take(count).toList();
    if (toHide.isEmpty) return session;
    final newMessages = List<ChatMessage>.from(session.messages);
    for (final idx in toHide) {
      newMessages[idx] = newMessages[idx].copyWith(isHidden: true);
    }
    return _persist(session, newMessages);
  }

  ChatSession setSwipe(ChatSession session, int messageIndex, int swipeId) {
    if (messageIndex < 0 || messageIndex >= session.messages.length) {
      return session;
    }
    final msg = session.messages[messageIndex];
    if (msg.swipes.isEmpty || swipeId < 0 || swipeId >= msg.swipes.length) {
      return session;
    }

    final meta = swipeId < msg.swipesMeta.length
        ? msg.swipesMeta[swipeId]
        : null;

    final swipesMeta = List<Map<String, dynamic>>.from(msg.swipesMeta);
    // Ensure swipesMeta is long enough.
    while (swipesMeta.length < msg.swipes.length) {
      swipesMeta.add(<String, dynamic>{});
    }
    // Nested swipes: persist current agentSwipes into the outgoing green
    // swipe's meta, then load (or seed) agentSwipes for the incoming swipe.
    // Save outgoing agentSwipes.
    if (msg.agentSwipes.isNotEmpty && msg.swipeId < swipesMeta.length) {
      swipesMeta[msg.swipeId] = {
        ...swipesMeta[msg.swipeId],
        'agentSwipes': msg.agentSwipes.map((e) => e.toJson()).toList(),
        'agentSwipeId': msg.agentSwipeId,
      };
    }
    // Load incoming agentSwipes.
    List<AgentSwipe> nextAgentSwipes;
    int nextAgentSwipeId;
    final storedAgentSwipes = _agentSwipesFromMeta(meta);
    if (storedAgentSwipes != null && storedAgentSwipes.isNotEmpty) {
      nextAgentSwipes = storedAgentSwipes;
      nextAgentSwipeId = (meta?['agentSwipeId'] as int?) ?? 0;
    } else {
      // Seed a single 'final' from the green swipe content.
      nextAgentSwipes = [
        AgentSwipe(
          content: msg.swipes[swipeId],
          kind: 'final',
          reasoning: meta?['reasoning'] as String?,
          genTime: meta?['genTime'] as String?,
          tokens: meta?['tokens'] as int?,
          studioOutputs: _studioOutputsFromMeta(meta),
        ),
      ];
      nextAgentSwipeId = 0;
    }

    // The active content is the active blue swipe (if any), else the green.
    final activeContent = nextAgentSwipes.isNotEmpty
        ? nextAgentSwipes[nextAgentSwipeId.clamp(0, nextAgentSwipes.length - 1)]
              .content
        : msg.swipes[swipeId];

    final updated = msg.copyWith(
      swipeId: swipeId,
      content: activeContent,
      // Switching variation is fresh activity: restamp so the chat list
      // (sorted on the last message's timestamp) reorders. The message keeps
      // its position inside the chat — only the stamp moves.
      timestamp: DateTime.now().millisecondsSinceEpoch,
      // Error state is tracked per-swipe (swipesMeta[i]['isError']) so the
      // error styling follows the active variation only. Navigating to a
      // healthy swipe clears the error window; navigating back restores it.
      isError: meta?['isError'] == true,
      reasoning: nextAgentSwipes.isNotEmpty
          ? nextAgentSwipes[nextAgentSwipeId.clamp(
                  0,
                  nextAgentSwipes.length - 1,
                )]
                .reasoning
          : meta?['reasoning'] as String?,
      genTime: nextAgentSwipes.isNotEmpty
          ? nextAgentSwipes[nextAgentSwipeId.clamp(
                  0,
                  nextAgentSwipes.length - 1,
                )]
                .genTime
          : meta?['genTime'] as String?,
      tokens: nextAgentSwipes.isNotEmpty
          ? nextAgentSwipes[nextAgentSwipeId.clamp(
                  0,
                  nextAgentSwipes.length - 1,
                )]
                .tokens
          : meta?['tokens'] as int?,
      triggeredLorebooks: _triggeredFromMeta(meta, 'triggeredLorebooks'),
      triggeredMemories: _triggeredFromMeta(meta, 'triggeredMemories'),
      studioOutputs: nextAgentSwipes.isNotEmpty
          ? nextAgentSwipes[nextAgentSwipeId.clamp(
                  0,
                  nextAgentSwipes.length - 1,
                )]
                .studioOutputs
          : _studioOutputsFromMeta(meta),
      swipesMeta: swipesMeta,
      agentSwipes: nextAgentSwipes,
      agentSwipeId: nextAgentSwipeId,
    );
    final newMessages = List<ChatMessage>.from(session.messages);
    newMessages[messageIndex] = updated;
    return _persist(session, newMessages);
  }

  /// Parse agentSwipes stored in [swipesMeta] meta. Returns null if absent.
  static List<AgentSwipe>? _agentSwipesFromMeta(Map<String, dynamic>? meta) {
    final raw = meta?['agentSwipes'];
    if (raw is! List) return null;
    final swipes = raw
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => AgentSwipe.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    // Lazy migration: older 'cleaned' swipes were saved with empty
    // studioOutputs (before appendAgentSwipe started inheriting them from
    // the parent 'final'). Backfill so that switching to a cleaned blue
    // swipe keeps the Studio regen button visible.
    for (var i = 0; i < swipes.length; i++) {
      if (swipes[i].kind == 'cleaned' &&
          swipes[i].studioOutputs.isEmpty &&
          swipes[i].parentSwipeId != null &&
          swipes[i].parentSwipeId! < swipes.length) {
        final parent = swipes[swipes[i].parentSwipeId!];
        if (parent.studioOutputs.isNotEmpty) {
          swipes[i] = swipes[i].copyWith(studioOutputs: parent.studioOutputs);
        }
      }
    }
    return swipes;
  }

  /// Set the active blue sub-swipe (agentSwipeId) for a message without
  /// changing the green swipe. The message content/reasoning/tokens are
  /// restored from the selected AgentSwipe.
  ChatSession setAgentSwipe(
    ChatSession session,
    int messageIndex,
    int agentSwipeId,
  ) {
    if (messageIndex < 0 || messageIndex >= session.messages.length) {
      return session;
    }
    final msg = session.messages[messageIndex];
    if (msg.agentSwipes.isEmpty ||
        agentSwipeId < 0 ||
        agentSwipeId >= msg.agentSwipes.length) {
      return session;
    }
    final swipe = msg.agentSwipes[agentSwipeId];
    final swipesMeta = _syncAgentSwipesToMeta(
      msg.swipesMeta,
      msg.swipeId,
      msg.agentSwipes,
      agentSwipeId,
    );
    final updated = msg.copyWith(
      agentSwipeId: agentSwipeId,
      content: swipe.content,
      // Same rule as the green swipes above: restamp on variation switch.
      timestamp: DateTime.now().millisecondsSinceEpoch,
      reasoning: swipe.reasoning,
      genTime: swipe.genTime,
      tokens: swipe.tokens,
      studioOutputs: swipe.studioOutputs,
      swipesMeta: swipesMeta,
    );
    final newMessages = List<ChatMessage>.from(session.messages);
    newMessages[messageIndex] = updated;
    return _persist(session, newMessages);
  }

  Future<ChatSession> deleteActiveSwipe(
    ChatSession session,
    int messageIndex,
  ) async {
    if (messageIndex < 0 || messageIndex >= session.messages.length) {
      return session;
    }
    final original = session.messages[messageIndex];
    if (removeActiveSwipe(original) == null) return session;
    return _deleteSwipeVariation(
      session: session,
      messageId: original.id,
      removeAgentSwipe: false,
    );
  }

  Future<ChatSession> deleteActiveAgentSwipe(
    ChatSession session,
    int messageIndex,
  ) async {
    if (messageIndex < 0 || messageIndex >= session.messages.length) {
      return session;
    }
    final original = session.messages[messageIndex];
    if (removeActiveAgentSwipe(original) == null) return session;
    return _deleteSwipeVariation(
      session: session,
      messageId: original.id,
      removeAgentSwipe: true,
    );
  }

  Future<ChatSession> _deleteSwipeVariation({
    required ChatSession session,
    required String messageId,
    required bool removeAgentSwipe,
  }) async {
    final chatRepo = _ref.read(chatRepoProvider);
    final snapshots = _ref.read(trackerSnapshotRepoProvider);
    final facts = _ref.read(characterKnowledgeFactRepoProvider);
    final memory = _ref.read(memoryBookRepoProvider);
    final blocks = _ref.read(infoBlocksRepoProvider);
    late ChatSession updatedSession;
    late ChatMessage updatedMessage;

    await chatRepo.transaction(() async {
      final latest = await chatRepo.getById(session.id);
      if (latest == null) throw StateError('Chat session no longer exists.');
      final messageIndex = latest.messages.indexWhere(
        (message) => message.id == messageId,
      );
      if (messageIndex < 0) throw StateError('Chat message no longer exists.');
      final original = latest.messages[messageIndex];
      final removedSwipeId = original.swipeId;
      final removedAgentSwipeId = removeAgentSwipe
          ? original.agentSwipeId
          : null;
      final replacement = removeAgentSwipe
          ? removeActiveAgentSwipe(original)
          : removeActiveSwipe(original);
      if (replacement == null) {
        throw StateError('The last remaining swipe cannot be deleted.');
      }
      updatedMessage = replacement;
      updatedSession = latest.copyWith(
        messages: List<ChatMessage>.from(latest.messages)
          ..[messageIndex] = replacement,
        updatedAt: currentTimestampSeconds(),
      );

      if (!removeAgentSwipe) {
        await snapshots.deleteSwipe(
          sessionId: session.id,
          messageId: messageId,
          swipeId: removedSwipeId,
        );
        await snapshots.shiftSwipeIdsAfterRemoval(
          sessionId: session.id,
          messageId: messageId,
          removedSwipeId: removedSwipeId,
        );
        await facts.deleteSwipeAndShift(
          sessionId: session.id,
          messageId: messageId,
          removedSwipeId: removedSwipeId,
        );
        await memory.deleteSwipeAndShift(
          sessionId: session.id,
          messageId: messageId,
          removedSwipeId: removedSwipeId,
        );
        await blocks.deleteSwipeAndShift(
          sessionId: session.id,
          messageId: messageId,
          removedSwipeId: removedSwipeId,
        );
      } else {
        await snapshots.deleteAnchor(
          sessionId: session.id,
          messageId: messageId,
          swipeId: removedSwipeId,
          agentSwipeId: removedAgentSwipeId!,
        );
        await snapshots.shiftAgentSwipeIdsAfterRemoval(
          sessionId: session.id,
          messageId: messageId,
          swipeId: removedSwipeId,
          removedAgentSwipeId: removedAgentSwipeId,
        );
        await facts.deleteAgentSwipeAndShift(
          sessionId: session.id,
          messageId: messageId,
          swipeId: removedSwipeId,
          removedAgentSwipeId: removedAgentSwipeId,
        );
        await memory.deleteAgentSwipeAndShift(
          sessionId: session.id,
          messageId: messageId,
          swipeId: removedSwipeId,
          removedAgentSwipeId: removedAgentSwipeId,
        );
        await blocks.deleteAgentSwipeAndShift(
          sessionId: session.id,
          messageId: messageId,
          swipeId: removedSwipeId,
          removedAgentSwipeId: removedAgentSwipeId,
        );
      }
      await _ref
          .read(ledgerReconciliationCheckpointRepoProvider)
          .deleteForMessages(session.id, {messageId});
      await _ref
          .read(embeddingRepoProvider)
          .deleteBySource('chat_message', session.id);
      await chatRepo.put(updatedSession);
    });

    final activeSnapshot = await snapshots.getByAnchor(
      sessionId: session.id,
      messageId: messageId,
      swipeId: updatedMessage.swipeId,
      agentSwipeId: updatedMessage.agentSwipeId,
    );
    final fallback =
        activeSnapshot ?? await snapshots.getLatestCommitted(session.id);
    if (fallback == null) {
      await _ref.read(trackerRepoProvider).clearForSession(session.id);
    } else {
      await _ref
          .read(trackerRepoProvider)
          .replaceForSession(session.id, fallback.trackers);
    }

    ChatSessionService.updateCache(updatedSession);
    _ref.invalidate(memoryBookProvider(session.id));
    await _ref.read(infoBlocksProvider(session.id).notifier).refresh();
    return updatedSession;
  }

  @visibleForTesting
  static ChatMessage? removeActiveSwipe(ChatMessage message) {
    if (message.swipes.length <= 1 ||
        message.swipeId < 0 ||
        message.swipeId >= message.swipes.length) {
      return null;
    }
    final removed = message.swipeId;
    final swipes = List<String>.from(message.swipes);
    final meta = List<Map<String, dynamic>>.generate(
      swipes.length,
      (index) => index < message.swipesMeta.length
          ? Map<String, dynamic>.from(message.swipesMeta[index])
          : <String, dynamic>{},
    );
    meta[removed] = {
      ...meta[removed],
      'agentSwipes': message.agentSwipes.map((e) => e.toJson()).toList(),
      'agentSwipeId': message.agentSwipeId,
    };
    swipes.removeAt(removed);
    meta.removeAt(removed);
    final nextSwipeId = removed.clamp(0, swipes.length - 1);
    final nextMeta = meta[nextSwipeId];
    final stored = _agentSwipesFromMeta(nextMeta);
    final agentSwipes = stored == null || stored.isEmpty
        ? [
            AgentSwipe(
              content: swipes[nextSwipeId],
              reasoning: nextMeta['reasoning'] as String?,
              genTime: nextMeta['genTime'] as String?,
              tokens: nextMeta['tokens'] as int?,
              studioOutputs: _studioOutputsFromMeta(nextMeta),
            ),
          ]
        : stored;
    final agentSwipeId = ((nextMeta['agentSwipeId'] as int?) ?? 0).clamp(
      0,
      agentSwipes.length - 1,
    );
    final active = agentSwipes[agentSwipeId];
    meta[nextSwipeId] = {
      ...nextMeta,
      'agentSwipes': agentSwipes.map((e) => e.toJson()).toList(),
      'agentSwipeId': agentSwipeId,
    };
    return message.copyWith(
      swipes: swipes,
      swipeId: nextSwipeId,
      swipesMeta: meta,
      agentSwipes: agentSwipes,
      agentSwipeId: agentSwipeId,
      content: active.content,
      reasoning: active.reasoning,
      isAllReasoning:
          active.content.isEmpty && (active.reasoning?.isNotEmpty ?? false),
      genTime: active.genTime,
      tokens: active.tokens,
      studioOutputs: active.studioOutputs,
      isError: nextMeta['isError'] == true,
      triggeredLorebooks: _triggeredFromMeta(nextMeta, 'triggeredLorebooks'),
      triggeredMemories: _triggeredFromMeta(nextMeta, 'triggeredMemories'),
    );
  }

  @visibleForTesting
  static ChatMessage? removeActiveAgentSwipe(ChatMessage message) {
    if (message.agentSwipes.length <= 1 ||
        message.agentSwipeId < 0 ||
        message.agentSwipeId >= message.agentSwipes.length) {
      return null;
    }
    final removed = message.agentSwipeId;
    final removedSwipe = message.agentSwipes[removed];
    final swipes = List<AgentSwipe>.from(message.agentSwipes)
      ..removeAt(removed);
    final fallbackParent = swipes.indexWhere((swipe) => swipe.kind == 'final');
    for (var i = 0; i < swipes.length; i++) {
      final swipe = swipes[i];
      var parent = swipe.parentSwipeId;
      if (parent != null) {
        if (parent > removed) {
          parent--;
        } else if (parent == removed) {
          parent = fallbackParent >= 0 ? fallbackParent : null;
        }
      }
      swipes[i] = AgentSwipe(
        content: swipe.content,
        kind: swipe.kind,
        reasoning: swipe.reasoning,
        genTime: swipe.genTime,
        tokens: swipe.tokens,
        studioOutputs: swipe.studioOutputs,
        parentSwipeId: parent,
      );
    }
    final nextAgentSwipeId = removed.clamp(0, swipes.length - 1);
    final active = swipes[nextAgentSwipeId];
    final greenSwipes = List<String>.from(message.swipes);
    if (removedSwipe.kind == 'final' &&
        message.swipeId >= 0 &&
        message.swipeId < greenSwipes.length) {
      final replacement = swipes.firstWhere(
        (swipe) => swipe.kind == 'final',
        orElse: () => active,
      );
      greenSwipes[message.swipeId] = replacement.content;
    }
    final meta = _syncAgentSwipesToMeta(
      message.swipesMeta,
      message.swipeId,
      swipes,
      nextAgentSwipeId,
    );
    return message.copyWith(
      content: active.content,
      reasoning: active.reasoning,
      isAllReasoning:
          active.content.isEmpty && (active.reasoning?.isNotEmpty ?? false),
      genTime: active.genTime,
      tokens: active.tokens,
      studioOutputs: active.studioOutputs,
      swipes: greenSwipes,
      swipesMeta: meta,
      agentSwipes: swipes,
      agentSwipeId: nextAgentSwipeId,
    );
  }

  /// Sync agentSwipes + agentSwipeId into swipesMeta[swipeId].
  static List<Map<String, dynamic>> _syncAgentSwipesToMeta(
    List<Map<String, dynamic>> swipesMeta,
    int swipeId,
    List<AgentSwipe> agentSwipes,
    int agentSwipeId,
  ) {
    if (swipeId < 0 || agentSwipes.isEmpty) return swipesMeta;
    final meta = List<Map<String, dynamic>>.from(swipesMeta);
    while (meta.length <= swipeId) {
      meta.add(<String, dynamic>{});
    }
    meta[swipeId] = {
      ...meta[swipeId],
      'agentSwipes': agentSwipes.map((e) => e.toJson()).toList(),
      'agentSwipeId': agentSwipeId,
    };
    return meta;
  }

  /// Parse the per-swipe triggered entries stored in [swipesMeta]. Each
  /// variation persists its own lorebook/memory activations so the chat UI
  /// (native sheet + webview) shows them per swipe instead of leaking the
  /// last-generated swipe's entries onto every variation.
  static List<TriggeredEntry> _triggeredFromMeta(
    Map<String, dynamic>? meta,
    String key,
  ) {
    final raw = meta?[key];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => TriggeredEntry.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  static List<Map<String, dynamic>> _studioOutputsFromMeta(
    Map<String, dynamic>? meta,
  ) {
    final raw = meta?['studioOutputs'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  /// Mirrors Glaze/src/composables/chat/useSwipeNavigation.js → `changeSwipe`.
  /// `dir`: +1 forward, -1 back. `fromSwipe`: animation hint (slide vs fade).
  /// Returns a [ChangeSwipeResult] describing whether the session was updated,
  /// whether the caller should regenerate a new variant, and whether nothing
  /// happened (out of bounds / single swipe / generating).
  ChangeSwipeResult changeSwipe(
    ChatSession session,
    int messageIndex,
    int dir, {
    bool fromSwipe = false,
    bool isLastMessage = false,
  }) {
    if (messageIndex < 0 || messageIndex >= session.messages.length) {
      return const ChangeSwipeResult.noop();
    }
    final msg = session.messages[messageIndex];
    final animDir = fromSwipe
        ? (dir > 0 ? 'slide-next' : 'slide-prev')
        : 'fade';

    if (msg.swipes.length <= 1) return const ChangeSwipeResult.noop();

    final newIndex = msg.swipeId + dir;

    // Right-edge on the last message → caller should kick off a new variant.
    if (dir > 0 && newIndex >= msg.swipes.length && isLastMessage) {
      return const ChangeSwipeResult.needsRegen();
    }
    if (newIndex < 0 || newIndex >= msg.swipes.length) {
      return const ChangeSwipeResult.noop();
    }

    // Delegate to setSwipe for the heavy lifting (agentSwipes save/load,
    // content/reasoning/meta restoration + per-swipe isError). Then patch
    // swipeDirection for the slide animation. Error variants are kept as
    // navigable swipes; the error styling is derived per-swipe in setSwipe.
    final swapped = setSwipe(session, messageIndex, newIndex);
    final swappedMsg = swapped.messages[messageIndex];
    final patched = swappedMsg.copyWith(swipeDirection: animDir);
    final patchedMessages = List<ChatMessage>.from(swapped.messages)
      ..[messageIndex] = patched;
    return ChangeSwipeResult.updated(_persist(session, patchedMessages));
  }

  /// Change the active blue sub-swipe (agentSwipeId) by [dir].
  ///
  /// Mirrors the green-swipe navigation but operates on `agentSwipes[]`.
  /// Right-edge on the last message → [ChangeSwipeResult.needsRegen] so the
  /// caller can kick off a full regeneration (new green swipe).
  ChangeSwipeResult changeAgentSwipe(
    ChatSession session,
    int messageIndex,
    int dir, {
    bool fromSwipe = false,
    bool isLastMessage = false,
  }) {
    if (messageIndex < 0 || messageIndex >= session.messages.length) {
      return const ChangeSwipeResult.noop();
    }
    final msg = session.messages[messageIndex];
    if (msg.agentSwipes.length <= 1) return const ChangeSwipeResult.noop();

    final animDir = fromSwipe
        ? (dir > 0 ? 'slide-next' : 'slide-prev')
        : 'fade';

    var newIndex = msg.agentSwipeId + dir;

    // Wrap-around: index < 0 → last; index >= length → 0.
    if (newIndex < 0) {
      newIndex = msg.agentSwipes.length - 1;
    } else if (newIndex >= msg.agentSwipes.length) {
      // Right-edge on the last message → full regen (new green swipe).
      if (isLastMessage) {
        return const ChangeSwipeResult.needsRegen();
      }
      newIndex = 0;
    }

    final swipe = msg.agentSwipes[newIndex];
    final swipesMeta = _syncAgentSwipesToMeta(
      msg.swipesMeta,
      msg.swipeId,
      msg.agentSwipes,
      newIndex,
    );
    final updated = msg.copyWith(
      agentSwipeId: newIndex,
      content: swipe.content,
      reasoning: swipe.reasoning,
      genTime: swipe.genTime,
      tokens: swipe.tokens,
      studioOutputs: swipe.studioOutputs,
      swipeDirection: animDir,
      swipesMeta: swipesMeta,
    );
    final newMessages = List<ChatMessage>.from(session.messages)
      ..[messageIndex] = updated;
    return ChangeSwipeResult.updated(_persist(session, newMessages));
  }

  ChatSession setGreeting(
    ChatSession session,
    int messageIndex,
    int newGreetingIndex,
    List<String> resolvedGreetings,
  ) {
    if (messageIndex < 0 || messageIndex >= session.messages.length) {
      return session;
    }
    if (resolvedGreetings.length <= 1) return session;
    var idx = newGreetingIndex;
    if (idx < 0) idx = resolvedGreetings.length - 1;
    if (idx >= resolvedGreetings.length) idx = 0;

    final msg = session.messages[messageIndex];
    final newText = resolvedGreetings[idx];
    final updated = msg.copyWith(
      greetingIndex: idx,
      content: newText,
      swipes: [newText],
      swipeId: 0,
      swipesMeta: const [],
      reasoning: null,
      studioOutputs: const [],
      isError: false,
      tokens: estimateTokens(newText),
      genTime: null,
    );
    final newMessages = List<ChatMessage>.from(session.messages);
    newMessages[messageIndex] = updated;
    return _persist(session, newMessages);
  }

  ChatSession _persist(ChatSession session, List<ChatMessage> newMessages) {
    final updated = session.copyWith(
      messages: newMessages,
      updatedAt: currentTimestampSeconds(),
    );
    if (!_ref.mounted) return updated;
    _ref.read(chatRepoProvider).put(updated).catchError((Object e) {
      debugPrint('[ChatMessageService] failed to persist session: $e');
      GlazeToast.showWithoutContext(
        'Failed to save changes: $e',
        isError: true,
        duration: 5000,
      );
    });
    ChatSessionService.updateCache(updated);
    return updated;
  }
}

/// Everything a message deletion needs, computed synchronously by
/// [ChatMessageService.planDeleteMessages] and consumed by
/// [ChatMessageService.commitDeleteMessages].
///
/// Splitting the plan from the commit lets the chat publish [session] (and its
/// bumped deleted-message counter) before the DB work starts, so the bubbles
/// leave the list on the frame of the tap instead of after the transaction.
class MessageDeletionPlan {
  /// The session as it looks once the deletion lands: messages removed,
  /// `deletedMessages` session var bumped, `updatedAt` restamped.
  final ChatSession session;

  /// Indices that were actually in range — the ones this plan deletes.
  final Set<int> deletedIndices;

  /// Lowest index in [deletedIndices]. Everything from here on is invalidated.
  final int earliestDeletedIndex;

  /// Ids of every message at or after [earliestDeletedIndex] in the *original*
  /// session, including the deleted ones. Snapshots, memory entries, knowledge
  /// facts and ext blocks anchored to these ids no longer describe the chat.
  final Set<String> invalidatedMessageIds;

  const MessageDeletionPlan({
    required this.session,
    required this.deletedIndices,
    required this.earliestDeletedIndex,
    required this.invalidatedMessageIds,
  });
}

/// Result of [ChatMessageService.changeSwipe].
/// - `updated`: session was modified, use [session].
/// - `needsRegen`: caller should kick off a new variant via regenerate.
/// - `noop`: nothing happened (out of bounds / single swipe / etc).
class ChangeSwipeResult {
  final ChatSession? session;
  final bool needsRegen;

  const ChangeSwipeResult._(this.session, this.needsRegen);
  const ChangeSwipeResult.updated(ChatSession s) : this._(s, false);
  const ChangeSwipeResult.needsRegen() : this._(null, true);
  const ChangeSwipeResult.noop() : this._(null, false);

  bool get isUpdated => session != null;
  bool get isNoop => session == null && !needsRegen;
}
