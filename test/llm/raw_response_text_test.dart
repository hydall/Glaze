import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/raw_response_text.dart';

void main() {
  group('OpenAI Chat Completions', () {
    test('reads the assistant message', () {
      final raw = jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'hello there'},
          },
        ],
      });

      expect(extractAssistantText(raw), 'hello there');
    });

    test('falls back to a streamed delta', () {
      final raw = jsonEncode({
        'choices': [
          {
            'delta': {'content': 'partial'},
          },
        ],
      });

      expect(extractAssistantText(raw), 'partial');
    });

    test('joins a multimodal content part list', () {
      final raw = jsonEncode({
        'choices': [
          {
            'message': {
              'content': [
                {'type': 'text', 'text': 'one '},
                {'type': 'text', 'text': 'two'},
              ],
            },
          },
        ],
      });

      expect(extractAssistantText(raw), 'one two');
    });
  });

  group('Anthropic', () {
    test('joins text blocks and skips thinking', () {
      final raw = jsonEncode({
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'thinking', 'thinking': 'internal notes'},
          {'type': 'text', 'text': 'visible reply'},
        ],
      });

      expect(extractAssistantText(raw), 'visible reply');
    });

    test('handles a response with only thinking', () {
      final raw = jsonEncode({
        'content': [
          {'type': 'thinking', 'thinking': 'internal notes'},
        ],
      });

      expect(extractAssistantText(raw), isNull);
    });
  });

  group('Gemini', () {
    test('joins candidate parts and skips thought parts', () {
      final raw = jsonEncode({
        'candidates': [
          {
            'content': {
              'role': 'model',
              'parts': [
                {'text': 'internal notes', 'thought': true},
                {'text': 'visible '},
                {'text': 'reply'},
              ],
            },
            'finishReason': 'STOP',
          },
        ],
      });

      expect(extractAssistantText(raw), 'visible reply');
    });
  });

  group('OpenAI Responses', () {
    test('reads output_text out of the message item', () {
      final raw = jsonEncode({
        'object': 'response',
        'output': [
          {
            'type': 'reasoning',
            'summary': [
              {'type': 'summary_text', 'text': 'internal notes'},
            ],
          },
          {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': 'visible reply'},
            ],
          },
        ],
      });

      expect(extractAssistantText(raw), 'visible reply');
    });
  });

  group('unusable payloads', () {
    test('returns null for malformed JSON', () {
      expect(extractAssistantText('not json at all'), isNull);
    });

    test('returns null for an empty string', () {
      expect(extractAssistantText(''), isNull);
    });

    test('returns null for a shape it does not know', () {
      expect(extractAssistantText(jsonEncode({'error': 'boom'})), isNull);
    });

    test('returns null when the assistant text is empty', () {
      final raw = jsonEncode({
        'choices': [
          {
            'message': {'content': ''},
          },
        ],
      });

      expect(extractAssistantText(raw), isNull);
    });
  });
}
