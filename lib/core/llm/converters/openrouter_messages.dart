/// OpenRouter-specific extensions on top of the OpenAI message shape.
///
/// OpenRouter accepts an OpenAI-compatible body, so the bulk of conversion is
/// the identity. These helpers add the extras:
/// - `cachingAtDepthForOpenRouterClaude` — sticks `cache_control: {type:
///   ephemeral, ttl}` on message text parts at a stable depth, so OR's cache
///   layer can pin the longest common prefix across turns.
/// - `cachingSystemPromptForOpenRouter` — same idea, applied to the leading
///   system message.
///
/// Ported from SillyTavern `src/prompt-converters.js`.
library;

/// Adds `cache_control` markers at [cachingAtDepth] for Claude-via-OR.
///
/// Walks messages **back to front**, skipping the trailing assistant prefill
/// and any system messages (they don't affect depth counting). Sets
/// `cache_control` on the last content part of messages at depth N and N+2,
/// matching OR's two-breakpoint convention. Pure: returns a new list.
List<Map<String, dynamic>> cachingAtDepthForOpenRouterClaude(
  List<Map<String, dynamic>> input,
  int cachingAtDepth,
  String ttl,
) {
  if (cachingAtDepth < 0) return input;
  final messages = input
      .map((m) => Map<String, dynamic>.from(m))
      .toList(growable: true);

  var passedThePrefill = false;
  var depth = 0;
  String? previousRoleName;

  for (var i = messages.length - 1; i >= 0; i--) {
    final role = messages[i]['role'];
    if (!passedThePrefill && role == 'assistant') continue;
    passedThePrefill = true;

    if (role == 'system') continue;

    if (role != previousRoleName) {
      if (depth == cachingAtDepth || depth == cachingAtDepth + 2) {
        _markCacheControlOnLastPart(messages[i], ttl);
      }
      if (depth == cachingAtDepth + 2) break;
      depth += 1;
      previousRoleName = role as String?;
    }
  }

  return messages;
}

/// Adds `cache_control` to the leading system message (or its last text part
/// if it's an array). No-op if already cached. Returns a new list.
List<Map<String, dynamic>> cachingSystemPromptForOpenRouter(
  List<Map<String, dynamic>> input, {
  String? ttl,
}) {
  if (input.isEmpty) return input;

  final messages = input
      .map((m) => Map<String, dynamic>.from(m))
      .toList(growable: true);

  final sysIdx = messages.indexWhere((m) => m['role'] == 'system');
  if (sysIdx < 0) return messages;

  final sys = messages[sysIdx];
  if (sys.containsKey('cache_control')) return messages;

  final cacheControl = <String, dynamic>{
    'type': 'ephemeral',
    'ttl': ?ttl,
  };

  final content = sys['content'];
  if (content is List) {
    final alreadyCached = content.any(
      (p) => p is Map && p.containsKey('cache_control'),
    );
    if (alreadyCached) return messages;
    final mutable = content.cast<dynamic>().toList();
    for (var i = mutable.length - 1; i >= 0; i--) {
      final p = mutable[i];
      if (p is Map && p['type'] == 'text') {
        final updated = Map<String, dynamic>.from(p);
        updated['cache_control'] = cacheControl;
        mutable[i] = updated;
        sys['content'] = mutable;
        return messages;
      }
    }
  } else if (content is String) {
    sys['content'] = [
      {
        'type': 'text',
        'text': content,
        'cache_control': cacheControl,
      },
    ];
  }

  return messages;
}

/// Heuristic: matches `claude-*` and the common OR slugs for Anthropic models.
bool isClaudeModelOnOpenRouter(String model) {
  final m = model.toLowerCase();
  return m.contains('claude') || m.startsWith('anthropic/');
}

void _markCacheControlOnLastPart(Map<String, dynamic> message, String ttl) {
  final content = message['content'];
  final cacheControl = <String, dynamic>{'type': 'ephemeral', 'ttl': ttl};

  if (content is String) {
    message['content'] = [
      {
        'type': 'text',
        'text': content,
        'cache_control': cacheControl,
      },
    ];
    return;
  }
  if (content is List && content.isNotEmpty) {
    final last = content.last;
    if (last is Map) {
      final updated = Map<String, dynamic>.from(last);
      updated['cache_control'] = cacheControl;
      final mutable = content.cast<dynamic>().toList();
      mutable[mutable.length - 1] = updated;
      message['content'] = mutable;
    }
  }
}
