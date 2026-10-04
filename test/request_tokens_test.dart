import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/request_tokens.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';

void main() {
  test('counts string content and replayed reasoning', () {
    expect(
      countRequestTokens([
        {'role': 'system', 'content': 'You are a knight.'},
        {
          'role': 'assistant',
          'content': 'Hello there.',
          'reasoning_content': 'Greet them.',
        },
      ]),
      estimateTokens('You are a knight.') +
          estimateTokens('Hello there.') +
          estimateTokens('Greet them.'),
    );
  });

  test('counts the text parts of multimodal content, not their JSON', () {
    final message = {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'Look at this.'},
        {
          'type': 'image_url',
          'image_url': {
            // How a capture records the data URI it redacted.
            'url': {
              'kind': 'redacted_data_uri',
              'prefix': 'data:image/png;base64,iVBORw0KGgo',
              'charCount': 120000,
              'sha256': 'abc',
            },
          },
        },
      ],
    };

    expect(countRequestMessageTokens(message), estimateTokens('Look at this.'));
  });

  test('counts what a capture kept of a truncated string', () {
    expect(
      countRequestMessageTokens({
        'role': 'user',
        'content': {
          'kind': 'truncated_text',
          'text': 'kept part',
          'charCount': 300000,
          'sha256': 'abc',
        },
      }),
      estimateTokens('kept part'),
    );
  });
}
