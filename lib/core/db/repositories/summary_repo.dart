import 'package:drift/drift.dart';

import '../app_db.dart';
import '../tables.dart';
import '../../models/chat_message.dart' hide ChatSummary;
import '../../models/summary_block.dart';
import '../../utils/time_helpers.dart';

part 'summary_repo.g.dart';

@DriftAccessor(tables: [ChatSummaries])
class SummaryRepo extends DatabaseAccessor<AppDatabase>
    with _$SummaryRepoMixin {
  SummaryRepo(super.db);

  Future<ChatSummary?> get(String sessionId) {
    return (select(
      chatSummaries,
    )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
  }

  Future<List<String>> getAllSessionIds() async {
    final rows = await select(chatSummaries).get();
    return rows.map((r) => r.sessionId).toList();
  }

  Future<List<ChatSummary>> getAll() => select(chatSummaries).get();

  Future<void> put({
    required String sessionId,
    required String content,
    required int messageCount,
    bool? enabled,
    String? prompt,
  }) async {
    final existing = await get(sessionId);
    await into(chatSummaries).insertOnConflictUpdate(
      ChatSummariesCompanion.insert(
        sessionId: sessionId,
        content: content,
        enabled: Value(enabled ?? existing?.enabled ?? true),
        messageCount: Value(messageCount),
        prompt: Value(prompt ?? existing?.prompt),
        updatedAt: Value(currentTimestampSeconds()),
        blocksJson: Value(existing?.blocksJson),
      ),
    );
  }

  /// Writes the block chain and the text rendered from it, leaving the
  /// switch and the template alone.
  Future<void> putBlocks({
    required String sessionId,
    required String blocksJson,
    required String content,
    required int messageCount,
  }) async {
    final existing = await get(sessionId);
    await into(chatSummaries).insertOnConflictUpdate(
      ChatSummariesCompanion.insert(
        sessionId: sessionId,
        content: content,
        enabled: Value(existing?.enabled ?? true),
        messageCount: Value(messageCount),
        prompt: Value(existing?.prompt),
        updatedAt: Value(currentTimestampSeconds()),
        blocksJson: Value(blocksJson),
      ),
    );
  }

  /// Atomically rewrites the block chain from the row as stored now.
  /// [mutate] gets that row (null when there is none) and returns the new
  /// chain and the text rendered from it, or null to write nothing — two
  /// writers can no longer lose each other's change. Returns whether it wrote.
  Future<bool> mutateBlocks({
    required String sessionId,
    required int messageCount,
    required ({String blocksJson, String content})? Function(ChatSummary? row)
    mutate,
  }) => transaction(() async {
    final existing = await get(sessionId);
    final next = mutate(existing);
    if (next == null) return false;
    await into(chatSummaries).insertOnConflictUpdate(
      ChatSummariesCompanion.insert(
        sessionId: sessionId,
        content: next.content,
        enabled: Value(existing?.enabled ?? true),
        messageCount: Value(messageCount),
        prompt: Value(existing?.prompt),
        updatedAt: Value(currentTimestampSeconds()),
        blocksJson: Value(next.blocksJson),
      ),
    );
    return true;
  });

  Future<void> putSynced({
    required String sessionId,
    required String content,
    required int messageCount,
    required bool enabled,
    required String? prompt,
    required int updatedAt,
    String? blocksJson,
  }) async {
    await into(chatSummaries).insertOnConflictUpdate(
      ChatSummariesCompanion.insert(
        sessionId: sessionId,
        content: content,
        enabled: Value(enabled),
        messageCount: Value(messageCount),
        prompt: Value(prompt),
        updatedAt: Value(updatedAt),
        blocksJson: Value(blocksJson),
      ),
    );
  }

  /// Writes only the summarization template, leaving the content and the
  /// message count alone. A settings screen that edits the prompt must not
  /// stamp a new message count — that silently restarts the auto-summary
  /// countdown.
  Future<void> setPrompt({
    required String sessionId,
    required String? prompt,
  }) async {
    final existing = await get(sessionId);
    await into(chatSummaries).insertOnConflictUpdate(
      ChatSummariesCompanion.insert(
        sessionId: sessionId,
        content: existing?.content ?? '',
        enabled: Value(existing?.enabled ?? true),
        messageCount: Value(existing?.messageCount ?? 0),
        prompt: Value(prompt),
        updatedAt: Value(currentTimestampSeconds()),
        blocksJson: Value(existing?.blocksJson),
      ),
    );
  }

  Future<void> setEnabled({
    required String sessionId,
    required bool enabled,
  }) async {
    final existing = await get(sessionId);
    await into(chatSummaries).insertOnConflictUpdate(
      ChatSummariesCompanion.insert(
        sessionId: sessionId,
        content: existing?.content ?? '',
        enabled: Value(enabled),
        messageCount: Value(existing?.messageCount ?? 0),
        prompt: Value(existing?.prompt),
        updatedAt: Value(currentTimestampSeconds()),
        blocksJson: Value(existing?.blocksJson),
      ),
    );
  }

  Future<void> deleteBySessionId(String sessionId) {
    return (delete(
      chatSummaries,
    )..where((t) => t.sessionId.equals(sessionId))).go().then((_) {});
  }

  /// Carries the summary over to a branch: the user settings, and the
  /// blocks whose source messages the branch keeps ([SummaryChain.forBranch]).
  /// A summary from before blocks existed records no sources, so nothing
  /// says it stops at the branch point; only its settings carry over.
  Future<void> copyForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
    required List<ChatMessage> messages,
  }) async {
    final source = await get(fromSessionId);
    if (source == null) return;
    final blocks = source.blocksJson == null
        ? const <SummaryBlock>[]
        : SummaryChain.forBranch(SummaryBlock.decodeList(source.blocksJson), {
            for (final message in messages) message.id,
          });
    final carried = blocks.isNotEmpty;
    await into(chatSummaries).insertOnConflictUpdate(
      ChatSummariesCompanion.insert(
        sessionId: toSessionId,
        content: carried
            ? SummaryChain.render(SummaryChain.inPrompt(blocks, messages))
            : '',
        enabled: Value(source.enabled),
        messageCount: Value(carried ? messages.length : 0),
        prompt: Value(source.prompt),
        updatedAt: Value(currentTimestampSeconds()),
        blocksJson: Value(carried ? SummaryBlock.encodeList(blocks) : null),
      ),
    );
  }
}
