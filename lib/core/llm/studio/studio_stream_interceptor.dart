import '../../models/chat_message.dart';
import '../prompt_builder.dart' show PromptPayload;
import '../studio_stage_brief.dart';
import '../../models/agent_operation_record.dart';
import '../tokenizer.dart';

/// Pure static helpers for Studio stream interception.
///
/// Extracted from `StreamGenerationService` — all methods are pure
/// (no `Ref`, no side effects) and can be called from any context.
class StudioStreamInterceptor {
  StudioStreamInterceptor._();

  /// Token budget mirroring [StudioHistoryLimiter.finalHistoryTokenBudget].
  /// The source-window ID set must match the messages that actually reach the
  /// final generator — if token trimming drops messages that the message-count
  /// slice would have kept, memory injection must know about it so it doesn't
  /// suppress entries for messages that are no longer visible.
  static const finalHistoryTokenBudget = 60000;

  /// Compute the set of visible message IDs that form the Studio final
  /// generator's source window. Takes the last [finalContextSize] non-hidden
  /// messages from [history], but also enforces a [finalHistoryTokenBudget]
  /// cap: messages are accumulated from the end until either the count or the
  /// token budget is reached, whichever comes first.
  ///
  /// This mirrors [StudioHistoryLimiter.limitFinalHistory] so that memory
  /// source-window exclusion stays in sync with what the final generator
  /// actually sees.
  static Set<String> computeStudioFinalVisibleMessageIds(
    List<ChatMessage> history,
    int finalContextSize,
  ) {
    if (finalContextSize <= 0) return const <String>{};
    final nonHidden = history.where((m) => !m.isHidden).toList();
    if (nonHidden.isEmpty) return const <String>{};

    final selected = <String>[];
    var totalTokens = 0;
    for (var i = nonHidden.length - 1; i >= 0; i--) {
      final m = nonHidden[i];
      final tokens = estimateTokens(m.content);
      if (selected.isNotEmpty &&
          totalTokens + tokens > finalHistoryTokenBudget) {
        break;
      }
      selected.insert(0, m.id);
      totalTokens += tokens;
      if (selected.length >= finalContextSize) break;
    }
    return selected.toSet();
  }

  /// Clone a [PromptPayload] with a different `sourceWindowVisibleMessageIds`.
  static PromptPayload payloadWithSourceWindow(
    PromptPayload payload,
    Set<String> sourceWindowVisibleMessageIds,
  ) {
    return PromptPayload(
      character: payload.character,
      persona: payload.persona,
      preset: payload.preset,
      history: payload.history,
      sessionId: payload.sessionId,
      apiConfig: payload.apiConfig,
      sessionVars: payload.sessionVars,
      globalVars: payload.globalVars,
      summaryContent: payload.summaryContent,
      summaryPrefix: payload.summaryPrefix,
      memoryContent: payload.memoryContent,
      memoryMacroContent: payload.memoryMacroContent,
      memoryInjectionTarget: payload.memoryInjectionTarget,
      guidanceText: payload.guidanceText,
      lorebooks: payload.lorebooks,
      lorebookSettings: payload.lorebookSettings,
      lorebookActivations: payload.lorebookActivations,
      vectorEntries: payload.vectorEntries,
      authorsNote: payload.authorsNote,
      characterDepthPrompt: payload.characterDepthPrompt,
      characterDepthPromptDepth: payload.characterDepthPromptDepth,
      characterDepthPromptRole: payload.characterDepthPromptRole,
      memoryCoverage: payload.memoryCoverage,
      globalRegexes: payload.globalRegexes,
      preScannedEntries: payload.preScannedEntries,
      triggeredMemories: payload.triggeredMemories,
      runtimePromptBlocks: payload.runtimePromptBlocks,
      memorySelection: payload.memorySelection,
      memoryExcerptingEnabled: payload.memoryExcerptingEnabled,
      memoryPackingMode: payload.memoryPackingMode,
      memoryExcerptTokensPerChunk: payload.memoryExcerptTokensPerChunk,
      memoryExcerptChunksPerEntry: payload.memoryExcerptChunksPerEntry,
      chunkFirstTopEntries: payload.chunkFirstTopEntries,
      chunkFirstTopChunks: payload.chunkFirstTopChunks,
      arcContent: payload.arcContent,
      entitiesContent: payload.entitiesContent,
      studioSessionStateContent: payload.studioSessionStateContent,
      characterKnowledgeContent: payload.characterKnowledgeContent,
      recalledMessagesContent: payload.recalledMessagesContent,
      recalledMessageChunks: payload.recalledMessageChunks,
      disableSourceWindowExclusion: payload.disableSourceWindowExclusion,
      sourceWindowVisibleMessageIds: sourceWindowVisibleMessageIds,
      memoryInjectionFingerprint: payload.memoryInjectionFingerprint,
    );
  }

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
