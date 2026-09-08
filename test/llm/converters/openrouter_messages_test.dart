import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/converters/openrouter_messages.dart';

void main() {
  group('cachingAtDepthForOpenRouterClaude', () {
    test('marks last text part at the configured depth', () {
      // Last assistant is prefill (skipped). Walking back, the user-assistant-
      // user pattern increments depth at each role flip. At depth=0 we mark.
      final r = cachingAtDepthForOpenRouterClaude(
        [
          {'role': 'system', 'content': 'sys'},
          {'role': 'user', 'content': 'u1'},
          {'role': 'assistant', 'content': 'a1'},
          {'role': 'user', 'content': 'u2'},
          {'role': 'assistant', 'content': ''}, // trailing prefill
        ],
        0,
        '5m',
      );
      // The cache_control marker should be on the deepest user message that
      // is not the prefill — that's `u2`. Its content was a String → became
      // a one-part array with cache_control on the text part.
      final u2 = r[3];
      expect(u2['role'], 'user');
      expect(u2['content'], isA<List<dynamic>>());
      final parts = u2['content'] as List;
      expect(parts.last['cache_control'], {'type': 'ephemeral', 'ttl': '5m'});
    });

    test('system messages do not consume depth slots', () {
      final r = cachingAtDepthForOpenRouterClaude(
        [
          {'role': 'system', 'content': 'sys'},
          {'role': 'user', 'content': 'u1'},
          {'role': 'system', 'content': 'midsys'},
          {'role': 'assistant', 'content': 'a1'},
          {'role': 'user', 'content': 'u2'},
        ],
        0,
        '1h',
      );
      // depth=0 → mark u2 (latest non-system, non-assistant-prefill).
      final u2 = r.last;
      final parts = u2['content'] as List;
      expect(parts.last['cache_control']?['type'], 'ephemeral');
      // mid system is untouched.
      final midSys = r.firstWhere(
        (m) => m['role'] == 'system' && m['content'] == 'midsys',
      );
      expect(midSys.containsKey('cache_control'), isFalse);
    });

    test('input is not mutated', () {
      final input = [
        {'role': 'user', 'content': 'u'},
      ];
      final clone = [
        {...input[0]},
      ];
      cachingAtDepthForOpenRouterClaude(input, 0, '5m');
      expect(input, clone);
    });
  });

  group('cachingSystemPromptForOpenRouter', () {
    test('wraps string content into array with cache_control', () {
      final r = cachingSystemPromptForOpenRouter([
        {'role': 'system', 'content': 'you are X'},
        {'role': 'user', 'content': 'q'},
      ], ttl: '5m');
      final sys = r[0];
      expect(sys['content'], isA<List<dynamic>>());
      final parts = sys['content'] as List;
      expect(parts, hasLength(1));
      expect(parts[0]['cache_control'], {'type': 'ephemeral', 'ttl': '5m'});
    });

    test('marks last text part of array content', () {
      final r = cachingSystemPromptForOpenRouter([
        {
          'role': 'system',
          'content': [
            {'type': 'text', 'text': 'part1'},
            {'type': 'text', 'text': 'part2'},
          ],
        },
      ]);
      final parts = r[0]['content'] as List;
      expect(parts[1]['cache_control']?['type'], 'ephemeral');
      expect(parts[0].containsKey('cache_control'), isFalse);
    });

    test('no-op when already cached', () {
      final input = [
        {
          'role': 'system',
          'content': [
            {
              'type': 'text',
              'text': 'foo',
              'cache_control': {'type': 'ephemeral'},
            },
          ],
        },
      ];
      final r = cachingSystemPromptForOpenRouter(input);
      // Marker not re-added.
      final parts = r[0]['content'] as List;
      expect(parts, hasLength(1));
    });

    test('no system message → unchanged', () {
      final r = cachingSystemPromptForOpenRouter([
        {'role': 'user', 'content': 'hi'},
      ]);
      expect(r, hasLength(1));
      expect(r[0].containsKey('cache_control'), isFalse);
    });
  });

  group('isClaudeModelOnOpenRouter', () {
    test('matches bare claude- ids', () {
      expect(isClaudeModelOnOpenRouter('claude-3-5-sonnet'), isTrue);
      expect(isClaudeModelOnOpenRouter('Claude-Opus-4'), isTrue);
    });

    test('matches anthropic/ slug', () {
      expect(isClaudeModelOnOpenRouter('anthropic/claude-3-opus'), isTrue);
    });

    test('rejects non-Claude', () {
      expect(isClaudeModelOnOpenRouter('openai/gpt-4o'), isFalse);
      expect(isClaudeModelOnOpenRouter('google/gemini-2.5-pro'), isFalse);
    });
  });
}
