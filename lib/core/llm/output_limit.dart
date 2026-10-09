import 'dart:convert';

import 'tokenizer.dart';

/// Finish reasons, across providers, that mean the reply was cut off by the
/// output-token cap: OpenAI `length`, Anthropic `max_tokens`, Gemini
/// `MAX_TOKENS`, Responses `max_output_tokens`.
const _limitReasons = {'length', 'max_tokens', 'max_output_tokens'};

/// Share of the cap our own count has to reach before a reply counts as cut
/// off, when the provider reported neither a finish reason nor usage.
///
/// Our count is not the provider's: the active tokenizer may belong to another
/// model family, and before one is downloaded it is a flat four characters per
/// token, which undercounts anything that is not English. Hidden reasoning (a
/// model that thinks without streaming its thoughts) is not counted at all. So
/// the threshold sits below the cap, and lower still for the rough estimate.
const _tokenizerTolerance = 0.9;
const _approxTolerance = 0.75;

/// Whether a finished reply stopped because it ran into the output-token cap
/// rather than ending on its own.
///
/// Checked in order of trust:
/// 1. The finish reason in [rawResponse] — the provider's own word.
/// 2. The output token count in its usage block. Reasoning models spend the
///    same budget on thinking, so this count includes it.
/// 3. Our estimate of [text] plus [reasoning] against [maxTokens], with the
///    slack described on [_tokenizerTolerance].
///
/// A non-positive [maxTokens] means no cap was sent; only an explicit finish
/// reason can flag the reply then (a provider default cap, for instance).
bool hitOutputTokenLimit({
  required String text,
  String? reasoning,
  String? rawResponse,
  required int maxTokens,
}) {
  final body = _decode(rawResponse);
  if (body != null) {
    final reason = _finishReason(body);
    if (reason != null) return _limitReasons.contains(reason.toLowerCase());
  }
  if (maxTokens <= 0) return false;
  if (body != null) {
    final used = _outputTokens(body);
    if (used != null) return used >= maxTokens;
  }
  final estimated = estimateTokens(text) + estimateTokens(reasoning ?? '');
  final tolerance = activeTokenizerKind == TokenizerKind.approx
      ? _approxTolerance
      : _tokenizerTolerance;
  return estimated >= maxTokens * tolerance;
}

Map<dynamic, dynamic>? _decode(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? decoded : null;
  } catch (_) {
    return null;
  }
}

String? _finishReason(Map<dynamic, dynamic> body) {
  final choices = body['choices'];
  if (choices is List && choices.isNotEmpty && choices.first is Map) {
    final reason = (choices.first as Map)['finish_reason'];
    if (reason is String && reason.isNotEmpty) return reason;
  }
  final stopReason = body['stop_reason'];
  if (stopReason is String && stopReason.isNotEmpty) return stopReason;
  final candidates = body['candidates'];
  if (candidates is List && candidates.isNotEmpty && candidates.first is Map) {
    final reason = (candidates.first as Map)['finishReason'];
    if (reason is String && reason.isNotEmpty) return reason;
  }
  final status = body['status'];
  if (status == 'incomplete') {
    final details = body['incomplete_details'];
    final reason = details is Map ? details['reason'] : null;
    return reason is String ? reason : 'incomplete';
  }
  if (status == 'completed') return 'completed';
  return null;
}

int? _outputTokens(Map<dynamic, dynamic> body) {
  final usage = body['usage'];
  if (usage is Map) {
    final count = usage['completion_tokens'] ?? usage['output_tokens'];
    if (count is num) return count.toInt();
  }
  final meta = body['usageMetadata'];
  if (meta is Map) {
    final candidates = meta['candidatesTokenCount'];
    final thoughts = meta['thoughtsTokenCount'];
    if (candidates is num || thoughts is num) {
      return (candidates is num ? candidates.toInt() : 0) +
          (thoughts is num ? thoughts.toInt() : 0);
    }
  }
  return null;
}
