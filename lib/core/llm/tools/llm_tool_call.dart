import 'dart:convert';

/// One function call a model asked for, in provider-neutral form.
class LlmToolCall {
  const LlmToolCall({
    required this.id,
    required this.name,
    required this.rawArguments,
  });

  /// Provider call id; the result goes back under the same id.
  final String id;
  final String name;

  /// The arguments exactly as the provider sent them — a JSON object text.
  final String rawArguments;

  /// [rawArguments] decoded, or null when they are not a JSON object.
  Map<String, dynamic>? get arguments {
    final text = rawArguments.trim();
    if (text.isEmpty) return const {};
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

/// The calls one model response ended with, plus what must accompany them
/// when they are sent back.
class LlmToolTurn {
  const LlmToolTurn({required this.calls, this.thinkingBlocks = const []});

  final List<LlmToolCall> calls;

  /// Anthropic `thinking` / `redacted_thinking` blocks, signatures included.
  /// With extended thinking on, the assistant turn that carries the calls must
  /// replay them verbatim ahead of its `tool_use` blocks.
  final List<Map<String, dynamic>> thinkingBlocks;
}

/// Reads the tool calls out of a transport's aggregated raw response.
///
/// Transports report calls there instead of through a callback of their own:
/// `rawResponseJson` already carries the whole final message for the raw
/// view, and widening `ChatTransportOnComplete` would touch every caller.
/// Understands the Chat Completions shape (`choices[0].message.tool_calls`)
/// and the Anthropic Messages shape (`content[].type == 'tool_use'`). Returns
/// null when the response asked for no call.
LlmToolTurn? parseToolTurn(String? rawResponseJson) {
  if (rawResponseJson == null || rawResponseJson.isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(rawResponseJson);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;

  final choices = decoded['choices'];
  if (choices is List && choices.isNotEmpty) {
    final message = choices.first is Map ? choices.first['message'] : null;
    final rawCalls = message is Map ? message['tool_calls'] : null;
    if (rawCalls is! List) return null;
    final calls = <LlmToolCall>[];
    for (final (index, call) in rawCalls.indexed) {
      if (call is! Map) continue;
      final function = call['function'];
      if (function is! Map) continue;
      final name = function['name'];
      if (name is! String || name.isEmpty) continue;
      final arguments = function['arguments'];
      calls.add(
        LlmToolCall(
          id: (call['id'] as String?)?.isNotEmpty == true
              ? call['id'] as String
              : 'call_$index',
          name: name,
          rawArguments: arguments is String
              ? arguments
              : jsonEncode(arguments ?? const {}),
        ),
      );
    }
    return calls.isEmpty ? null : LlmToolTurn(calls: calls);
  }

  final content = decoded['content'];
  if (content is List) {
    final calls = <LlmToolCall>[];
    final thinking = <Map<String, dynamic>>[];
    for (final block in content) {
      if (block is! Map) continue;
      final type = block['type'];
      if (type == 'tool_use') {
        final name = block['name'];
        if (name is! String || name.isEmpty) continue;
        calls.add(
          LlmToolCall(
            id: block['id'] as String? ?? 'toolu_${calls.length}',
            name: name,
            rawArguments: jsonEncode(block['input'] ?? const {}),
          ),
        );
      } else if (type == 'thinking' || type == 'redacted_thinking') {
        thinking.add(Map<String, dynamic>.from(block));
      }
    }
    return calls.isEmpty
        ? null
        : LlmToolTurn(calls: calls, thinkingBlocks: thinking);
  }
  return null;
}

/// The conversation tail that answers [turn]: the assistant message that
/// asked for the calls, then one `tool` message per call, in call order.
///
/// Chat Completions shape — the Anthropic converter turns it into
/// `tool_use` / `tool_result` blocks. [results] is keyed by call id and holds
/// the text the model reads back.
List<Map<String, dynamic>> toolFollowUpMessages({
  required String assistantText,
  required LlmToolTurn turn,
  required Map<String, String> results,
}) => [
  {
    'role': 'assistant',
    'content': assistantText,
    'tool_calls': [
      for (final call in turn.calls)
        {
          'id': call.id,
          'type': 'function',
          'function': {'name': call.name, 'arguments': call.rawArguments},
        },
    ],
    if (turn.thinkingBlocks.isNotEmpty) 'thinking_blocks': turn.thinkingBlocks,
  },
  for (final call in turn.calls)
    {
      'role': 'tool',
      'tool_call_id': call.id,
      'content': results[call.id] ?? '',
    },
];
