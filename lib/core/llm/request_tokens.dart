import 'tokenizer.dart';

/// Tokens of a provider-bound message list: the shape `buildApiMessages`
/// emits and a request capture records.
///
/// The Prompt Inspector counts the next request and every captured one by
/// this same rule, so a request shows one number before it is sent and after.
/// Text is what counts — string content, the text parts of multimodal
/// content, and replayed reasoning. Image parts travel outside the text and
/// are priced by the provider's own rules, so they are left out rather than
/// guessed at (their JSON, or a capture's redaction record, is not prompt
/// text either).
int countRequestTokens(Iterable<Map<String, dynamic>> messages) {
  var total = 0;
  for (final message in messages) {
    total += countRequestMessageTokens(message);
  }
  return total;
}

/// [countRequestTokens] for one message.
int countRequestMessageTokens(Map<String, dynamic> message) {
  var total = 0;
  for (final text in _texts(message['content'])) {
    total += estimateTokens(text);
  }
  final reasoning = message['reasoning_content'];
  if (reasoning is String) total += estimateTokens(reasoning);
  return total;
}

Iterable<String> _texts(Object? content) sync* {
  if (content is String) {
    yield content;
  } else if (content is List) {
    for (final part in content) {
      yield* _texts(part);
    }
  } else if (content is Map) {
    // An OpenAI text part, or a capture's record of an over-long string —
    // which keeps its first part, so the count is a floor.
    final text = content['text'];
    if ((content['type'] == 'text' || content['kind'] == 'truncated_text') &&
        text is String) {
      yield text;
    }
  }
}
