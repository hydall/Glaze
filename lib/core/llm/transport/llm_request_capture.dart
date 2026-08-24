import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'chat_transport_request.dart';
import 'llm_capture_context.dart';

abstract interface class LlmRequestCaptureSink {
  FutureOr<void> record(LlmRequestCaptureEvent event);
}

/// Sanitized, immutable view of the request observed by the transport layer.
final class LlmRequestCaptureEvent {
  const LlmRequestCaptureEvent({
    required this.sequence,
    required this.createdAt,
    required this.protocol,
    required this.context,
    required this.request,
    required this.truncated,
  });

  final int sequence;
  final DateTime createdAt;
  final String? protocol;
  final LlmCaptureContext? context;
  final Map<String, dynamic> request;
  final bool truncated;

  Map<String, dynamic> toJson() => {
    'seq': sequence,
    'ts': createdAt.toIso8601String(),
    if (protocol != null) 'protocol': protocol,
    if (context != null) 'context': context!.toJson(),
    'truncated': truncated,
    ...request,
  };
}

/// Dispatches transport captures without making diagnostics part of request
/// success. A durable sink can be installed by application composition.
class LlmRequestCapture {
  LlmRequestCapture._();

  static LlmRequestCaptureSink? sink;
  static int _sequence = 0;

  static bool get hasSink => sink != null;

  static LlmRequestCaptureEvent build(
    ChatTransportRequest request, {
    String? protocol,
  }) {
    final sanitizer = _CaptureSanitizer();
    return LlmRequestCaptureEvent(
      sequence: _sequence++,
      createdAt: DateTime.now().toUtc(),
      protocol: protocol,
      context: request.captureContext,
      request: {
        'protocolEndpoint': _stripQuery(request.endpoint),
        'model': request.model,
        'stream': request.stream,
        'maxTokens': request.maxTokens,
        'temperature': request.omitTemperature ? null : request.temperature,
        'topP': request.omitTopP ? null : request.topP,
        'topK': request.omitTopK ? null : request.topK,
        'frequencyPenalty': request.omitFrequencyPenalty
            ? null
            : request.frequencyPenalty,
        'presencePenalty': request.omitPresencePenalty
            ? null
            : request.presencePenalty,
        'requestReasoning': request.requestReasoning,
        'useResponsesApi': request.useResponsesApi,
        'omitReasoning': request.omitReasoning,
        'reasoningEffort': request.omitReasoningEffort
            ? null
            : request.reasoningEffort,
        'showNativeReasoning': request.showNativeReasoning,
        'sessionId': request.sessionId,
        'cacheControlTtl': request.cacheControlTtl,
        'cacheBreakpointMode': request.cacheBreakpointMode,
        'sessionIdMode': request.sessionIdMode,
        'messageCount': request.messages.length,
        'messages': sanitizer.sanitize(request.messages),
        if (request.tools != null) 'toolCount': request.tools!.length,
        if (request.toolChoice != null) 'toolChoice': request.toolChoice,
      },
      truncated: sanitizer.truncated,
    );
  }

  static void dispatch(LlmRequestCaptureEvent event) {
    final target = sink;
    if (target == null) return;
    try {
      final result = target.record(event);
      if (result is Future<void>) {
        unawaited(
          result.catchError((Object error) {
            debugPrint('[LlmRequestCapture] sink failed: $error');
          }),
        );
      }
    } catch (error) {
      debugPrint('[LlmRequestCapture] sink failed: $error');
    }
  }

  static String _stripQuery(String endpoint) {
    final queryStart = endpoint.indexOf('?');
    return queryStart < 0 ? endpoint : endpoint.substring(0, queryStart);
  }
}

final class _CaptureSanitizer {
  static const int _maxStringChars = 200000;
  static const int _dataPreviewChars = 96;

  bool truncated = false;

  dynamic sanitize(dynamic value) {
    if (value is String) return _sanitizeString(value);
    if (value is List) return List<dynamic>.unmodifiable(value.map(sanitize));
    if (value is Map) {
      return Map<String, dynamic>.unmodifiable({
        for (final entry in value.entries)
          entry.key.toString(): sanitize(entry.value),
      });
    }
    if (value == null || value is num || value is bool) return value;
    return value.toString();
  }

  dynamic _sanitizeString(String value) {
    if (value.startsWith('data:') && value.length > _dataPreviewChars) {
      truncated = true;
      return <String, dynamic>{
        'kind': 'redacted_data_uri',
        'prefix': value.substring(0, _dataPreviewChars),
        'charCount': value.length,
        'sha256': sha256.convert(utf8.encode(value)).toString(),
      };
    }
    if (value.length <= _maxStringChars) return value;
    truncated = true;
    return <String, dynamic>{
      'kind': 'truncated_text',
      'text': value.substring(0, _maxStringChars),
      'charCount': value.length,
      'sha256': sha256.convert(utf8.encode(value)).toString(),
    };
  }
}
