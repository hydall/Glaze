import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/converters/message_merger.dart';

void main() {
  group('mergeNonAssistant', () {
    test('merges consecutive system+user into one block at mergeRole', () {
      final r = mergeNonAssistant([
        {'role': 'system', 'content': 'A'},
        {'role': 'user', 'content': 'B'},
        {'role': 'system', 'content': 'C'},
        {'role': 'assistant', 'content': 'reply'},
        {'role': 'user', 'content': 'D'},
      ]);
      // Three non-assistant before fence → one merged.
      expect(r, hasLength(3));
      expect(r[0]['role'], 'system');
      expect(r[0]['content'], 'A\n\nB\n\nC');
      expect(r[1]['role'], 'assistant');
      expect(r[1]['content'], 'reply');
      expect(r[2]['role'], 'system');
      expect(r[2]['content'], 'D');
    });

    test('assistant message acts as fence; "model" also fences', () {
      final r = mergeNonAssistant([
        {'role': 'user', 'content': 'a'},
        {'role': 'model', 'content': 'm'},
        {'role': 'user', 'content': 'b'},
      ]);
      expect(r, hasLength(3));
      expect(r[1]['role'], 'model');
    });

    test('idempotent: merge(merge(x)) == merge(x)', () {
      final input = [
        {'role': 'system', 'content': 'A'},
        {'role': 'user', 'content': 'B'},
        {'role': 'assistant', 'content': 'C'},
        {'role': 'user', 'content': 'D'},
        {'role': 'system', 'content': 'E'},
      ];
      final once = mergeNonAssistant(input);
      final twice = mergeNonAssistant(once);
      expect(twice, once);
    });

    test('merges across mixed content arrays preserving image parts', () {
      final r = mergeNonAssistant([
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'first'},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,AAA'},
            },
          ],
        },
        {'role': 'system', 'content': 'second'},
      ]);
      expect(r, hasLength(1));
      final content = r[0]['content'] as List;
      // text from #1 merged with #2's string into a single text part, image
      // preserved at the end.
      expect(content.where((p) => p is Map && p['type'] == 'image_url'),
          hasLength(1));
    });

    test('empty input returns empty list', () {
      expect(mergeNonAssistant(const []), isEmpty);
    });

    test('input is not mutated', () {
      final input = [
        {'role': 'system', 'content': 'A'},
        {'role': 'user', 'content': 'B'},
      ];
      final clone = [
        {...input[0]},
        {...input[1]},
      ];
      mergeNonAssistant(input);
      expect(input, clone);
    });
  });
}
