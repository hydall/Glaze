/// Pure converter: OpenAI-shape messages → Anthropic Messages API shape.
///
/// Ported from SillyTavern `src/prompt-converters.js::convertClaudeMessages`,
/// minus tool_calls / tool_results (out of scope) and minus the SillyTavern
/// `names` rewrites (no group-chat semantics here).
///
/// Output contract:
/// - `system` is a list of `{type: 'text', text}` parts collected from the
///   leading run of `system` messages. May be empty.
/// - `messages` is the Anthropic shape: `[{role: 'user'|'assistant', content: [...parts]}]`.
///   Consecutive same-role messages get squashed.
/// - When [extractPrefill] is true (default) and the input's last message has
///   `role: 'assistant'`, it is treated as a prefill: trailing whitespace is
///   trimmed, the text is exposed on `prefill`, and the message is appended
///   to `messages` as the final assistant turn (Anthropic Messages API treats
///   a trailing assistant turn as a continuation point).
/// - When [extractPrefill] is false (extended thinking enabled), trailing
///   assistant messages are passed through but no `prefill` text is returned
///   — callers should drop the prefill from the request entirely in that mode.
library;

import 'dart:convert';

const String _zwsp = '​';

class ClaudeConversionResult {
  /// Anthropic `messages` array.
  final List<Map<String, dynamic>> messages;

  /// Anthropic `system` parts (may be empty).
  final List<Map<String, dynamic>> system;

  /// Detected prefill text (trailing assistant content), or null if none.
  /// Caller uses this to prepend back to the streamed response so the UI
  /// shows a continuous reply.
  final String? prefill;

  const ClaudeConversionResult({
    required this.messages,
    required this.system,
    this.prefill,
  });
}

ClaudeConversionResult convertClaudeMessages(
  List<Map<String, dynamic>> input, {
  bool extractPrefill = true,
}) {
  // Defensive deep-ish copy so we don't mutate the caller's list / maps.
  final messages = input
      .map((m) => Map<String, dynamic>.from(m))
      .toList(growable: true);

  // 1. Leading system run → `system` parts.
  final system = <Map<String, dynamic>>[];
  while (messages.isNotEmpty && messages.first['role'] == 'system') {
    final m = messages.removeAt(0);
    final text = _stringifyContent(m['content']);
    if (text.isNotEmpty) {
      system.add({'type': 'text', 'text': text});
    }
  }

  if (messages.isEmpty) {
    messages.add({'role': 'user', 'content': "Let's get started."});
  }

  // 2. Per-message normalisation.
  for (final m in messages) {
    if (m['role'] == 'system') {
      m['role'] = 'user';
    }
    final content = m['content'];
    if (content is String) {
      m['content'] = [
        {'type': 'text', 'text': content.isEmpty ? _zwsp : content},
      ];
    } else if (content is List) {
      m['content'] = content.map(_convertContentPart).toList().cast<dynamic>();
    } else {
      m['content'] = [
        {'type': 'text', 'text': _zwsp},
      ];
    }
    // Drop fields Anthropic doesn't accept.
    m.remove('name');
    m.remove('tool_calls');
    m.remove('tool_call_id');
  }

  // 3. Move images out of assistant turns (Claude rejects images on assistant).
  for (var i = 0; i < messages.length; i++) {
    if (messages[i]['role'] != 'assistant') continue;
    final parts = (messages[i]['content'] as List).cast<dynamic>();
    final images = parts
        .where((p) => p is Map && p['type'] == 'image')
        .toList()
        .cast<dynamic>();
    if (images.isEmpty) continue;
    final textParts = parts
        .where((p) => !(p is Map && p['type'] == 'image'))
        .toList()
        .cast<dynamic>();
    messages[i]['content'] = textParts;

    var j = i + 1;
    while (j < messages.length && messages[j]['role'] != 'user') {
      j++;
    }
    if (j >= messages.length) {
      messages.insert(j, {'role': 'user', 'content': <dynamic>[]});
    }
    final target = <dynamic>[
      ...(messages[j]['content'] as List),
      ...images,
    ];
    messages[j]['content'] = target;
  }

  // 4. Prefill handling.
  String? prefill;
  if (extractPrefill && messages.isNotEmpty &&
      messages.last['role'] == 'assistant') {
    final parts = messages.last['content'] as List;
    final buffer = StringBuffer();
    for (final p in parts) {
      if (p is Map && p['type'] == 'text') {
        buffer.write(p['text'] ?? '');
      }
    }
    final trimmed = buffer.toString().replaceFirst(RegExp(r'[ \t\r\n]+$'), '');
    if (trimmed.isNotEmpty) {
      prefill = trimmed;
      messages.last['content'] = [
        {'type': 'text', 'text': trimmed},
      ];
    }
  }

  // 5. Squash consecutive same-role messages.
  final merged = <Map<String, dynamic>>[];
  for (final m in messages) {
    if (merged.isNotEmpty && merged.last['role'] == m['role']) {
      final combined = <dynamic>[
        ...(merged.last['content'] as List),
        ...(m['content'] as List),
      ];
      merged.last['content'] = combined;
    } else {
      merged.add(m);
    }
  }

  return ClaudeConversionResult(
    messages: merged,
    system: system,
    prefill: prefill,
  );
}

dynamic _convertContentPart(dynamic part) {
  if (part is! Map) return part;
  final type = part['type'];

  if (type == 'image_url') {
    final imageUrl = part['image_url'];
    final url = imageUrl is Map ? imageUrl['url'] as String? : null;
    if (url == null || !url.startsWith('data:')) {
      // Anthropic requires base64 — drop URL-only images.
      return {'type': 'text', 'text': _zwsp};
    }
    final match = RegExp(r'^data:([^;]+);base64,(.+)$').firstMatch(url);
    if (match == null) {
      return {'type': 'text', 'text': _zwsp};
    }
    return {
      'type': 'image',
      'source': {
        'type': 'base64',
        'media_type': match.group(1),
        'data': match.group(2),
      },
    };
  }

  if (type == 'text') {
    final t = part['text'] as String?;
    return {'type': 'text', 'text': (t == null || t.isEmpty) ? _zwsp : t};
  }

  // Anthropic-native shapes (`image` / `tool_*`) pass through unchanged.
  return part;
}

String _stringifyContent(dynamic content) {
  if (content == null) return '';
  if (content is String) return content;
  if (content is List) {
    final parts = <String>[];
    for (final p in content) {
      if (p is Map && p['type'] == 'text') {
        final t = p['text'];
        if (t is String) parts.add(t);
      }
    }
    return parts.join('\n\n');
  }
  return jsonEncode(content);
}
