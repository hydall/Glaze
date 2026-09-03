import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../llm/transport/llm_request_capture.dart';
import '../../llm/transport/llm_call_event.dart';
import '../app_db.dart';

final class ExactLlmPromptCapture {
  const ExactLlmPromptCapture({required this.row, required this.prompt});

  final LlmRequestCaptureRow row;
  final String prompt;
}

/// Local bounded persistence sink for sanitized transport request captures.
final class LlmRequestCaptureRepo
    implements LlmRequestCaptureSink, LlmCallEventSink {
  LlmRequestCaptureRepo(this.db);

  final AppDatabase db;

  // Captures are trimmed by two budgets at once: a row ceiling and a byte
  // budget, whichever bites first.
  //
  // Rows alone were the wrong unit. A cleaner request is a couple of KB while a
  // main-model request can be a megabyte, so "keep the newest 50" meant either
  // holding ~50 MB of prompts or — on an agentic preset, where one turn is 5-10
  // requests — keeping barely five turns of history. Bytes make the two cases
  // behave: many small requests survive, a handful of huge ones do not squat on
  // the whole allowance.
  //
  // [minRowsPerSession] is the floor the byte budget may not cross, so a single
  // oversized request can never empty the list.
  static const int maxRowsPerSession = 200;
  static const int maxBytesPerSession = 6 * 1024 * 1024;
  static const int minRowsPerSession = 8;
  static const int maxRowsWithoutSession = 100;
  static const int maxRowsTotal = 2000;
  static const int maxBytesTotal = 24 * 1024 * 1024;
  static const int maxEventBytes = 1024 * 1024;

  Future<void> _chain = Future<void>.value();
  bool _closed = false;

  @override
  Future<void> record(LlmRequestCaptureEvent event) {
    if (_closed) return Future<void>.value();
    final write = _chain.then((_) => _record(event));
    _chain = write.catchError((Object error) {
      debugPrint('[LlmRequestCapture] persistence failed: $error');
    });
    return _chain;
  }

  @override
  Future<void> recordCallEvent(LlmCallEvent event) {
    if (_closed) return Future<void>.value();
    final write = _chain.then((_) => _recordCallEvent(event));
    _chain = write.catchError((Object error) {
      debugPrint('[LlmCallEventCapture] persistence failed: $error');
    });
    return _chain;
  }

  Future<void> close() async {
    _closed = true;
    await _chain;
  }

  Future<List<LlmRequestCaptureRow>> newestForSession(
    String sessionId, {
    String? stage,
    int limit = 50,
  }) {
    final query = db.select(db.llmRequestCaptureRows)
      ..where(
        (row) =>
            row.sessionId.equals(sessionId) &
            (stage == null ? const Constant(true) : row.stage.equals(stage)),
      )
      ..orderBy([
        (row) => OrderingTerm.desc(row.createdAtMs),
        (row) => OrderingTerm.desc(row.id),
      ])
      ..limit(limit);
    return query.get();
  }

  Future<List<LlmRequestCaptureRow>> newestWithoutSession({int limit = 50}) {
    final query = db.select(db.llmRequestCaptureRows)
      ..where((row) => row.sessionId.isNull())
      ..orderBy([
        (row) => OrderingTerm.desc(row.createdAtMs),
        (row) => OrderingTerm.desc(row.id),
      ])
      ..limit(limit);
    return query.get();
  }

  /// Stamps [messageId] over the generation-phase rows of one turn.
  ///
  /// The main request and the Studio agent shards are sent before the reply
  /// exists, so they are captured with a turn id and no message id. Once the
  /// assistant message is written, this binds them to it — that is what lets a
  /// diagnostics view group a turn without guessing from timestamps.
  ///
  /// Deliberately narrow: only rows of this session, only the stages that run
  /// inside a generation (the model itself, the agent shards, and the vector
  /// searches that build its prompt), only ones still unbound, and only from
  /// [sinceMs] on. A background job (card rewriter, reconciliation) running in
  /// the same window keeps its own identity.
  Future<void> bindTurnMessageId({
    required String sessionId,
    required String messageId,
    required int sinceMs,
  }) async {
    try {
      final update = db.update(db.llmRequestCaptureRows)
        ..where(
          (row) =>
              row.sessionId.equals(sessionId) &
              row.messageId.isNull() &
              row.createdAtMs.isBiggerOrEqualValue(sinceMs) &
              (row.stage.equals('main') |
                  row.stage.like('studio.%') |
                  row.stage.like('embedding.%')),
        );
      await update.write(
        LlmRequestCaptureRowsCompanion(messageId: Value(messageId)),
      );
    } catch (error) {
      debugPrint('[LlmRequestCapture] turn binding failed: $error');
    }
  }

  Future<ExactLlmPromptCapture?> exactPromptForCall({
    required String callId,
    required String sessionId,
    required String pipelineRunId,
    required String stage,
  }) async {
    final row =
        await (db.select(db.llmRequestCaptureRows)
              ..where((item) => item.callId.equals(callId))
              ..where((item) => item.sessionId.equals(sessionId))
              ..where((item) => item.pipelineRunId.equals(pipelineRunId))
              ..where((item) => item.stage.equals(stage))
              ..orderBy([
                (item) => OrderingTerm.desc(item.attempt),
                (item) => OrderingTerm.desc(item.createdAtMs),
                (item) => OrderingTerm.desc(item.id),
              ])
              ..limit(1))
            .getSingleOrNull();
    if (row == null || row.truncated) return null;
    try {
      final event = jsonDecode(row.eventJson);
      if (event is! Map || event['messages'] is! List) return null;
      final messages = event['messages'] as List;
      if (messages.length != 1 || messages.single is! Map) return null;
      final message = messages.single as Map;
      if (message['role'] != 'user' || message['content'] is! String) {
        return null;
      }
      return ExactLlmPromptCapture(
        row: row,
        prompt: message['content'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteBySessionId(String sessionId) => db.transaction(() async {
    await (db.delete(
      db.llmCallEventRows,
    )..where((row) => row.sessionId.equals(sessionId))).go();
    await (db.delete(
      db.llmRequestCaptureRows,
    )..where((row) => row.sessionId.equals(sessionId))).go();
  });

  Future<List<LlmCallEventRow>> newestCallEventsForSession(
    String sessionId, {
    int limit = 200,
  }) {
    final query = db.select(db.llmCallEventRows)
      ..where((row) => row.sessionId.equals(sessionId))
      ..orderBy([
        (row) => OrderingTerm.desc(row.createdAtMs),
        (row) => OrderingTerm.desc(row.id),
      ])
      ..limit(limit);
    return query.get();
  }

  Future<List<LlmCallEventRow>> callEvents(String callId) {
    final query = db.select(db.llmCallEventRows)
      ..where((row) => row.callId.equals(callId))
      ..orderBy([
        (row) => OrderingTerm.asc(row.createdAtMs),
        (row) => OrderingTerm.asc(row.id),
      ]);
    return query.get();
  }

  Future<List<LlmCallEventRow>> callEventsForArtifact(
    String sessionId,
    String relatedArtifactId,
  ) {
    final query = db.select(db.llmCallEventRows)
      ..where(
        (row) =>
            row.sessionId.equals(sessionId) &
            row.relatedArtifactId.equals(relatedArtifactId),
      )
      ..orderBy([
        (row) => OrderingTerm.asc(row.createdAtMs),
        (row) => OrderingTerm.asc(row.id),
      ]);
    return query.get();
  }

  Future<void> _record(LlmRequestCaptureEvent event) async {
    try {
      final encoded = _encodeBounded(event);
      final context = event.context;
      await db.transaction(() async {
        await db
            .into(db.llmRequestCaptureRows)
            .insert(
              LlmRequestCaptureRowsCompanion.insert(
                sequence: event.sequence,
                createdAtMs: event.createdAt.millisecondsSinceEpoch,
                sessionId: Value(context?.sessionId),
                stage: Value(context?.stage),
                messageId: Value(context?.messageId),
                pipelineRunId: Value(context?.pipelineRunId),
                callId: Value(context?.callId),
                logicalCallId: Value(context?.logicalCallId),
                relatedArtifactId: Value(context?.relatedArtifactId),
                agentId: Value(context?.agentId),
                stageOrdinal: Value(context?.stageOrdinal),
                attempt: Value(context?.attempt),
                protocol: Value(event.protocol),
                truncated: event.truncated || encoded.storageTruncated,
                eventJson: encoded.json,
              ),
            );
        await _trimContext(context?.sessionId);
        await _trimGlobal();
      });
    } catch (error) {
      debugPrint('[LlmRequestCapture] persistence failed: $error');
    }
  }

  Future<void> _recordCallEvent(LlmCallEvent event) async {
    try {
      final context = event.context;
      final pipelineRunId = context.pipelineRunId;
      final callId = context.callId;
      if (pipelineRunId == null || callId == null) return;
      await db
          .into(db.llmCallEventRows)
          .insert(
            LlmCallEventRowsCompanion.insert(
              id: event.id,
              createdAtMs: event.createdAt.millisecondsSinceEpoch,
              sessionId: Value(context.sessionId),
              pipelineRunId: pipelineRunId,
              callId: callId,
              parentCallId: Value(context.parentCallId),
              stage: context.stage,
              stageOrdinal: Value(context.stageOrdinal),
              attempt: Value(context.attempt),
              relatedArtifactId: Value(context.relatedArtifactId),
              kind: event.kind,
              status: Value(event.status),
              statusCode: Value(event.statusCode),
              responseText: Value(event.responseText),
              responseHash: Value(event.responseHash),
              error: Value(event.error),
              parserName: Value(event.parserName),
              parserCode: Value(event.parserCode),
              parserDetail: Value(event.parserDetail),
              payloadJson: Value(jsonEncode(event.payload)),
              truncated: Value(event.truncated),
            ),
          );
    } catch (error) {
      debugPrint('[LlmCallEventCapture] persistence failed: $error');
    }
  }

  Future<void> _trimContext(String? sessionId) async {
    final predicate = sessionId == null
        ? 'session_id IS NULL'
        : 'session_id = ?';
    final args = sessionId == null ? <Object?>[] : <Object?>[sessionId];
    final rowCeiling = sessionId == null
        ? maxRowsWithoutSession
        : maxRowsPerSession;
    await _trimTo(
      predicate: predicate,
      args: args,
      rowCeiling: rowCeiling,
      byteBudget: maxBytesPerSession,
      minRows: minRowsPerSession,
    );
  }

  Future<void> _trimGlobal() => _trimTo(
    predicate: '1 = 1',
    args: const [],
    rowCeiling: maxRowsTotal,
    byteBudget: maxBytesTotal,
    minRows: minRowsPerSession,
  );

  /// Deletes everything past *either* budget, newest first.
  ///
  /// The window walks the rows from newest to oldest keeping a running byte
  /// total (`LENGTH(CAST(... AS BLOB))` is bytes; bare `LENGTH` on TEXT counts
  /// characters and would under-count every non-ASCII prompt). A row is dropped
  /// when it is past the row ceiling, or when it is past [minRows] *and* the
  /// running total has already exceeded the byte budget.
  Future<void> _trimTo({
    required String predicate,
    required List<Object?> args,
    required int rowCeiling,
    required int byteBudget,
    required int minRows,
  }) => db.customStatement(
    'DELETE FROM llm_request_capture_rows WHERE id IN ('
    'SELECT id FROM ('
    'SELECT id, '
    'ROW_NUMBER() OVER w AS rn, '
    'SUM(LENGTH(CAST(event_json AS BLOB))) OVER w AS running_bytes '
    'FROM llm_request_capture_rows WHERE $predicate '
    'WINDOW w AS (ORDER BY created_at_ms DESC, id DESC '
    'ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)'
    ') WHERE rn > ? OR (rn > ? AND running_bytes > ?)'
    ')',
    [...args, rowCeiling, minRows, byteBudget],
  );

  static _EncodedCapture _encodeBounded(LlmRequestCaptureEvent event) {
    final json = jsonEncode(event.toJson());
    final bytes = utf8.encode(json);
    if (bytes.length <= maxEventBytes) {
      return _EncodedCapture(json: json, storageTruncated: false);
    }
    return _EncodedCapture(
      json: jsonEncode({
        'seq': event.sequence,
        'ts': event.createdAt.toIso8601String(),
        if (event.protocol != null) 'protocol': event.protocol,
        if (event.context != null) 'context': event.context!.toJson(),
        'truncated': true,
        'storageTruncated': true,
        'originalBytes': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      }),
      storageTruncated: true,
    );
  }
}

final class _EncodedCapture {
  const _EncodedCapture({required this.json, required this.storageTruncated});

  final String json;
  final bool storageTruncated;
}
