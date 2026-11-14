import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/converters/claude_messages.dart';

void main() {
  group('convertClaudeMessages', () {
    test('extracts leading system run into system parts', () {
      final result = convertClaudeMessages([
        {'role': 'system', 'content': 'You are a helpful AI.'},
        {'role': 'system', 'content': 'Be terse.'},
        {'role': 'user', 'content': 'Hi.'},
      ]);
      expect(result.system, hasLength(2));
      expect(result.system[0], {'type': 'text', 'text': 'You are a helpful AI.'});
      expect(result.system[1], {'type': 'text', 'text': 'Be terse.'});
      expect(result.messages, hasLength(1));
      expect(result.messages[0]['role'], 'user');
    });

    test('non-leading system messages are converted to user', () {
      final result = convertClaudeMessages([
        {'role': 'system', 'content': 'sysA'},
        {'role': 'user', 'content': 'hello'},
        {'role': 'system', 'content': 'mid-system'},
        {'role': 'assistant', 'content': 'ack'},
      ]);
      expect(result.system, hasLength(1));
      expect(result.messages, hasLength(2));
      // user "hello" merged with the converted-to-user "mid-system".
      expect(result.messages[0]['role'], 'user');
      final parts = result.messages[0]['content'] as List;
      expect(parts.any((p) => p['type'] == 'text' && p['text'] == 'hello'), isTrue);
      expect(parts.any((p) => p['type'] == 'text' && p['text'] == 'mid-system'), isTrue);
      expect(result.messages[1]['role'], 'assistant');
    });

    test('squashes consecutive same-role messages by appending parts', () {
      final result = convertClaudeMessages([
        {'role': 'user', 'content': 'one'},
        {'role': 'user', 'content': 'two'},
        {'role': 'assistant', 'content': 'reply'},
      ]);
      expect(result.messages, hasLength(2));
      final parts = result.messages[0]['content'] as List;
      expect(parts, hasLength(2));
      expect(parts[0], {'type': 'text', 'text': 'one'});
      expect(parts[1], {'type': 'text', 'text': 'two'});
    });

    test('empty content becomes zero-width-space, not dropped', () {
      final result = convertClaudeMessages([
        {'role': 'user', 'content': ''},
      ]);
      final parts = result.messages[0]['content'] as List;
      expect(parts[0]['type'], 'text');
      expect((parts[0]['text'] as String).isNotEmpty, isTrue);
    });

    test('extractPrefill captures trailing assistant text, trims tail', () {
      final result = convertClaudeMessages([
        {'role': 'user', 'content': 'tell me a story'},
        {'role': 'assistant', 'content': 'Once upon a time   \n  '},
      ]);
      expect(result.prefill, 'Once upon a time');
      // Trailing assistant message stays in messages array — Claude expects it.
      expect(result.messages.last['role'], 'assistant');
      final lastParts = result.messages.last['content'] as List;
      expect(lastParts[0]['text'], 'Once upon a time');
    });

    test('extractPrefill=false leaves trailing assistant alone', () {
      final result = convertClaudeMessages(
        [
          {'role': 'user', 'content': 'q'},
          {'role': 'assistant', 'content': 'prefill text  '},
        ],
        extractPrefill: false,
      );
      expect(result.prefill, isNull);
    });

    test('image_url with data: URL becomes Anthropic image source', () {
      final dataUrl =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
      final result = convertClaudeMessages([
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'whats this?'},
            {
              'type': 'image_url',
              'image_url': {'url': dataUrl},
            },
          ],
        },
      ]);
      final parts = result.messages[0]['content'] as List;
      expect(parts, hasLength(2));
      expect(parts[0]['type'], 'text');
      expect(parts[1]['type'], 'image');
      expect(parts[1]['source']['type'], 'base64');
      expect(parts[1]['source']['media_type'], 'image/png');
      expect((parts[1]['source']['data'] as String).length > 10, isTrue);
    });

    test('image_url with non-data URL is dropped (replaced by zwsp)', () {
      final result = convertClaudeMessages([
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'https://example.com/foo.png'},
            },
          ],
        },
      ]);
      final parts = result.messages[0]['content'] as List;
      // Replaced with zwsp text — Anthropic accepts that, just no image.
      expect(parts[0]['type'], 'text');
      expect(parts.where((p) => p['type'] == 'image'), isEmpty);
    });

    test('images in assistant message are moved to next user', () {
      final dataUrl = 'data:image/png;base64,AAAA';
      final result = convertClaudeMessages([
        {'role': 'user', 'content': 'hi'},
        {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'ack'},
            {
              'type': 'image_url',
              'image_url': {'url': dataUrl},
            },
          ],
        },
        {'role': 'user', 'content': 'next'},
      ]);
      // Find the assistant turn.
      final assistant = result.messages.firstWhere(
        (m) => m['role'] == 'assistant',
      );
      final assistantParts = assistant['content'] as List;
      expect(
        assistantParts.where((p) => p['type'] == 'image'),
        isEmpty,
        reason: 'image stripped from assistant',
      );

      // The next user turn (last) gets the image.
      final lastUser = result.messages.lastWhere((m) => m['role'] == 'user');
      final userParts = lastUser['content'] as List;
      expect(userParts.where((p) => p['type'] == 'image'), hasLength(1));
    });

    test('input is not mutated', () {
      final input = [
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'u'},
      ];
      final inputClone = [
        {...input[0]},
        {...input[1]},
      ];
      convertClaudeMessages(input);
      expect(input, inputClone);
    });
  });
}
