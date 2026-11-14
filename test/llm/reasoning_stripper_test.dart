import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/reasoning_stripper.dart';

void main() {
  group('ReasoningStripper.stripMessageReasoning', () {
    test('preserves paragraph newlines in history content', () {
      final messages = [
        {
          'role': 'assistant',
          'content':
              '*First action paragraph.*\n\n*Second action paragraph.*\n\n«Dialogue.»',
        },
      ];
      final result = ReasoningStripper.stripMessageReasoning(messages);
      expect(result[0]['content'], contains('\n\n'));
      expect(
        result[0]['content'],
        '*First action paragraph.*\n\n*Second action paragraph.*\n\n«Dialogue.»',
      );
    });

    test('preserves single newlines inside content', () {
      final messages = [
        {
          'role': 'assistant',
          'content': 'Line one\nLine two\nLine three',
        },
      ];
      final result = ReasoningStripper.stripMessageReasoning(messages);
      expect(result[0]['content'], 'Line one\nLine two\nLine three');
    });

    test('rewrites literal think tags to hidden reasoning', () {
      final messages = [
        {
          'role': 'system',
          'content': 'Use <think>reasoning</think> for planning.',
        },
      ];
      final result = ReasoningStripper.stripMessageReasoning(messages);
      expect(result[0]['content'], contains('hidden reasoning'));
      expect(result[0]['content'], isNot(contains('<think>')));
      expect(result[0]['content'], isNot(contains('</think>')));
    });

    test('strips Plan internally directive and preserves surrounding newlines', () {
      final messages = [
        {
          'role': 'system',
          'content':
              'Introduction.\n\nPlan internally before responding <think>secret</think> after.\n\nConclusion.',
        },
      ];
      final result = ReasoningStripper.stripMessageReasoning(messages);
      final content = result[0]['content'] as String;
      expect(content, isNot(contains('Plan internally')));
      expect(content, isNot(contains('secret')));
      expect(content, contains('Introduction.'));
      expect(content, contains('Conclusion.'));
    });

    test('does not collapse non-directive whitespace in roleplay content', () {
      final rp =
          '*action one* "dialogue" *action two*\n\n*action three*\n\n«quote»';
      final messages = [
        {'role': 'assistant', 'content': rp},
      ];
      final result = ReasoningStripper.stripMessageReasoning(messages);
      expect(result[0]['content'], rp);
    });

    test('preserves lumiaooc blocks with internal newlines', () {
      final content =
          '*Action.*\n\n<lumiaooc>\nOOC note here\nmore notes\n</lumiaooc>';
      final messages = [
        {'role': 'assistant', 'content': content},
      ];
      final result = ReasoningStripper.stripMessageReasoning(messages);
      expect(result[0]['content'], content);
    });

    test('passes through non-string content unchanged', () {
      final messages = [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hello'},
          ],
        },
      ];
      final result = ReasoningStripper.stripMessageReasoning(messages);
      expect(result[0]['content'], same(messages[0]['content']));
    });
  });
}
