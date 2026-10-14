import 'dart:async';
import 'dart:convert';

import '../../../core/llm/transport/llm_call_event.dart';
import '../../../core/llm/transport/llm_capture_context.dart';
import '../../../core/llm/transport/llm_request_capture.dart';
import '../../../core/models/agent_operation_record.dart';

/// Stage of a plugin's HTTP request in the Prompt Inspector: one it sends
/// from its frame (`fetch`, XHR, beacons, sockets) or through
/// `glaze.net.fetch`.
const String kPluginRequestStage = 'plugin.net';

/// Most of a request or response body the inspector keeps, in characters.
const int kPluginRequestTextCap = 200000;

final _secretName = RegExp(
  r'auth|key|token|secret|password|passwd|signature|^sig$|cookie|session',
  caseSensitive: false,
);

/// Starts of requests whose end has not been reported, for the time taken.
final Map<String, int> _startedAt = {};

/// What the inspector shows a plugin's request under: its chat, the plugin
/// and what it called, and an id of the request's own that its outcome is
/// joined to.
LlmCaptureContext pluginRequestContext({
  required String pluginId,
  required String? sessionId,
  required String requestId,
  required String method,
  required Uri? url,
}) {
  final id = 'call:plugin:$pluginId:$requestId';
  final target = url == null
      ? ''
      : ' · $method ${url.host}${url.path == '/' ? '' : url.path}';
  return LlmCaptureContext(
    stage: kPluginRequestStage,
    sessionId: sessionId,
    agentId: '$pluginId$target',
    pipelineRunId: id,
    callId: id,
    attempt: 1,
  );
}

/// Records a plugin's request as it goes out. [headers] are name/value
/// pairs; values of ones that carry credentials are hidden, as are such
/// query parameters. A JSON body with chat messages (or a prompt) shows as
/// those messages, anything else as the body itself.
void recordPluginRequest(
  LlmCaptureContext context, {
  required String method,
  required String url,
  List<List<String>> headers = const [],
  String? body,
  String? via,
}) {
  _startedAt[context.callId!] = DateTime.now().millisecondsSinceEpoch;
  if (_startedAt.length > 500) _startedAt.remove(_startedAt.keys.first);
  final json = _json(body);
  LlmRequestCapture.recordAuxiliary(
    stage: context.stage,
    endpoint: url,
    model: json?['model'] is String ? json!['model'] as String : null,
    context: context,
    messages: _messages(json, body),
    params: {
      'method': method,
      'url': hidePluginUrlSecrets(url),
      'via': ?via,
      'headers': {
        for (final h in headers)
          h[0]: _secretName.hasMatch(h[0]) ? '•••' : h[1],
      },
      if (json?['stream'] is bool) 'stream': json!['stream'],
    },
  );
}

/// Records how the request [context] stands for ended: its HTTP [status]
/// and [body], or the [error] it failed with.
void recordPluginResponse(
  LlmCaptureContext context, {
  int? status,
  String? body,
  String? error,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final started = _startedAt.remove(context.callId) ?? now;
  final code = status ?? 0;
  final ok = error == null && code < 400;
  unawaited(
    LlmCallEventCapture.record(
      LlmCallEvent.transport(
        context: context,
        attempt: AgentOperationAttempt(
          attempt: 1,
          statusCode: code,
          status: ok
              ? 'ok'
              : error == 'aborted'
              ? 'cancelled'
              : error == 'timeout'
              ? 'timeout'
              : code >= 500
              ? 'http_5xx'
              : code >= 400
              ? 'http_4xx'
              : 'error',
          error: ok ? null : error ?? 'HTTP $code',
          startedAtMs: started,
          elapsedMs: now - started,
        ),
        responseText: body,
      ),
    ),
  );
}

/// [url] with the values of query parameters that carry credentials hidden.
String hidePluginUrlSecrets(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasQuery) return url;
  if (!uri.queryParametersAll.keys.any(_secretName.hasMatch)) return url;
  return uri
      .replace(
        queryParameters: {
          for (final e in uri.queryParametersAll.entries)
            e.key: _secretName.hasMatch(e.key) ? ['•••'] : e.value,
        },
      )
      .toString();
}

Map<String, dynamic>? _json(String? body) {
  if (body == null) return null;
  final text = body.trimLeft();
  if (!text.startsWith('{')) return null;
  try {
    final value = jsonDecode(text);
    return value is Map<String, dynamic> ? value : null;
  } catch (_) {
    return null;
  }
}

List<Map<String, dynamic>> _messages(Map<String, dynamic>? json, String? body) {
  final messages = json?['messages'];
  if (messages is List && messages.isNotEmpty && messages.every(_isMessage)) {
    final system = json!['system'];
    return [
      if (system != null) {'role': 'system', 'content': system},
      for (final m in messages) Map<String, dynamic>.from(m as Map),
    ];
  }
  // Gemini: {contents: [{role, parts: [{text}]}]}.
  final contents = json?['contents'];
  if (contents is List &&
      contents.isNotEmpty &&
      contents.every((c) => c is Map)) {
    final system = json!['systemInstruction'] ?? json['system_instruction'];
    return [
      if (system is Map) {'role': 'system', 'content': _parts(system)},
      for (final c in contents.cast<Map<dynamic, dynamic>>())
        {'role': '${c['role'] ?? 'user'}', 'content': _parts(c)},
    ];
  }
  final prompt = json?['prompt'] ?? json?['input'];
  if (prompt is String) {
    return [
      {'role': 'prompt', 'content': prompt},
    ];
  }
  if (body == null || body.isEmpty) return const [];
  return [
    {'role': 'body', 'content': body},
  ];
}

bool _isMessage(Object? m) => m is Map && m['role'] is String;

Object? _parts(Map<dynamic, dynamic> c) {
  final parts = c['parts'];
  if (parts is! List) return c;
  if (parts.every((p) => p is Map && p['text'] is String)) {
    return parts.map((p) => (p as Map)['text']).join('\n');
  }
  return parts;
}

/// A report a plugin frame sent about a request it made: `phase` `start`
/// (`method`, `url`, `headers`, `body`, `via`) or `end` (`status`, `body`,
/// `error`), both with the frame's `id` for the request. Malformed reports
/// are dropped.
void recordFramePluginRequest(
  String pluginId,
  String? sessionId,
  Map<String, dynamic> report,
) {
  final id = report['id'];
  if (id is! String || id.isEmpty || id.length > 64) return;
  final method = '${report['method'] ?? 'GET'}'.toUpperCase();
  final rawUrl = report['url'];
  final url = rawUrl is String && rawUrl.length <= 8192 ? rawUrl : null;
  final context = pluginRequestContext(
    pluginId: pluginId,
    sessionId: sessionId,
    requestId: 'frame:$id',
    method: method.length > 16 ? method.substring(0, 16) : method,
    url: url == null ? null : Uri.tryParse(url),
  );
  final body = _capped(report['body']);
  if (report['phase'] == 'start') {
    if (url == null) return;
    final headers = report['headers'];
    recordPluginRequest(
      context,
      method: method,
      url: url,
      headers: [
        if (headers is List)
          for (final h in headers.take(64))
            if (h is List && h.length == 2 && h[0] is String && h[1] is String)
              [h[0] as String, _capped(h[1])!],
      ],
      body: body,
      via: report['via'] is String ? report['via'] as String : null,
    );
  } else if (report['phase'] == 'end') {
    final status = report['status'];
    final error = report['error'];
    recordPluginResponse(
      context,
      status: status is num ? status.toInt() : null,
      body: body,
      error: error is String && error.isNotEmpty ? _capped(error) : null,
    );
  }
}

String? _capped(Object? value) {
  if (value is! String) return null;
  return value.length > kPluginRequestTextCap
      ? value.substring(0, kPluginRequestTextCap)
      : value;
}
