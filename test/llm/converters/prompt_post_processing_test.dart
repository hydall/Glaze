import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/converters/prompt_post_processing.dart';

List<Map<String, dynamic>> _msgs(List<(String, String)> pairs) =>
    pairs.map((p) => <String, dynamic>{'role': p.$1, 'content': p.$2}).toList();

List<(String, Object?)> _shape(List<Map<String, dynamic>> messages) =>
    messages.map((m) => (m['role'] as String, m['content'])).toList();

void main() {
  group('mode identifiers', () {
    test('normalizes the values SillyTavern writes', () {
      expect(PromptPostProcessing.normalize(''), PromptPostProcessing.none);
      expect(PromptPostProcessing.normalize(null), PromptPostProcessing.none);
      // Retired ST alias for `merge`.
      expect(
        PromptPostProcessing.normalize('claude'),
        PromptPostProcessing.merge,
      );
      expect(
        PromptPostProcessing.normalize('strict_tools'),
        PromptPostProcessing.strictTools,
      );
    });

    test('the UI list offers one row per family, no tool duplicates', () {
      expect(PromptPostProcessing.uiModes, [
        PromptPostProcessing.none,
        PromptPostProcessing.merge,
        PromptPostProcessing.semi,
        PromptPostProcessing.strict,
        PromptPostProcessing.single,
      ]);
      // Both halves of every pair stay reachable in the engine.
      for (final mode in PromptPostProcessing.toolModes) {
        expect(PromptPostProcessing.isValid(mode), isTrue, reason: mode);
      }
    });

    test('picking a family stores the tool-preserving half', () {
      expect(
        PromptPostProcessing.withTools(PromptPostProcessing.merge),
        PromptPostProcessing.mergeTools,
      );
      expect(
        PromptPostProcessing.withTools(PromptPostProcessing.semi),
        PromptPostProcessing.semiTools,
      );
      expect(
        PromptPostProcessing.withTools(PromptPostProcessing.strict),
        PromptPostProcessing.strictTools,
      );
      // No pair exists for these two.
      expect(
        PromptPostProcessing.withTools(PromptPostProcessing.single),
        PromptPostProcessing.single,
      );
      expect(
        PromptPostProcessing.withTools(PromptPostProcessing.none),
        PromptPostProcessing.none,
      );
      // Idempotent, so re-opening the picker never shifts the stored value.
      expect(
        PromptPostProcessing.withTools(PromptPostProcessing.mergeTools),
        PromptPostProcessing.mergeTools,
      );
    });

    test('both halves of a pair report the same family', () {
      for (final pair in const [
        (PromptPostProcessing.mergeTools, PromptPostProcessing.merge),
        (PromptPostProcessing.semiTools, PromptPostProcessing.semi),
        (PromptPostProcessing.strictTools, PromptPostProcessing.strict),
      ]) {
        expect(PromptPostProcessing.baseOf(pair.$1), pair.$2);
        expect(PromptPostProcessing.baseOf(pair.$2), pair.$2);
      }
      // An ST config lands on the row it corresponds to, not on "None".
      expect(PromptPostProcessing.baseOf('claude'), PromptPostProcessing.merge);
      expect(PromptPostProcessing.baseOf(''), PromptPostProcessing.none);
      expect(
        PromptPostProcessing.baseOf('nonsense'),
        PromptPostProcessing.none,
      );
    });

    test('an unknown mode degrades to none instead of reshaping', () {
      expect(
        PromptPostProcessing.normalize('nonsense'),
        PromptPostProcessing.none,
      );
      final input = _msgs([('system', 'a'), ('system', 'b')]);
      expect(postProcessPrompt(input, 'nonsense'), same(input));
    });
  });

  group('none', () {
    test('returns the prompt untouched', () {
      final input = _msgs([('system', 'a'), ('system', 'b')]);
      expect(postProcessPrompt(input, PromptPostProcessing.none), same(input));
    });
  });

  group('merge', () {
    test('squashes consecutive same-role messages', () {
      final out = postProcessPrompt(
        _msgs([
          ('system', 'sys one'),
          ('system', 'sys two'),
          ('user', 'hi'),
          ('assistant', 'hello'),
          ('user', 'a'),
          ('user', 'b'),
        ]),
        PromptPostProcessing.merge,
      );
      expect(_shape(out), [
        ('system', 'sys one\n\nsys two'),
        ('user', 'hi'),
        ('assistant', 'hello'),
        ('user', 'a\n\nb'),
      ]);
    });

    test('leaves a mid-prompt system message as system', () {
      final out = postProcessPrompt(
        _msgs([('system', 'sys'), ('user', 'hi'), ('system', 'note')]),
        PromptPostProcessing.merge,
      );
      expect(_shape(out).map((e) => e.$1), ['system', 'user', 'system']);
    });

    test('does not mutate the caller\'s messages', () {
      final input = _msgs([('system', 'a'), ('system', 'b')]);
      postProcessPrompt(input, PromptPostProcessing.merge);
      expect(_shape(input), [('system', 'a'), ('system', 'b')]);
    });

    test('is idempotent', () {
      final once = postProcessPrompt(
        _msgs([('system', 'a'), ('system', 'b'), ('user', 'hi')]),
        PromptPostProcessing.merge,
      );
      final twice = postProcessPrompt(once, PromptPostProcessing.merge);
      expect(_shape(twice), _shape(once));
    });
  });

  group('semi', () {
    test('demotes every system message after the first, then re-squashes', () {
      final out = postProcessPrompt(
        _msgs([
          ('system', 'sys'),
          ('user', 'hi'),
          ('system', 'note'),
          ('user', 'more'),
        ]),
        PromptPostProcessing.semi,
      );
      expect(_shape(out), [('system', 'sys'), ('user', 'hi\n\nnote\n\nmore')]);
    });

    test('adds no filler when the prompt opens on assistant', () {
      final out = postProcessPrompt(
        _msgs([('assistant', 'prefill')]),
        PromptPostProcessing.semi,
      );
      expect(_shape(out), [('assistant', 'prefill')]);
    });
  });

  group('strict', () {
    test('inserts a user turn after a leading system block', () {
      final out = postProcessPrompt(
        _msgs([('system', 'sys'), ('assistant', 'prefill')]),
        PromptPostProcessing.strict,
      );
      expect(_shape(out), [
        ('system', 'sys'),
        ('user', promptPostProcessingPlaceholder),
        ('assistant', 'prefill'),
      ]);
    });

    test('prepends a user turn when the prompt opens on assistant', () {
      final out = postProcessPrompt(
        _msgs([('assistant', 'prefill'), ('user', 'hi')]),
        PromptPostProcessing.strict,
      );
      expect(_shape(out), [
        ('user', promptPostProcessingPlaceholder),
        ('assistant', 'prefill'),
        ('user', 'hi'),
      ]);
    });

    test('leaves a system+user opening alone', () {
      final out = postProcessPrompt(
        _msgs([('system', 'sys'), ('user', 'hi')]),
        PromptPostProcessing.strict,
      );
      expect(_shape(out), [('system', 'sys'), ('user', 'hi')]);
    });

    test('yields strictly alternating roles', () {
      final out = postProcessPrompt(
        _msgs([
          ('system', 'sys'),
          ('system', 'sys2'),
          ('user', 'hi'),
          ('system', 'jailbreak'),
          ('assistant', 'reply'),
          ('assistant', 'more'),
        ]),
        PromptPostProcessing.strict,
      );
      expect(_shape(out), [
        ('system', 'sys\n\nsys2'),
        ('user', 'hi\n\njailbreak'),
        ('assistant', 'reply\n\nmore'),
      ]);
    });

    test('is idempotent', () {
      final once = postProcessPrompt(
        _msgs([('system', 'sys'), ('assistant', 'prefill')]),
        PromptPostProcessing.strict,
      );
      expect(
        _shape(postProcessPrompt(once, PromptPostProcessing.strict)),
        _shape(once),
      );
    });
  });

  group('single', () {
    test('collapses the whole conversation into one user message', () {
      final out = postProcessPrompt(
        _msgs([
          ('system', 'sys'),
          ('user', 'hi'),
          ('assistant', 'hello'),
          ('user', 'bye'),
        ]),
        PromptPostProcessing.single,
      );
      expect(_shape(out), [('user', 'sys\n\nhi\n\nhello\n\nbye')]);
    });

    test('labels turns when speaker names are supplied', () {
      final out = postProcessPrompt(
        _msgs([('user', 'hi'), ('assistant', 'hello')]),
        PromptPostProcessing.single,
        charName: 'Ada',
        userName: 'Bob',
      );
      expect(_shape(out), [('user', 'Bob: hi\n\nAda: hello')]);
    });

    test('is idempotent', () {
      final once = postProcessPrompt(
        _msgs([('system', 'sys'), ('user', 'hi')]),
        PromptPostProcessing.single,
      );
      expect(
        _shape(postProcessPrompt(once, PromptPostProcessing.single)),
        _shape(once),
      );
    });
  });

  group('tool traffic', () {
    List<Map<String, dynamic>> toolPrompt() => [
      {'role': 'system', 'content': 'sys'},
      {'role': 'user', 'content': 'search'},
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call_1',
            'function': {'name': 'searchMemory'},
          },
        ],
      },
      {'role': 'tool', 'content': 'result', 'tool_call_id': 'call_1'},
    ];

    test('merge_tools keeps the tool role and its call metadata', () {
      final out = postProcessPrompt(
        toolPrompt(),
        PromptPostProcessing.mergeTools,
      );
      expect(out.map((m) => m['role']), [
        'system',
        'user',
        'assistant',
        'tool',
      ]);
      expect(out[2]['tool_calls'], isNotNull);
      expect(out[3]['tool_call_id'], 'call_1');
    });

    test('merge strips tool calls and relabels tool results as user', () {
      final out = postProcessPrompt(toolPrompt(), PromptPostProcessing.merge);
      expect(out.map((m) => m['role']), [
        'system',
        'user',
        'assistant',
        'user',
      ]);
      expect(out[2].containsKey('tool_calls'), isFalse);
      expect(out[3].containsKey('tool_call_id'), isFalse);
    });

    test('consecutive tool results are never squashed together', () {
      final out = postProcessPrompt([
        {'role': 'tool', 'content': 'a', 'tool_call_id': '1'},
        {'role': 'tool', 'content': 'b', 'tool_call_id': '2'},
      ], PromptPostProcessing.mergeTools);
      expect(out, hasLength(2));
    });
  });

  group('multimodal content', () {
    test('image parts survive a merge', () {
      final out = postProcessPrompt([
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'look'},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,AAA'},
            },
          ],
        },
        {'role': 'user', 'content': 'at this'},
      ], PromptPostProcessing.merge);

      expect(out, hasLength(1));
      final parts = out.single['content'] as List;
      expect(parts, hasLength(3));
      expect(parts[0], {'type': 'text', 'text': 'look'});
      expect((parts[1] as Map)['type'], 'image_url');
      // The next message's text joined the part list instead of being dropped.
      expect(parts[2], {'type': 'text', 'text': 'at this'});
    });

    test('a text-only part list flattens back to a plain string', () {
      final out = postProcessPrompt([
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
        },
      ], PromptPostProcessing.merge);
      expect(out.single['content'], 'hi');
    });
  });

  group('degenerate input', () {
    test('an empty prompt gets a placeholder user turn', () {
      final out = postProcessPrompt(const [], PromptPostProcessing.merge);
      expect(_shape(out), [('user', promptPostProcessingPlaceholder)]);
    });

    test('an empty message opens a new run instead of joining the last', () {
      final out = postProcessPrompt(
        _msgs([('user', 'hi'), ('user', ''), ('user', 'there')]),
        PromptPostProcessing.merge,
      );
      expect(_shape(out), [('user', 'hi'), ('user', '\n\nthere')]);
    });
  });
}
