import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../llm/transport/llm_request_capture.dart';
import '../../llm/transport/llm_call_event.dart';
import '../app_db.dart';

/// Local bounded persistence sink for sanitized transport request captures.
final class LlmRequestCaptureRepo
    implements LlmRequestCaptureSink, LlmCallEventSink {
  LlmRequestCaptureRepo(this.db);

  final AppDatabase db;

  static const int maxRowsPerSession = 50;
  static const int maxRowsWithoutSession = 100;
  static const int maxRowsTotal = 1000;
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
    final limit = sessionId == null ? maxRowsWithoutSession : maxRowsPerSession;
    await db.customStatement(
      'DELETE FROM llm_request_capture_rows WHERE $predicate AND id NOT IN ('
      'SELECT id FROM llm_request_capture_rows WHERE $predicate '
      'ORDER BY created_at_ms DESC, id DESC LIMIT ?)',
      [...args, ...args, limit],
    );
  }

  Future<void> _trimGlobal() => db.customStatement(
    'DELETE FROM llm_request_capture_rows WHERE id NOT IN ('
    'SELECT id FROM llm_request_capture_rows '
    'ORDER BY created_at_ms DESC, id DESC LIMIT ?)',
    [maxRowsTotal],
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
