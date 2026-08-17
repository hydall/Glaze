import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../models/agent_operation_record.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import '../app_db.dart';

/// Which Ledger entry point produced a diagnostic row.
enum LedgerDebugRunKind {
  /// Per-turn Studio Ledger run over the final assistant message.
  normal,

  /// Range reconciliation run over accepted chunks.
  reconciliation,
}

/// One recorded Studio Ledger model exchange.
///
/// Rows are written even when the run succeeds, because the interesting
/// question is usually "why did this turn need two model calls" rather than
/// "did it ultimately apply ops".
class LedgerDebugRun {
  const LedgerDebugRun({
    required this.sessionId,
    required this.kind,
    required this.status,
    this.messageId = '',
    this.swipeId = 0,
    this.agentSwipeId = 0,
    this.model = '',
    this.parseFailure = 'none',
    this.rejectionReason,
    this.rejectedOps = const [],
    this.repairAttempted = false,
    this.repairFailure,
    this.responseText,
    this.repairResponseText,
    this.attempts = const [],
    this.error,
    this.opsApplied = 0,
    this.elapsedMs = 0,
    this.promptChars = 0,
    this.responseChars = 0,
  });

  final String sessionId;
  final LedgerDebugRunKind kind;
  final String status;
  final String messageId;
  final int swipeId;
  final int agentSwipeId;
  final String model;
  final String parseFailure;
  final String? rejectionReason;
  final List<String> rejectedOps;
  final bool repairAttempted;
  final String? repairFailure;
  final String? responseText;
  final String? repairResponseText;
  final List<AgentOperationAttempt> attempts;
  final String? error;
  final int opsApplied;
  final int elapsedMs;
  final int promptChars;
  final int responseChars;
}

/// Bounded journal of Studio Ledger model exchanges.
///
/// Diagnostics must never be able to break or slow a Ledger turn, so every
/// write is best-effort: failures are logged and swallowed, stored text is
/// truncated, and old rows are trimmed as new ones arrive.
class LedgerDebugRunRepo {
  const LedgerDebugRunRepo(this.db);

  final AppDatabase db;

  /// Retained rows per session. Enough to cover a debugging session without
  /// letting a long chat accumulate megabytes of raw model output.
  static const int maxRunsPerSession = 50;

  /// Upper bound for each stored response payload.
  static const int maxStoredTextChars = 200000;

  /// Records [run], trimming the session's journal to [maxRunsPerSession].
  ///
  /// Never throws: a diagnostic failure must not surface as a Ledger failure.
  Future<void> record(LedgerDebugRun run) async {
    if (run.sessionId.isEmpty || run.status.isEmpty) return;
    try {
      await db.transaction(() async {
        await db
            .into(db.ledgerDebugRuns)
            .insert(
              LedgerDebugRunsCompanion.insert(
                id: 'ledger-debug-${generateId()}',
                sessionId: run.sessionId,
                kind: run.kind.name,
                status: run.status,
                messageId: Value(run.messageId),
                swipeId: Value(run.swipeId),
                agentSwipeId: Value(run.agentSwipeId),
                model: Value(run.model),
                parseFailure: Value(run.parseFailure),
                rejectionReason: Value(_bounded(run.rejectionReason)),
                rejectedOpsJson: Value(
                  jsonEncode([
                    for (final op in run.rejectedOps) _bounded(op) ?? '',
                  ]),
                ),
                repairAttempted: Value(run.repairAttempted),
                repairFailure: Value(run.repairFailure),
                responseText: Value(_bounded(run.responseText)),
                repairResponseText: Value(_bounded(run.repairResponseText)),
                attemptsJson: Value(
                  jsonEncode([
                    for (final attempt in run.attempts) attempt.toJson(),
                  ]),
                ),
                error: Value(_bounded(run.error)),
                opsApplied: Value(run.opsApplied),
                elapsedMs: Value(run.elapsedMs),
                promptChars: Value(run.promptChars),
                responseChars: Value(run.responseChars),
                createdAt: currentTimestampSeconds(),
              ),
            );
        await _trim(run.sessionId);
      });
    } catch (e) {
      debugPrint('[StudioLedger] debug run not recorded: $e');
    }
  }

  /// Most recent rows for [sessionId], newest first.
  Future<List<LedgerDebugRunRow>> recentForSession(
    String sessionId, {
    int limit = 20,
  }) {
    final query = db.select(db.ledgerDebugRuns)
      ..where((table) => table.sessionId.equals(sessionId))
      ..orderBy([
        (table) => OrderingTerm(
          expression: table.createdAt,
          mode: OrderingMode.desc,
        ),
        (table) =>
            OrderingTerm(expression: table.id, mode: OrderingMode.desc),
      ])
      ..limit(limit);
    return query.get();
  }

  Future<void> deleteBySessionId(String sessionId) {
    return (db.delete(
      db.ledgerDebugRuns,
    )..where((table) => table.sessionId.equals(sessionId))).go();
  }

  Future<void> _trim(String sessionId) async {
    await db.customStatement(
      'DELETE FROM ledger_debug_runs WHERE session_id = ? AND id NOT IN ('
      'SELECT id FROM ledger_debug_runs WHERE session_id = ? '
      'ORDER BY created_at DESC, id DESC LIMIT ?)',
      [sessionId, sessionId, maxRunsPerSession],
    );
  }

  static String? _bounded(String? text) {
    if (text == null) return null;
    if (text.length <= maxStoredTextChars) return text;
    return '${text.substring(0, maxStoredTextChars)}…[truncated]';
  }
}
