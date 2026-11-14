import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/output_limit.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';

void main() {
  setUp(() => debugSetActiveTokenizer(null, TokenizerKind.approx));

  group('finish reason', () {
    test('OpenAI length', () {
      final raw = jsonEncode({
        'choices': [
          {'finish_reason': 'length'},
        ],
      });
      expect(
        hitOutputTokenLimit(text: 'short', rawResponse: raw, maxTokens: 500),
        isTrue,
      );
    });

    test('Anthropic max_tokens', () {
      final raw = jsonEncode({'stop_reason': 'max_tokens'});
      expect(
        hitOutputTokenLimit(text: 'short', rawResponse: raw, maxTokens: 0),
        isTrue,
      );
    });

    test('Gemini MAX_TOKENS', () {
      final raw = jsonEncode({
        'candidates': [
          {'finishReason': 'MAX_TOKENS'},
        ],
      });
      expect(
        hitOutputTokenLimit(text: 'short', rawResponse: raw, maxTokens: 500),
        isTrue,
      );
    });

    test('Responses incomplete on max_output_tokens', () {
      final raw = jsonEncode({
        'status': 'incomplete',
        'incomplete_details': {'reason': 'max_output_tokens'},
      });
      expect(
        hitOutputTokenLimit(text: 'short', rawResponse: raw, maxTokens: 500),
        isTrue,
      );
    });

    test('a natural stop wins over a long count', () {
      final raw = jsonEncode({
        'choices': [
          {'finish_reason': 'stop'},
        ],
        'usage': {'completion_tokens': 500},
      });
      expect(
        hitOutputTokenLimit(
          text: 'x' * 4000,
          rawResponse: raw,
          maxTokens: 500,
        ),
        isFalse,
      );
    });
  });

  group('usage', () {
    test('OpenAI completion tokens include reasoning', () {
      final raw = jsonEncode({
        'choices': <Object>[],
        'usage': {
          'completion_tokens': 1000,
          'completion_tokens_details': {'reasoning_tokens': 900},
        },
      });
      expect(
        hitOutputTokenLimit(text: 'tiny', rawResponse: raw, maxTokens: 1000),
        isTrue,
      );
    });

    test('Gemini adds thought tokens to candidate tokens', () {
      final raw = jsonEncode({
        'usageMetadata': {
          'candidatesTokenCount': 100,
          'thoughtsTokenCount': 900,
        },
      });
      expect(
        hitOutputTokenLimit(text: 'tiny', rawResponse: raw, maxTokens: 1000),
        isTrue,
      );
    });

    test('an exact count under the cap is trusted over the estimate', () {
      final raw = jsonEncode({
        'usage': {'output_tokens': 400},
      });
      expect(
        hitOutputTokenLimit(
          text: 'x' * 4000,
          rawResponse: raw,
          maxTokens: 1000,
        ),
        isFalse,
      );
    });
  });

  group('estimate', () {
    test('counts reasoning against the cap', () {
      // 4 chars per token under the approximation: 200 + 600 = 800 of 1000.
      expect(
        hitOutputTokenLimit(
          text: 'x' * 800,
          reasoning: 'y' * 2400,
          maxTokens: 1000,
        ),
        isTrue,
      );
      expect(hitOutputTokenLimit(text: 'x' * 800, maxTokens: 1000), isFalse);
    });

    test('leaves slack for an undercounting tokenizer', () {
      // 760 of 1000 estimated: short of the cap, but the rough count is
      // allowed to be a quarter off.
      expect(hitOutputTokenLimit(text: 'x' * 3040, maxTokens: 1000), isTrue);
      expect(hitOutputTokenLimit(text: 'x' * 2800, maxTokens: 1000), isFalse);
    });

    test('no cap sent, no estimate', () {
      expect(hitOutputTokenLimit(text: 'x' * 100000, maxTokens: 0), isFalse);
    });

    test('unparseable raw falls through to the estimate', () {
      expect(
        hitOutputTokenLimit(
          text: 'x' * 4000,
          rawResponse: 'data: {"choices": []}',
          maxTokens: 1000,
        ),
        isTrue,
      );
    });
  });
}
