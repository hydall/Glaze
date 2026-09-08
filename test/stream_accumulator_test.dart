import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/stream_accumulator.dart';

void main() {
  group('StreamAccumulator', () {
    test('preserves behavior without inline reasoning', () {
      final accumulator = StreamAccumulator(hasInlineTags: false);

      accumulator.consumeDelta(' visible', reasoningDelta: ' model ');
      accumulator.consumeDelta(' text', reasoningDelta: 'thought');

      expect(accumulator.text, ' visible text');
      expect(accumulator.reasoning, 'model thought');
      expect(accumulator.raw, isEmpty);
      expect(accumulator.hasExternalReasoning, isTrue);
      expect(accumulator.splitDone, isFalse);
    });

    test('combines external and inline reasoning with headers', () {
      final accumulator = _createAccumulator(
        headerModel: 'Model',
        headerInline: 'Inline',
      );

      accumulator.consumeDelta(
        '<think> inline </think>answer',
        reasoningDelta: ' external ',
      );

      expect(accumulator.text, 'answer');
      expect(accumulator.reasoning, 'Model\nexternal\n\n---\n\nInline\ninline');
      expect(accumulator.hasExternalReasoning, isTrue);
      expect(accumulator.splitDone, isTrue);
    });

    test('reset clears parser candidates and all accumulated state', () {
      final accumulator = _createAccumulator();
      accumulator.consumeDelta('before<thi', reasoningDelta: 'external');

      accumulator.reset();

      expect(_snapshot(accumulator), ('', '', '', false, false));
      accumulator.consumeDelta('<think>new</think>answer');
      expect(_snapshot(accumulator), (
        'answer',
        'new',
        '<think>new</think>answer',
        false,
        true,
      ));
    });

    test('flush remains a no-op for unterminated input', () {
      final accumulator = _createAccumulator();
      accumulator.consumeDelta('  lead<think>unfinished');
      final before = _snapshot(accumulator);

      accumulator.flush();

      expect(_snapshot(accumulator), before);
      expect(accumulator.text, 'lead');
      expect(accumulator.reasoning, 'unfinished');
      expect(accumulator.splitDone, isFalse);
    });

    final cases = <_Case>[
      const _Case('plain text', 'plain text', '', false),
      const _Case('  plain text', '  plain text', '', false),
      const _Case('<think>reason</think>answer', 'answer', 'reason', true),
      const _Case(
        '  lead <think> reason </think> answer ',
        'lead  answer ',
        'reason',
        true,
      ),
      const _Case('lead<think>unfinished', 'lead', 'unfinished', false),
      const _Case('lead</think>tail', 'lead</think>tail', '', false),
      const _Case(
        'a<think>one</think>b<think>two</think>c',
        'ab<think>two</think>c',
        'one',
        true,
      ),
      const _Case(
        '<thinking mode="deep">reason</thinking extra>answer',
        'answer',
        'reason',
        true,
        raw: '<think>reason</think>answer',
      ),
      const _Case(
        'x<THINKING>reason</THINKING>y',
        'xy',
        'reason',
        true,
        raw: 'x<think>reason</think>y',
      ),
      const _Case(
        '<thinkingBroken>visible',
        '<thinkingBroken>visible',
        '',
        false,
      ),
      const _Case(
        '<thinking attr="unterminated"',
        '<thinking attr="unterminated"',
        '',
        false,
      ),
    ];

    for (final entry in cases) {
      test('matches expected semantics and every split: ${entry.input}', () {
        final oneShot = _createAccumulator()..consumeDelta(entry.input);
        expect(oneShot.text, entry.text);
        expect(oneShot.reasoning, entry.reasoning);
        expect(oneShot.raw, entry.raw ?? entry.input);
        expect(oneShot.splitDone, entry.splitDone);

        for (var split = 0; split <= entry.input.length; split++) {
          final chunked = _createAccumulator();
          chunked.consumeDelta(entry.input.substring(0, split));
          chunked.consumeDelta(entry.input.substring(split));
          expect(
            _snapshot(chunked),
            _snapshot(oneShot),
            reason: 'split at $split',
          );
        }

        final characterChunks = _createAccumulator();
        for (var end = 1; end <= entry.input.length; end++) {
          characterChunks.consumeDelta(entry.input.substring(end - 1, end));
          final prefix = _createAccumulator()
            ..consumeDelta(entry.input.substring(0, end));
          expect(
            _snapshot(characterChunks),
            _snapshot(prefix),
            reason: 'prefix ending at $end',
          );
        }
      });
    }

    test('supports configured tags across every boundary', () {
      const input = ' pre [[reason]]inside[[/reason]] post';
      final expected = StreamAccumulator(
        tagStart: '[[reason]]',
        tagEnd: '[[/reason]]',
        hasInlineTags: true,
      )..consumeDelta(input);
      expect(expected.text, 'pre  post');
      expect(expected.reasoning, 'inside');

      for (var split = 0; split <= input.length; split++) {
        final chunked = StreamAccumulator(
          tagStart: '[[reason]]',
          tagEnd: '[[/reason]]',
          hasInlineTags: true,
        );
        chunked.consumeDelta(input.substring(0, split));
        chunked.consumeDelta(input.substring(split));
        expect(_snapshot(chunked), _snapshot(expected), reason: 'split $split');
      }
    });

    test('normalizes think variants in both configured directions', () {
      final accumulator = StreamAccumulator(
        tagStart: '<thinking>',
        tagEnd: '</thinking>',
        hasInlineTags: true,
      )..consumeDelta('<think class=x>reason</think data-x>answer');

      expect(accumulator.text, 'answer');
      expect(accumulator.reasoning, 'reason');
      expect(accumulator.raw, '<thinking>reason</thinking>answer');
    });

    test('keeps configured tag matching case-sensitive', () {
      final accumulator = _createAccumulator()
        ..consumeDelta('<THINK>visible</THINK>');

      expect(accumulator.text, '<THINK>visible</THINK>');
      expect(accumulator.reasoning, isEmpty);
      expect(accumulator.splitDone, isFalse);
    });

    test('requires both configured tags before enabling inline parsing', () {
      final accumulator = StreamAccumulator(
        tagStart: '<think>',
        hasInlineTags: true,
      )..consumeDelta('<think>visible', reasoningDelta: 'external');

      expect(accumulator.text, '<think>visible');
      expect(accumulator.reasoning, 'external');
      expect(accumulator.raw, isEmpty);
      expect(accumulator.splitDone, isFalse);
    });

    test('preserves empty configured tag behavior', () {
      final emptyEnd = StreamAccumulator(
        tagStart: '<think>',
        tagEnd: '',
        hasInlineTags: true,
      )..consumeDelta('  pre<think>post');
      expect(emptyEnd.text, 'prepost');
      expect(emptyEnd.reasoning, isEmpty);
      expect(emptyEnd.splitDone, isTrue);

      final emptyStart = StreamAccumulator(
        tagStart: '',
        tagEnd: '</think>',
        hasInlineTags: true,
      )..consumeDelta('reason</think> answer');
      expect(emptyStart.text, 'answer');
      expect(emptyStart.reasoning, 'reason');
      expect(emptyStart.splitDone, isTrue);
    });
  });
}

StreamAccumulator _createAccumulator({
  String? headerModel,
  String? headerInline,
}) => StreamAccumulator(
  tagStart: '<think>',
  tagEnd: '</think>',
  hasInlineTags: true,
  headerModel: headerModel,
  headerInline: headerInline,
);

(String, String, String, bool, bool) _snapshot(StreamAccumulator accumulator) =>
    (
      accumulator.text,
      accumulator.reasoning,
      accumulator.raw,
      accumulator.hasExternalReasoning,
      accumulator.splitDone,
    );

class _Case {
  final String input;
  final String text;
  final String reasoning;
  final bool splitDone;
  final String? raw;

  const _Case(
    this.input,
    this.text,
    this.reasoning,
    this.splitDone, {
    this.raw,
  });
}
