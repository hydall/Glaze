import 'package:drift/drift.dart';

import '../app_db.dart';
import '../tables.dart';
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

  /// Carries user settings but not the blocks: a branch's messages are its
  /// own, and blocks are bound to the source messages they were written from.
  Future<void> copySettingsForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
  }) async {
    final source = await get(fromSessionId);
    if (source == null) return;
    await into(chatSummaries).insertOnConflictUpdate(
      ChatSummariesCompanion.insert(
        sessionId: toSessionId,
        content: '',
        enabled: Value(source.enabled),
        messageCount: const Value(0),
        prompt: Value(source.prompt),
        updatedAt: Value(currentTimestampSeconds()),
        blocksJson: const Value(null),
      ),
    );
  }
}
