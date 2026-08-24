import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../llm/transport/llm_request_capture.dart';
import '../app_db.dart';

/// Local bounded persistence sink for sanitized transport request captures.
final class LlmRequestCaptureRepo implements LlmRequestCaptureSink {
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

  Future<void> deleteBySessionId(String sessionId) => (db.delete(
    db.llmRequestCaptureRows,
  )..where((row) => row.sessionId.equals(sessionId))).go();

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
