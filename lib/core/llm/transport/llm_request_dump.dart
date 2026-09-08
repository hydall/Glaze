import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'chat_transport.dart';
import 'chat_transport_request.dart';

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
  static int _seq = 0;

  /// Serializes writes so concurrent calls don't interleave/corrupt lines.
  static Future<void> _chain = Future<void>.value();

  /// Records a single outgoing request. Best-effort: never throws, never
  /// blocks the caller (fire-and-forget chained write).
  static void record(ChatTransportRequest r, {String? label}) {
    if (!enabled) return;

    final entry = <String, dynamic>{
      'seq': _seq++,
      'ts': DateTime.now().toIso8601String(),
      'label': ?label,
      'protocolEndpoint': r.endpoint,
      'model': r.model,
      'stream': r.stream,
      'maxTokens': r.maxTokens,
      'temperature': r.omitTemperature ? null : r.temperature,
      'topP': r.omitTopP ? null : r.topP,
      'topK': r.topK,
      'frequencyPenalty': r.frequencyPenalty,
      'presencePenalty': r.presencePenalty,
      'requestReasoning': r.requestReasoning,
      'useResponsesApi': r.useResponsesApi,
      'omitReasoning': r.omitReasoning,
      'reasoningEffort': r.omitReasoningEffort ? null : r.reasoningEffort,
      'showNativeReasoning': r.showNativeReasoning,
      'omitTopK': r.omitTopK,
      'omitFrequencyPenalty': r.omitFrequencyPenalty,
      'omitPresencePenalty': r.omitPresencePenalty,
      'sessionId': r.sessionId,
      'cacheControlTtl': r.cacheControlTtl,
      'cacheBreakpointMode': r.cacheBreakpointMode,
      'sessionIdMode': r.sessionIdMode,
      'messageCount': r.messages.length,
      'messages': r.messages,
      if (r.tools != null) 'toolCount': r.tools!.length,
      if (r.toolChoice != null) 'toolChoice': r.toolChoice,
    };

    String line;
    try {
      line = jsonEncode(entry);
    } catch (e) {
      // Some message content may be non-encodable (e.g. exotic multimodal
      // parts). Fall back to a stringified shape so we still capture it.
      line = jsonEncode(<String, dynamic>{
        'seq': entry['seq'],
        'ts': entry['ts'],
        'label': ?label,
        'model': r.model,
        'encodeError': e.toString(),
        'messages': r.messages.map((m) => m.toString()).toList(),
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

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) {
    LlmRequestDump.record(request, label: label);
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
