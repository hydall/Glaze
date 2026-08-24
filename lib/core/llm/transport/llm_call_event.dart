import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../utils/id_generator.dart';
import '../../models/agent_operation_record.dart';
import 'llm_capture_context.dart';

abstract interface class LlmCallEventSink {
  FutureOr<void> recordCallEvent(LlmCallEvent event);
}

/// Immutable orchestration-side event linked to a captured request by
/// `callId + attempt`.
final class LlmCallEvent {
  const LlmCallEvent({
    required this.id,
    required this.createdAt,
    required this.context,
    required this.kind,
    this.status,
    this.statusCode,
    this.responseText,
    this.responseHash,
    this.error,
    this.parserName,
    this.parserCode,
    this.parserDetail,
    this.payload = const {},
    this.truncated = false,
  });

  final String id;
  final DateTime createdAt;
  final LlmCaptureContext context;
  final String kind;
  final String? status;
  final int? statusCode;
  final String? responseText;
  final String? responseHash;
  final String? error;
  final String? parserName;
  final String? parserCode;
  final String? parserDetail;
  final Map<String, dynamic> payload;
  final bool truncated;

  factory LlmCallEvent.transport({
    required LlmCaptureContext context,
    required AgentOperationAttempt attempt,
    String? responseText,
  }) {
    final bounded = _boundedText(responseText);
    final boundedError = _boundedText(attempt.error);
    return LlmCallEvent(
      id: 'llm-event-${generateId()}',
      createdAt: DateTime.now().toUtc(),
      context: context.withAttempt(attempt.attempt),
      kind: attempt.isSuccess ? 'transport_succeeded' : 'transport_failed',
      status: attempt.status,
      statusCode: attempt.statusCode,
      responseText: bounded.text,
      responseHash: responseText == null
          ? null
          : sha256.convert(utf8.encode(responseText)).toString(),
      error: boundedError.text,
      payload: {
        'startedAtMs': attempt.startedAtMs,
        'elapsedMs': attempt.elapsedMs,
      },
      truncated: bounded.truncated || boundedError.truncated,
    );
  }

  factory LlmCallEvent.parserVerdict({
    required LlmCaptureContext context,
    required String parserName,
    required bool accepted,
    required String code,
    String? detail,
    Map<String, dynamic> payload = const {},
  }) {
    final boundedDetail = _boundedText(detail);
    return LlmCallEvent(
      id: 'llm-event-${generateId()}',
      createdAt: DateTime.now().toUtc(),
      context: context,
      kind: accepted ? 'parser_accepted' : 'parser_rejected',
      parserName: parserName,
      parserCode: code,
      parserDetail: boundedDetail.text,
      payload: Map.unmodifiable(payload),
      truncated: boundedDetail.truncated,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'ts': createdAt.toIso8601String(),
    'context': context.toJson(),
    'kind': kind,
    if (status != null) 'status': status,
    if (statusCode != null) 'statusCode': statusCode,
    if (responseText != null) 'responseText': responseText,
    if (responseHash != null) 'responseHash': responseHash,
    if (error != null) 'error': error,
    if (parserName != null) 'parserName': parserName,
    if (parserCode != null) 'parserCode': parserCode,
    if (parserDetail != null) 'parserDetail': parserDetail,
    if (payload.isNotEmpty) 'payload': payload,
    'truncated': truncated,
  };
}

class LlmCallEventCapture {
  LlmCallEventCapture._();

  static LlmCallEventSink? sink;

  static Future<void> record(LlmCallEvent event) async {
    final target = sink;
    if (target == null) return;
    try {
      await target.recordCallEvent(event);
    } catch (error) {
      debugPrint('[LlmCallEventCapture] sink failed: $error');
    }
  }
}

const _maxStoredTextChars = 200000;

({String? text, bool truncated}) _boundedText(String? value) {
  if (value == null || value.length <= _maxStoredTextChars) {
    return (text: value, truncated: false);
  }
  return (text: value.substring(0, _maxStoredTextChars), truncated: true);
}
