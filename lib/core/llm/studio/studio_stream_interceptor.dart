import '../../models/chat_message.dart';
import '../studio_stage_brief.dart';
import '../../models/agent_operation_record.dart';
import '../history_assembler.dart';
import '../../models/studio_config.dart';
import 'studio_history_limiter.dart';

/// Pure static helpers for Studio stream interception.
///
/// Extracted from `StreamGenerationService` — all methods are pure
/// (no `Ref`, no side effects) and can be called from any context.
class StudioStreamInterceptor {
  StudioStreamInterceptor._();

  /// Compute the set of visible message IDs that form the Studio final
  /// generator's stable source window. When a persisted boundary exists, only
  /// messages from that boundary onward are visible. Without one, the full
  /// non-hidden history remains visible until a completed assistant turn can
  /// rotate the window safely.
  ///
  /// This mirrors [StudioHistoryLimiter.limitFinalHistory] so that memory
  /// source-window exclusion stays in sync with what the final generator
  /// actually sees.
  static Set<String> computeStudioFinalVisibleMessageIds(
    List<ChatMessage> history,
    int finalContextSize, {
    int reasoningHistoryCount = 0,
    bool excludeReasoningFromContextBudget = false,
    String? historyWindowStartMessageId,
  }) {
    final limited = StudioHistoryLimiter.limitFinalHistory(
      _asPromptHistory(history),
      StudioPreset(
        id: 'visible-window',
        maxFinalHistoryMessages: finalContextSize,
      ),
      reasoningHistoryCount: reasoningHistoryCount,
      excludeReasoningFromContextBudget: excludeReasoningFromContextBudget,
      historyWindowStartMessageId: historyWindowStartMessageId,
    );
    return limited
        .map((message) => message.sourceMessageId)
        .whereType<String>()
        .toSet();
  }

  /// Plans a boundary advance after an assistant reply has been committed.
  static StudioHistoryWindowPlan planCompletedHistoryWindow(
    List<ChatMessage> history, {
    required int finalContextSize,
    String? historyWindowStartMessageId,
    int reasoningHistoryCount = 0,
    bool excludeReasoningFromContextBudget = false,
  }) {
    final promptHistory = _asPromptHistory(history);
    final currentStart = promptHistory.indexWhere(
      (message) => message.sourceMessageId == historyWindowStartMessageId,
    );
    final currentWindow = currentStart >= 0
        ? promptHistory.sublist(currentStart)
        : promptHistory;
    return StudioHistoryLimiter.planCompletedWindow(
      currentWindow,
      maxMessages: finalContextSize,
      reasoningHistoryCount: reasoningHistoryCount,
      excludeReasoningFromContextBudget: excludeReasoningFromContextBudget,
    );
  }

  /// Uses the tracker limiter exactly, including its 1..200 count clamp.
  static Set<String> computeStudioVisibleMessageIds(
    List<ChatMessage> history,
    int contextSize,
  ) {
    final limited = StudioHistoryLimiter.limitTrackerHistory(
      _asPromptHistory(history),
      contextSize,
    );
    return limited
        .map((message) => message.sourceMessageId)
        .whereType<String>()
        .toSet();
  }

  static List<PromptMessage> _asPromptHistory(List<ChatMessage> history) =>
      history
          .where((message) => !message.isHidden && !message.isTyping)
          .map(
            (message) => PromptMessage(
              role: message.role,
              content: message.content,
              reasoningContent: message.reasoning,
              sourceMessageId: message.id,
              imagePath: message.imageHidden ? null : message.imagePath,
            ),
          )
          .toList(growable: false);

  /// Convert Studio stage briefs into the compact JSON format stored on
  /// `ChatMessage.studioOutputs` / `AgentSwipe.studioOutputs` and read by the
  /// UI (Agentic Ops panel). Format: `{'id','name','content'}` per brief.
  static List<Map<String, dynamic>> studioOutputsToJson(
    List<StudioStageBrief> briefs,
  ) {
    return briefs
        .map((b) => {'id': b.agentId, 'name': b.agentName, 'content': b.brief})
        .toList(growable: false);
  }

  /// Maps a Studio pipeline status string to an [AgentOperationStatus].
  static AgentOperationStatus studioStatusToOp(String status) {
    return switch (status) {
      'ok' => AgentOperationStatus.ok,
      'disabled' => AgentOperationStatus.disabled,
      'aborted' => AgentOperationStatus.aborted,
      'timeout' => AgentOperationStatus.timeout,
      'error' => AgentOperationStatus.error,
      'agent_errors' => AgentOperationStatus.error,
      _ => AgentOperationStatus.error,
    };
  }
}
