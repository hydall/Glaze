import 'dart:convert';

/// Unwraps a structured-output JSON object back into the plain text the model
/// was forced to begin with.
///
/// A `functionPrefill` block with `prefillStyle: 'structured'` sends a schema
/// of the shape `{prefix (enum), content (string)}`. The model is forced to
/// emit `prefix` before it streams `content`, so the visible reply is exactly
/// `prefix + content`. This mirrors the tool-call prefill: the prefill text is
/// the start of the reply, and whatever the model wrote after it is the rest.
String unwrapStructuredResponse(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) {
      final prefix = decoded['prefix'];
      final content = decoded['content'];
      final prefixText = prefix is String ? prefix : '';
      final contentText = content is String ? content : '';
      if (prefixText.isEmpty && contentText.isEmpty) {
        return trimmed;
      }
      return '$prefixText$contentText';
    }
  } catch (_) {}
  return trimmed;
}
