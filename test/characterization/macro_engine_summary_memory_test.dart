import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/macro_engine.dart';

/// Characterization test for the {{summary}} / {{memory}} split
/// (introduced to fix the visual duplicate in the tokenizer, where
/// memory injected through `summary_block` target was piggybacking on
/// the `{{summary}}` expansion and showing up twice in the UI).
///
/// After the split:
/// * `{{summary}}` resolves to `MacroContext.summaryContent` ONLY.
/// * `{{memory}}` resolves to `MacroContext.memoryContent` ONLY.
/// * `summaryContent` and `memoryContent` are independent.
void main() {
  MacroContext ctx({
    String? summary,
    String? memory,
  }) =>
      MacroContext(
        charName: 'Alice',
        charId: 'c1',
        sessionId: 's1',
        summaryContent: summary,
        memoryContent: memory,
      );

  group('{{summary}} resolution', () {
    test('returns summary content when both summary and memory present', () {
      final result = replaceMacros('Summary: {{summary}}', ctx(
        summary: 'hello world',
        memory: 'memory bytes',
      ));
      expect(result.text, 'Summary: hello world');
    });

    test('returns empty string when summary is null', () {
      final result = replaceMacros('S:{{summary}}E', ctx(memory: 'm'));
      expect(result.text, 'S:E');
    });

    test('does NOT append memory to summary (no piggyback)', () {
      // The old behaviour would resolve {{summary}} when memory was
      // present even if summary was null, falling back to memory content.
      // This is the very behaviour that caused the double-count in the
      // tokenizer UI.
      final result = replaceMacros('{{summary}}', ctx(memory: 'mem'));
      expect(result.text, isEmpty,
          reason: '{{summary}} must NOT include memory content');
    });
  });

  group('{{memory}} resolution', () {
    test('returns memory content when present', () {
      final result = replaceMacros('Memory: {{memory}}', ctx(memory: 'mem text'));
      expect(result.text, 'Memory: mem text');
    });

    test('returns empty string when memory is null', () {
      final result = replaceMacros('M:{{memory}}E', ctx(summary: 's'));
      expect(result.text, 'M:E');
    });

    test('independent of summary content', () {
      final result = replaceMacros('{{memory}}', ctx(
        summary: 'summary text',
        memory: 'memory text',
      ));
      expect(result.text, 'memory text',
          reason: '{{memory}} must NOT include summary content');
    });
  });

  group('independent substitution', () {
    test('both {{summary}} and {{memory}} expand in same text', () {
      final result = replaceMacros(
        'S={{summary}} M={{memory}}',
        ctx(summary: 'sum', memory: 'mem'),
      );
      expect(result.text, 'S=sum M=mem');
    });

    test('tokens do not leak between {{summary}} and {{memory}}', () {
      // Replaces only summary, not memory. And vice versa.
      final result1 = replaceMacros('{{summary}}', ctx(summary: 'a', memory: 'b'));
      final result2 = replaceMacros('{{memory}}', ctx(summary: 'a', memory: 'b'));
      expect(result1.text, 'a');
      expect(result2.text, 'b');
    });
  });

  group('case insensitivity (matches existing macro behaviour)', () {
    test('{{SUMMARY}} resolves to summary content', () {
      final result = replaceMacros('{{SUMMARY}}', ctx(summary: 'X'));
      expect(result.text, 'X');
    });

    test('{{Memory}} resolves to memory content', () {
      final result = replaceMacros('{{Memory}}', ctx(memory: 'Y'));
      expect(result.text, 'Y');
    });
  });
}
