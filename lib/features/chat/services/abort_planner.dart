import '../../../core/models/chat_message.dart';
import '../../../core/utils/id_generator.dart';
import '../abort_handler.dart' show AbortSessionMutation;
import '../chat_state.dart';
import 'continuation_message_merger.dart';

/// Works out what a stop leaves in the chat, so the UI can show it on the tap
/// and the database can be brought to the same result afterwards.
class AbortPlanner {
  const AbortPlanner({required this.mutateSession, required this.loadSession});

  final AbortSessionMutation mutateSession;
  final Future<ChatSession?> Function(String sessionId) loadSession;

  /// What a stop leaves behind, worked out once so the UI and the database
  /// agree: [optimistic] is painted on the tap, [persist] writes the same
  /// result against the latest durable row (falling back to reloading it on a
  /// conflict). Null when there is no session to stop.
  AbortPlan? plan(
    ChatState current,
    StreamingState partialStreaming,
    ChatMessage? restoration,
  ) {
    final session = current.session;
    if (session == null) return null;

    AbortPlan reload(ChatSession optimistic) =>
        AbortPlan(optimistic, () => loadSession(session.id));

    AbortPlan mutating(
      ChatSession optimistic,
      ChatSession? Function(ChatSession latest) mutate,
    ) => AbortPlan(
      optimistic,
      () => mutateSession(
        session.id,
        mutate,
      ).then((updated) async => updated ?? await loadSession(session.id)),
    );

    final continuationId = current.continuationTargetId;
    if (continuationId != null) {
      return _planContinuationAbort(
        session,
        partialStreaming,
        continuationId,
        reload: reload,
        mutating: mutating,
      );
    }

    final regenId = current.regenTargetId;
    if (regenId != null && restoration != null) {
      return _planRegenAbort(
        session,
        partialStreaming,
        regenId,
        restoration,
        reload: reload,
        mutating: mutating,
      );
    }

    if (restoration != null) {
      ChatSession? mutate(ChatSession latest) {
        if (latest.messages.any((message) => message.id == restoration.id)) {
          return latest;
        }
        final expectedTailId = session.messages.isEmpty
            ? null
            : session.messages.last.id;
        final latestTailId = latest.messages.isEmpty
            ? null
            : latest.messages.last.id;
        if (latestTailId != expectedTailId) return null;
        return latest.copyWith(messages: [...latest.messages, restoration]);
      }

      return mutating(mutate(session) ?? session, mutate);
    }

    final String partialText = partialStreaming.text;
    final String? partialReasoning = partialStreaming.reasoning;
    final bool hasPartial =
        partialText.isNotEmpty ||
        (partialReasoning != null && partialReasoning.isNotEmpty);
    if (!hasPartial) return reload(session);

    final currentMessages = session.messages;
    final lastMsg = currentMessages.isNotEmpty ? currentMessages.last : null;
    final bool lastIsEmptyAssistant =
        lastMsg != null &&
        lastMsg.role == 'assistant' &&
        lastMsg.content.isEmpty &&
        (lastMsg.reasoning == null || lastMsg.reasoning!.isEmpty);

    final partialMsg = ChatMessage(
      id: generateId(),
      role: 'assistant',
      content: partialText,
      reasoning: partialReasoning,
      isTyping: false,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      swipes: [partialText],
      swipeId: 0,
      swipesMeta: [<String, dynamic>{}],
    );
    final baseMessages = lastIsEmptyAssistant
        ? currentMessages.sublist(0, currentMessages.length - 1)
        : currentMessages;
    final expectedTailId = baseMessages.isEmpty ? null : baseMessages.last.id;
    return mutating(
      session.copyWith(messages: [...baseMessages, partialMsg]),
      (latest) {
        final latestTailId = latest.messages.isEmpty
            ? null
            : latest.messages.last.id;
        if (latestTailId != expectedTailId) return null;
        return latest.copyWith(messages: [...latest.messages, partialMsg]);
      },
    );
  }

  /// Stop pressed while `continueMessage()` was streaming. The partial text
  /// belongs to the message being continued — merge it in place (exactly what
  /// the completed run would have done) instead of appending a separate
  /// assistant bubble, which would contradict what the WebView already shows.
  AbortPlan _planContinuationAbort(
    ChatSession session,
    StreamingState partialStreaming,
    String continuationId, {
    required AbortPlan Function(ChatSession optimistic) reload,
    required AbortPlan Function(
      ChatSession optimistic,
      ChatSession? Function(ChatSession latest) mutate,
    )
    mutating,
  }) {
    final messages = session.messages;
    final idx = messages.indexWhere((m) => m.id == continuationId);
    final partialText = partialStreaming.text.trim();
    if (idx < 0 || partialText.isEmpty) return reload(session);

    final expected = messages[idx];
    ChatMessage merge(ChatMessage target) => mergeContinuationMessage(
      target,
      ChatMessage(
        id: continuationId,
        role: 'assistant',
        content: partialText,
        reasoning: partialStreaming.reasoning,
      ),
    );
    final optimisticMessages = [...messages]..[idx] = merge(expected);
    return mutating(session.copyWith(messages: optimisticMessages), (latest) {
      final latestIdx = latest.messages.indexWhere(
        (m) => m.id == continuationId,
      );
      if (latestIdx < 0 || latestIdx != latest.messages.length - 1) return null;
      final target = latest.messages[latestIdx];
      if (target.content != expected.content ||
          target.swipeId != expected.swipeId ||
          target.agentSwipeId != expected.agentSwipeId) {
        return null;
      }
      final updatedMessages = [...latest.messages]..[latestIdx] = merge(target);
      return latest.copyWith(messages: updatedMessages);
    });
  }

  /// Stop pressed during a regenerate. With partial text the variation it
  /// opened keeps that text; with none, the variation that was on screen
  /// before the regenerate comes back untouched.
  AbortPlan _planRegenAbort(
    ChatSession session,
    StreamingState partialStreaming,
    String regenId,
    ChatMessage restoration, {
    required AbortPlan Function(ChatSession optimistic) reload,
    required AbortPlan Function(
      ChatSession optimistic,
      ChatSession? Function(ChatSession latest) mutate,
    )
    mutating,
  }) {
    final idx = session.messages.indexWhere((m) => m.id == regenId);
    ChatSession withTarget(ChatMessage message) {
      if (idx < 0) return session;
      final messages = [...session.messages]..[idx] = message;
      return session.copyWith(messages: messages);
    }

    final String partialText = partialStreaming.text;
    if (partialText.isEmpty) return reload(withTarget(restoration));

    final keptSwipes = List<String>.from(
      restoration.swipes.isNotEmpty
          ? restoration.swipes
          : [restoration.content],
    );
    final keptSwipesMeta = List<Map<String, dynamic>>.from(
      restoration.swipesMeta.isNotEmpty
          ? restoration.swipesMeta
          : [
              <String, dynamic>{
                'genTime': restoration.genTime,
                'reasoning': restoration.reasoning,
                'tokens': restoration.tokens,
                'time': restoration.time,
              },
            ],
    );
    keptSwipes.add(partialText);
    final partialAgentSwipe = AgentSwipe(
      content: partialText,
      reasoning: partialStreaming.reasoning,
      parentSwipeId: keptSwipes.length - 1,
    );
    keptSwipesMeta.add(<String, dynamic>{
      'agentSwipes': [partialAgentSwipe.toJson()],
      'agentSwipeId': 0,
    });
    final newSwipeId = keptSwipes.length - 1;
    ChatMessage withPartial(ChatMessage target) => target.copyWith(
      content: partialText,
      swipeId: newSwipeId,
      swipes: keptSwipes,
      swipesMeta: keptSwipesMeta,
      reasoning: partialStreaming.reasoning,
      genTime: null,
      tokens: null,
      time: null,
      agentSwipes: [partialAgentSwipe],
      agentSwipeId: 0,
      isTyping: false,
      // Partial text becomes a fresh (healthy) swipe; with nothing
      // streamed we put the pre-regen variation back untouched — an
      // errored one included, so cancelling a regen over an error does
      // not launder the error away.
      isError: false,
      swipeDirection: 'right',
    );

    // The on-screen message is the pending variation the regenerate opened;
    // the durable row still holds [restoration], so the optimistic paint is
    // built from that, exactly as the write below will be.
    return mutating(withTarget(withPartial(restoration)), (latest) {
      final latestIdx = latest.messages.indexWhere((m) => m.id == regenId);
      if (latestIdx < 0) return null;
      final target = latest.messages[latestIdx];
      if (target.content != restoration.content ||
          target.swipeId != restoration.swipeId ||
          target.agentSwipeId != restoration.agentSwipeId) {
        return null;
      }
      final updatedMessages = [...latest.messages];
      updatedMessages[latestIdx] = withPartial(target);
      return latest.copyWith(messages: updatedMessages);
    });
  }
}

/// See [AbortPlanner.plan].
class AbortPlan {
  const AbortPlan(this.optimistic, this.persist);

  final ChatSession optimistic;
  final Future<ChatSession?> Function() persist;
}
