import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'chat_transport.dart';
import 'chat_transport_request.dart';
import 'llm_request_capture.dart';

/// Debug-only dump of every outgoing LLM request payload.
///
/// Writes one JSON object per line (JSONL) to a temp file so all LLM calls
/// made while answering a single chat turn — studio shards, the main model,
/// the post-cleaner factchecker + cleaner passes, and the agentic-memory
/// writer — can be inspected after the fact.
///
/// Toggle with [enabled]. When off, [LoggingChatTransport] delegates with zero
/// overhead. This is a diagnostics aid, NOT a production logging facility:
/// the dump contains full prompts and is overwritten on app start.
class LlmRequestDump {
  LlmRequestDump._();

  /// Master switch. Flip to `true` to enable dumping for diagnostics.
  static bool enabled = false;

  /// Absolute path of the dump file. Defaults to the OS temp dir.
  static String filePath =
      '${Directory.systemTemp.path}${Platform.pathSeparator}glaze_llm_dump.jsonl';

  static bool _truncatedThisSession = false;

  /// Serializes writes so concurrent calls don't interleave/corrupt lines.
  static Future<void> _chain = Future<void>.value();

  /// Records a single outgoing request. Best-effort: never throws, never
  /// blocks the caller (fire-and-forget chained write).
  static void record(LlmRequestCaptureEvent event) {
    if (!enabled) return;

    String line;
    try {
      line = jsonEncode(event.toJson());
    } catch (e) {
      line = jsonEncode(<String, dynamic>{
        'seq': event.sequence,
        'ts': event.createdAt.toIso8601String(),
        'protocol': event.protocol,
        'encodeError': e.toString(),
      });
    }

    _chain = _chain.then((_) => _append(line)).catchError((Object e) {
      debugPrint('[LlmRequestDump] write failed: $e');
    });
  }

  static Future<void> _append(String line) async {
    final file = File(filePath);
    final mode = _truncatedThisSession ? FileMode.append : FileMode.write;
    _truncatedThisSession = true;
    await file.writeAsString('$line\n', mode: mode, flush: true);
  }
}

/// [ChatTransport] decorator that dumps the request payload before delegating.
/// Wraps every transport returned by `pickChatTransport`, so all protocol
/// implementations and all callers are covered by a single hook.
class LoggingChatTransport implements ChatTransport {
  LoggingChatTransport(this._inner, {this.label});

  final ChatTransport _inner;
  final String? label;

  /// The wrapped transport. Exposed so tests can assert factory routing.
  @visibleForTesting
  ChatTransport get inner => _inner;

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) {
    if (LlmRequestDump.enabled || LlmRequestCapture.hasSink) {
      final event = LlmRequestCapture.build(request, protocol: label);
      LlmRequestDump.record(event);
      LlmRequestCapture.dispatch(event);
    }
    return _inner.stream(
      request: request,
      cancelToken: cancelToken,
      onUpdate: onUpdate,
      onComplete: onComplete,
      onError: onError,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) => _inner.fetchModels(endpoint: endpoint, apiKey: apiKey);
}
