import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/json_repair.dart';

void main() {
  group('extractJsonArray', () {
    test('extracts a bare array', () {
      expect(extractJsonArray('[1, 2, 3]'), '[1, 2, 3]');
    });

    test('extracts an array from a JSON code fence', () {
      const input = '''
```json
[
  {"id": 1},
  {"id": 2}
]
```
''';
      expect(extractJsonArray(input), '[\n  {"id": 1},\n  {"id": 2}\n]');
    });

    test('extracts an array from a non-JSON code fence', () {
      expect(extractJsonArray('```text\n[true, false]\n```'), '[true, false]');
    });

    test('ignores prose before and after the array', () {
      const input = 'Here is the result:\n[{"ok": true}]\nHope this helps.';
      expect(extractJsonArray(input), '[{"ok": true}]');
    });

    test('stops after the first complete array', () {
      expect(extractJsonArray('first [1] then [2, 3]'), '[1]');
    });

    test('balances nested arrays and objects', () {
      const input = 'prefix [{"items": [1, {"deep": [2, 3]}]}, [4, 5]] suffix';
      expect(
        extractJsonArray(input),
        '[{"items": [1, {"deep": [2, 3]}]}, [4, 5]]',
      );
    });

    test('ignores brackets and braces inside strings', () {
      const input =
          r'prose ["literal ] and }", {"value": "[still quoted]"}] tail';
      expect(
        extractJsonArray(input),
        r'["literal ] and }", {"value": "[still quoted]"}]',
      );
    });

    test('handles escaped quotes and backslashes inside strings', () {
      const input = r'["escaped quote: \" ]", "path: C:\\tmp\\["] after';
      expect(
        extractJsonArray(input),
        r'["escaped quote: \" ]", "path: C:\\tmp\\["]',
      );
    });

    test('preserves balanced malformed JSON for repair', () {
      const input = '''Result:
[
  {"id": 1,}, // model comment
  {"id": 2,},
]
Done.''';
      final extracted = extractJsonArray(input);
      expect(extracted, isNotNull);
      expect(jsonDecode(repairJson(extracted!)), [
        {'id': 1},
        {'id': 2},
      ]);
    });

    test('returns null when there is no array root', () {
      expect(extractJsonArray('prose only {"object": true}'), isNull);
    });

    test('returns null for an unclosed array', () {
      expect(extractJsonArray('before [1, {"x": 2} after'), isNull);
    });

    test('returns null for mismatched nested delimiters', () {
      expect(extractJsonArray('[{"x": 1]]'), isNull);
    });

    test('returns null for an unterminated quoted string', () {
      expect(extractJsonArray('["unfinished ]'), isNull);
    });

    test('returns an empty array', () {
      expect(extractJsonArray('response: []'), '[]');
    });
  });

  group('repairJson', () {
    test('passes through valid JSON unchanged (modulo whitespace)', () {
      const input = '{"a": 1, "b": ["x", "y"]}';
      expect(jsonDecode(repairJson(input)), {'a': 1, 'b': ['x', 'y']});
    });

    test('strips line comments outside strings', () {
      const input = '''
{
  "a": 1, // first comment
  "b": 2 // second comment
}
''';
      final result = jsonDecode(repairJson(input)) as Map<String, dynamic>;
      expect(result['a'], 1);
      expect(result['b'], 2);
      expect(result.length, 2);
    });

    test('strips block comments outside strings', () {
      const input = '''
{
  "a": 1, /* block comment */
  "b": 2
}
''';
      final result = jsonDecode(repairJson(input)) as Map<String, dynamic>;
      expect(result['a'], 1);
      expect(result['b'], 2);
    });

    test('preserves comment-like sequences inside string values', () {
      const input = '{"text": "this // is not a comment, nor /* this */"}';
      final result = jsonDecode(repairJson(input)) as Map<String, dynamic>;
      expect(result['text'], 'this // is not a comment, nor /* this */');
    });

    test('strips ellipsis placeholders outside strings', () {
      const input = '{"items": ["a", ..., "z"]}';
      // Stripping `...` produces `["a", , "z"]` — a malformed array with
      // a missing element. repairJson is a string transform, not a JSON
      // parser; the trailing-comma pass will not rescue a *middle* empty
      // slot. This test asserts the `...` is GONE (the upstream LLM defect
      // is removed) — the caller's jsonDecode is the final authority and
      // the caller should fall back to its non-JSON path when the slot is
      // still malformed. (Marinara's repairJson has the same limitation:
      // it strips `...` tokens but does not collapse missing elements.)
      final repaired = repairJson(input);
      expect(repaired.contains('...'), isFalse);
    });

    test('preserves ellipsis inside string values', () {
      const input = '{"text": "wait... what"}';
      final result = jsonDecode(repairJson(input)) as Map<String, dynamic>;
      expect(result['text'], 'wait... what');
    });

    test('removes trailing comma before closing bracket', () {
      const input = '{"a": [1, 2, 3,]}';
      final result = jsonDecode(repairJson(input)) as Map<String, dynamic>;
      expect(result['a'], [1, 2, 3]);
    });

    test('removes trailing comma before closing brace', () {
      const input = '{"a": 1, "b": 2,}';
      final result = jsonDecode(repairJson(input)) as Map<String, dynamic>;
      expect(result['a'], 1);
      expect(result['b'], 2);
    });

    test('removes trailing comma with whitespace before bracket', () {
      const input = '{"a": [1, 2,\n  3,\n]}';
      final result = jsonDecode(repairJson(input)) as Map<String, dynamic>;
      expect(result['a'], [1, 2, 3]);
    });

    test('preserves a literal ", ]" inside a string value (no corruption)', () {
      // Regression: the trailing-comma pass must be string-aware. A string
      // value that contains a comma followed by whitespace then `]` must NOT
      // have that comma stripped (it would silently mutate the value into
      // valid-but-wrong JSON that jsonDecode accepts).
      const input = '{"rule": "avoid lists like [a, b, ]"}';
      final result = jsonDecode(repairJson(input)) as Map<String, dynamic>;
      expect(result['rule'], 'avoid lists like [a, b, ]');
    });

    test('preserves a literal ", }" inside an embedded-JSON string value', () {
      const input = '{"example": "{\\"x\\": 1, }"}';
      final result = jsonDecode(repairJson(input)) as Map<String, dynamic>;
      expect(result['example'], '{"x": 1, }');
    });

    test('strips real trailing comma but keeps an in-string one in same doc', () {
      const input = '{"rule": "drop a, ]", "items": [1, 2,]}';
      final result = jsonDecode(repairJson(input)) as Map<String, dynamic>;
      expect(result['rule'], 'drop a, ]');
      expect(result['items'], [1, 2]);
    });

    test('handles escaped quotes inside strings correctly', () {
      const input = '{"text": "he said \\"hi\\" // not a comment"}';
      final result = jsonDecode(repairJson(input)) as Map<String, dynamic>;
      expect(result['text'], 'he said "hi" // not a comment');
    });

    test('returns empty string unchanged', () {
      expect(repairJson(''), '');
    });

    test('does not choke on input with no JSON structure', () {
      const input = 'not json at all';
      // repairJson is a string transform; it does not validate JSON.
      // The caller is responsible for catching jsonDecode failures.
      expect(() => repairJson(input), returnsNormally);
    });

    test('combined repair: comments + ellipsis + trailing comma', () {
      const input = '''
{
  // top comment
  "focus": ["a", "b"], /* trailing */
  "constraints": ["c",],
}
''';
      final result = jsonDecode(repairJson(input)) as Map<String, dynamic>;
      expect(result['focus'], ['a', 'b']);
      expect(result['constraints'], ['c']);
    });

    test('does not strip comment-like sequences at the start of a string', () {
      const input = '{"text": "// starts like a comment"}';
      final result = jsonDecode(repairJson(input)) as Map<String, dynamic>;
      expect(result['text'], '// starts like a comment');
    });

    test('preserves nested objects with comments at multiple levels', () {
      const input = '''
{
  "outer": {
    "inner": "value", // inner comment
    "list": [1, 2]
  }
}
''';
      final result = jsonDecode(repairJson(input)) as Map<String, dynamic>;
      final outer = result['outer'] as Map<String, dynamic>;
      expect(outer['inner'], 'value');
      expect(outer['list'], [1, 2]);
    });
  });
}
