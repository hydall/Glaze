import '../../../core/models/agent_operation_record.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/llm/prompt_builder.dart' show PromptPayload;

/// Extracts recent conversation as plain text for auxiliary prompt analysis.
/// Format: "Role: content" per line, last [maxMessages] messages.
/// Skips error, typing, and empty-content messages.
///
/// Used by Studio Ledger to build its bounded recent-history context.
String extractRecentHistoryText(
  List<ChatMessage> messages, {
  int maxMessages = 10,

  /// If non-null, only messages up to AND INCLUDING the one with this id
  /// are considered. Messages after it are dropped.
  String? upToMessageId,
}) {
  // Truncate to the historical slice first if requested.
  List<ChatMessage> source = messages;
  if (upToMessageId != null) {
    final idx = messages.indexWhere((m) => m.id == upToMessageId);
    if (idx >= 0) {
      source = messages.sublist(0, idx + 1);
    }
  }
  final start = source.length > maxMessages ? source.length - maxMessages : 0;
  final recent = source.sublist(start);
  final lines = <String>[];
  for (final msg in recent) {
    if (msg.isError || msg.isTyping) continue;
    final role = msg.role == 'assistant' ? 'Assistant' : 'User';
    final content = msg.content.trim();
    if (content.isEmpty) continue;
    lines.add('$role: $content');
  }
  return lines.join('\n\n');
}

/// Selects the text the Studio Ledger should analyse after the cleaner has
/// run (or skipped/failed). Extracted as a top-level function so it can be
/// tested in isolation.
///
/// 1. wasCleaned → cleanedText is the new canon.
/// 2. skipped → assistantText (original preserved, cleaned rejected).
/// 3. partial → streamedPartialText (persisted as partial swipe).
/// 4. error/nothing → assistantText (original unchanged in DB).
String selectStudioLedgerTextAfterCleaner({
  required String cleanerStatus,
  required bool wasCleaned,
  required String cleanedText,
  required String assistantText,
  required String streamedPartialText,
}) {
  if (wasCleaned) return cleanedText;
  if (cleanerStatus == 'skipped') return assistantText;
  final partial = streamedPartialText.trim();
  if (partial.isNotEmpty) return streamedPartialText;
  return assistantText;
}

/// Maps a [PostCleanerResult] status string to the operations-log enum.
AgentOperationStatus cleanerStatusToOp(String status) {
  return switch (status) {
    'ok' => AgentOperationStatus.ok,
    'skipped' => AgentOperationStatus.invalidOutput,
    'disabled' => AgentOperationStatus.disabled,
    'aborted' => AgentOperationStatus.aborted,
    'timeout' => AgentOperationStatus.timeout,
    'error' => AgentOperationStatus.error,
    _ => AgentOperationStatus.error,
  };
}

AgentOperationStatus ledgerStatusToOp(String status) {
  return switch (status) {
    'ok' => AgentOperationStatus.ok,
    'skipped' => AgentOperationStatus.disabled,
    'disabled' => AgentOperationStatus.disabled,
    'aborted' => AgentOperationStatus.aborted,
    'timeout' => AgentOperationStatus.timeout,
    'error' => AgentOperationStatus.error,
    _ => AgentOperationStatus.error,
  };
}

/// Assembles a plain-text lorebook context snapshot from the [PromptPayload]
/// for the auditor. Combines vector entries (already retrieved, with content)
/// and pre-scanned keyword entries (if available). This is a simpler assembly
/// than the full prompt builder's `_classifyLorebooks` — the auditor only needs
/// the facts, not the precise positioning/formatting.
String? assembleLorebooksContent(PromptPayload payload) {
  final blocks = <String>[];

  // Pre-scanned keyword entries (from buildFromSession path).
  final preScanned = payload.preScannedEntries;
  if (preScanned != null) {
    for (final e in preScanned) {
      final content = e.content.trim();
      if (content.isEmpty) continue;
      final name = e.comment.isNotEmpty ? e.comment : e.id;
      blocks.add('[${e.lorebookName}] $name:\n$content');
    }
  }

  // Vector entries (from buildFromPreFetched / deep mode).
  for (final e in payload.vectorEntries) {
    final content = e.content.trim();
    if (content.isEmpty) continue;
    final name = e.comment.isNotEmpty ? e.comment : e.id;
    blocks.add('[vector] $name:\n$content');
  }

  if (blocks.isEmpty) return null;
  return blocks.join('\n\n');
}
