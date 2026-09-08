/// Pure converter: OpenAI-shape messages → Gemini `generateContent` shape.
///
/// Ported from SillyTavern `src/prompt-converters.js::convertGooglePrompt`,
/// minus tool_calls / tool_call_id and minus group-chat name semantics.
///
/// Gemini expects:
/// - `systemInstruction: { parts: [{text}, ...] }` — collected from leading
///   system messages.
/// - `contents: [{role, parts: [...]}, ...]` where role is `'user'` or
///   `'model'` and parts can be `{text}` or `{inlineData: {mimeType, data}}`.
/// - Consecutive same-role messages are merged.
///
/// Recommended: call `mergeNonAssistant(messages)` from `message_merger.dart`
/// before this converter (the Gemini transport does this unconditionally).
library;

import 'message_merger.dart' show mergeNonAssistant;

class GeminiConversionResult {
  /// `contents` array for the request body.
  final List<Map<String, dynamic>> contents;

  /// `systemInstruction` object (omit from request body if `parts` is empty).
  final Map<String, dynamic> systemInstruction;

  const GeminiConversionResult({
    required this.contents,
    required this.systemInstruction,
  });

  bool get hasSystemInstruction =>
      (systemInstruction['parts'] as List?)?.isNotEmpty ?? false;
}

GeminiConversionResult convertGoogleMessages(
  List<Map<String, dynamic>> input, {
  bool useSystemInstruction = true,
}) {
  final messages = input
      .map((m) => Map<String, dynamic>.from(m))
      .toList(growable: true);

  // 1. Leading system run → systemInstruction.parts.
  final sysParts = <Map<String, dynamic>>[];
  if (useSystemInstruction) {
    while (messages.length > 1 && messages.first['role'] == 'system') {
      final text = _stringifyContent(messages.removeAt(0)['content']);
      if (text.isNotEmpty) sysParts.add({'text': text});
    }
  }

  final contents = <Map<String, dynamic>>[];

  for (final m in messages) {
    // 2. Role mapping.
    var role = m['role'] as String? ?? 'user';
    if (role == 'system' || role == 'tool') {
      role = 'user';
    } else if (role == 'assistant') {
      role = 'model';
    }

    // 3. Content → parts.
    final parts = <Map<String, dynamic>>[];
    final content = m['content'];
    if (content is String) {
      if (content.isNotEmpty) parts.add({'text': content});
    } else if (content is List) {
      for (final p in content) {
        if (p is! Map) continue;
        final type = p['type'];
        if (type == 'text') {
          final t = p['text'] as String?;
          if (t != null && t.isNotEmpty) parts.add({'text': t});
        } else if (type == 'image_url') {
          final imageUrl = p['image_url'];
          final url = imageUrl is Map ? imageUrl['url'] as String? : null;
          final inline = _parseDataUrl(url, defaultMime: 'image/png');
          if (inline != null) parts.add({'inlineData': inline});
        } else if (type == 'video_url') {
          final videoUrl = p['video_url'];
          final url = videoUrl is Map ? videoUrl['url'] as String? : null;
          final inline = _parseDataUrl(url, defaultMime: 'video/mp4');
          if (inline != null) parts.add({'inlineData': inline});
        } else if (type == 'audio_url') {
          final audioUrl = p['audio_url'];
          final url = audioUrl is Map ? audioUrl['url'] as String? : null;
          final inline = _parseDataUrl(url, defaultMime: 'audio/mpeg');
          if (inline != null) parts.add({'inlineData': inline});
        }
      }
    }

    if (parts.isEmpty) continue;

    // 4. Squash with previous if same role.
    if (contents.isNotEmpty && contents.last['role'] == role) {
      final lastParts = (contents.last['parts'] as List).cast<Map<String, dynamic>>();
      for (final p in parts) {
        if (p.containsKey('text')) {
          final idx = lastParts.indexWhere((q) => q.containsKey('text'));
          if (idx >= 0) {
            lastParts[idx] = {
              'text': '${lastParts[idx]['text']}\n\n${p['text']}',
            };
          } else {
            lastParts.add(p);
          }
        } else {
          lastParts.add(p);
        }
      }
    } else {
      contents.add({'role': role, 'parts': parts});
    }
  }

  return GeminiConversionResult(
    contents: contents,
    systemInstruction: {'parts': sysParts},
  );
}

/// Same as [convertGoogleMessages] but first collapses all non-assistant
/// runs into a single block per [mergeNonAssistant]. Gemini transports call
/// this — it lets the user keep authoring multi-block system chrome in the
/// preset while still getting a clean single `systemInstruction`.
GeminiConversionResult convertGoogleMessagesMerged(
  List<Map<String, dynamic>> input, {
  String mergeRole = 'system',
  bool useSystemInstruction = true,
}) {
  final merged = mergeNonAssistant(input, mergeRole: mergeRole);
  return convertGoogleMessages(
    merged,
    useSystemInstruction: useSystemInstruction,
  );
}

Map<String, dynamic>? _parseDataUrl(
  String? url, {
  required String defaultMime,
}) {
  if (url == null || !url.startsWith('data:')) return null;
  final match = RegExp(r'^data:([^;]+);base64,(.+)$').firstMatch(url);
  if (match == null) return null;
  return {
    'mimeType': match.group(1) ?? defaultMime,
    'data': match.group(2),
  };
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
  return '';
}
