import 'dart:convert';

/// Extracts the assistant's visible text out of a raw provider payload.
///
/// `ChatState.lastRawResponse` holds whatever the active transport captured —
/// a real provider response on non-streaming calls, or the aggregate the
/// transport reassembles from SSE deltas. Each protocol has its own shape, so
/// the prompt inspector needs all four to render its "pretty" response view;
/// reading only the OpenAI shape made Anthropic and Gemini fall back to
/// dumping raw JSON.
///
/// Returns `null` when the payload can't be decoded or carries no assistant
/// text, which callers should treat as "show the raw JSON instead".
///
/// Reasoning is deliberately excluded — it has its own place in the UI, and
/// the raw view still shows it.
String? extractAssistantText(String raw) {
  if (raw.isEmpty) return null;

  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;

  for (final extract in const [
    _fromOpenAiChoices,
    _fromResponsesOutput,
    _fromGeminiCandidates,
    _fromAnthropicContent,
  ]) {
    final text = extract(decoded);
    if (text != null && text.isNotEmpty) return text;
  }
  return null;
}

/// OpenAI Chat Completions and every OpenAI-compatible endpoint, including the
/// aggregate `OpenAiChatTransport` builds from a stream. `content` is normally
/// a plain string, but some proxies mirror the multimodal part list back.
String? _fromOpenAiChoices(Map<dynamic, dynamic> body) {
  final choices = body['choices'];
  if (choices is! List || choices.isEmpty) return null;
  final first = choices.first;
  if (first is! Map) return null;

  for (final key in const ['message', 'delta']) {
    final holder = first[key];
    if (holder is! Map) continue;
    final content = holder['content'];
    if (content is String) return content;
    if (content is List) {
      return _joinParts(content, textKey: 'text');
    }
  }
  // Text-completion style fallback (`/completions`, koboldcpp and friends).
  final text = first['text'];
  return text is String ? text : null;
}

/// OpenAI Responses API: a flat `output` list where the assistant turn is a
/// `message` item holding `output_text` parts.
String? _fromResponsesOutput(Map<dynamic, dynamic> body) {
  final output = body['output'];
  if (output is! List) return null;

  final buffer = StringBuffer();
  for (final item in output) {
    if (item is! Map || item['type'] != 'message') continue;
    final content = item['content'];
    if (content is! List) continue;
    for (final part in content) {
      if (part is! Map) continue;
      if (part['type'] != 'output_text') continue;
      final text = part['text'];
      if (text is String) buffer.write(text);
    }
  }
  return buffer.isEmpty ? null : buffer.toString();
}

/// Gemini: `candidates[].content.parts[]`. Thought parts are flagged with
/// `thought: true` and must not be mixed into the reply.
String? _fromGeminiCandidates(Map<dynamic, dynamic> body) {
  final candidates = body['candidates'];
  if (candidates is! List || candidates.isEmpty) return null;
  final first = candidates.first;
  if (first is! Map) return null;
  final content = first['content'];
  if (content is! Map) return null;
  final parts = content['parts'];
  if (parts is! List) return null;

  final buffer = StringBuffer();
  for (final part in parts) {
    if (part is! Map) continue;
    if (part['thought'] == true) continue;
    final text = part['text'];
    if (text is String) buffer.write(text);
  }
  return buffer.isEmpty ? null : buffer.toString();
}

/// Anthropic: a top-level `content` block list. `thinking` blocks are skipped;
/// a bare string `content` covers hand-rolled proxies.
String? _fromAnthropicContent(Map<dynamic, dynamic> body) {
  final content = body['content'];
  if (content is String) return content;
  if (content is! List) return null;
  return _joinParts(content, textKey: 'text');
}

/// Concatenates the `text` of every part that isn't a reasoning block.
String? _joinParts(List<dynamic> parts, {required String textKey}) {
  final buffer = StringBuffer();
  for (final part in parts) {
    if (part is! Map) continue;
    final type = part['type'];
    if (type == 'thinking' || type == 'redacted_thinking') continue;
    final text = part[textKey];
    if (text is String) buffer.write(text);
  }
  return buffer.isEmpty ? null : buffer.toString();
}
