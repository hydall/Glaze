import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/context_calculator.dart';
import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/history_trim.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';

/// History of [count] messages, each roughly the same size, ids `m0..mN`.
List<PromptMessage> _history(int count) => [
  for (var i = 0; i < count; i++)
    PromptMessage(
      role: i.isEven ? 'user' : 'assistant',
      content: 'message $i ${'filler ' * 20}',
      sourceMessageId: 'm$i',
      isHistory: true,
    ),
];

ContextCalculator _calculator({
  required String mode,
  String? anchorId,
  bool pinned = false,
  int contextSize = 4000,
  int maxTokens = 1000,
  int triggerPercent = kDefaultHistoryTrimTriggerPercent,
  int stepPercent = kDefaultHistoryTrimStepPercent,
}) => ContextCalculator(
  contextSize: contextSize,
  maxTokens: maxTokens,
  historyTrimMode: mode,
  historyAnchorId: anchorId,
  historyAnchorPinned: pinned,
  historyTrimTriggerPercent: triggerPercent,
  historyTrimStepPercent: stepPercent,
);

/// The fixed part of a prompt — preset, character, lorebooks — worth about
/// [tokens] tokens under the approximate count the tests run with.
List<StaticBlock> _fixed(int tokens) => [
  StaticBlock(id: 'main', content: 'x ' * (tokens * 2)),
];

TokenBreakdown _run(
  ContextCalculator calculator,
  List<PromptMessage> history, {
  List<StaticBlock> fixed = const [],
}) => calculator.calculate(staticBlocks: fixed, historyMessages: history);

void main() {
  group('sliding', () {
    test('keeps as much history as fits and reports no anchor', () {
      final history = _history(80);
      final result = _run(_calculator(mode: HistoryTrimMode.sliding), history);

      expect(result.cutoffIndex, greaterThan(0));
      expect(result.trimmedHistory.length, 80 - result.cutoffIndex);
      expect(result.historyTokens, lessThanOrEqualTo(result.historyBudget));
      expect(
        result.historyAnchorId,
        isNull,
        reason: 'sliding holds nothing still, so there is no anchor to keep',
      );
    });

    test('the cutoff advances as the chat grows', () {
      final first = _run(
        _calculator(mode: HistoryTrimMode.sliding),
        _history(80),
      );
      final later = _run(
        _calculator(mode: HistoryTrimMode.sliding),
        _history(90),
      );

      // The prefix moves every turn — this is exactly what costs the cache.
      expect(later.cutoffIndex, greaterThan(first.cutoffIndex));
    });
  });

  group('stepped', () {
    test('re-anchors with headroom, so it keeps less than sliding would', () {
      final history = _history(80);
      final sliding = _run(_calculator(mode: HistoryTrimMode.sliding), history);
      final stepped = _run(_calculator(mode: HistoryTrimMode.stepped), history);

      expect(stepped.cutoffIndex, greaterThan(sliding.cutoffIndex));
      expect(
        stepped.historyTokens,
        lessThan(sliding.historyTokens),
        reason: 'the spare budget is the headroom the next turns grow into',
      );
      expect(stepped.historyAnchorId, 'm${stepped.cutoffIndex}');
    });

    test(
      'an anchor that still fits holds the prefix still as the chat grows',
      () {
        final first = _run(
          _calculator(mode: HistoryTrimMode.stepped),
          _history(80),
        );
        final anchor = first.historyAnchorId!;

        // Four more turns land; the anchored window still fits, so the request
        // still starts at the same message and the provider's cache can hit.
        final later = _run(
          _calculator(mode: HistoryTrimMode.stepped, anchorId: anchor),
          _history(84),
        );

        expect(later.historyAnchorId, anchor);
        expect(later.trimmedHistory.first.sourceMessageId, anchor);
      },
    );

    test('the anchor moves once the window it opens stops fitting', () {
      final history = _history(200);
      final stale = _run(
        _calculator(mode: HistoryTrimMode.stepped, anchorId: 'm0'),
        history,
      );

      expect(stale.historyAnchorId, isNot('m0'));
      expect(stale.historyTokens, lessThanOrEqualTo(stale.historyBudget));
    });

    test('raising max output tokens re-anchors instead of overflowing', () {
      final history = _history(120);
      final roomy = _run(_calculator(mode: HistoryTrimMode.stepped), history);
      final anchor = roomy.historyAnchorId!;

      // Same chat, same anchor, but the completion budget just doubled — the
      // history budget shrinks by exactly that much.
      final tight = _run(
        _calculator(
          mode: HistoryTrimMode.stepped,
          anchorId: anchor,
          maxTokens: 2500,
        ),
        history,
      );

      expect(tight.historyAnchorId, isNot(anchor));
      expect(tight.historyTokens, lessThanOrEqualTo(tight.historyBudget));
      expect(
        tight.totalTokens + 2500,
        lessThanOrEqualTo(4000),
        reason: 'the prompt must still leave the completion its full budget',
      );
    });

    test('an anchor whose message is gone is replaced, not trusted', () {
      final result = _run(
        _calculator(mode: HistoryTrimMode.stepped, anchorId: 'deleted-message'),
        _history(80),
      );

      expect(result.historyAnchorId, isNotNull);
      expect(result.historyAnchorId, isNot('deleted-message'));
      expect(result.historyTokens, lessThanOrEqualTo(result.historyBudget));
    });

    test('never keeps less history than the budget allows for one message', () {
      // One message far larger than the reduced refill target: the stepped
      // walk would come back empty, so it must fall back to the full budget.
      final huge = [
        PromptMessage(
          role: 'user',
          content: 'x ' * 5000,
          sourceMessageId: 'big',
          isHistory: true,
        ),
      ];
      final budget = ContextCalculator(
        contextSize: 4000,
        maxTokens: 1000,
      ).safeContext;
      // The trigger line is the whole budget here (85 % of 4000 is past it),
      // and a step frees 30 % of the context window.
      final target = budget - (4000 * kDefaultHistoryTrimStepPercent / 100);
      expect(
        estimateTokens(huge.single.content),
        allOf(greaterThan(target), lessThanOrEqualTo(budget)),
        reason: 'the fixture must sit between the refill target and the budget',
      );

      final result = _run(_calculator(mode: HistoryTrimMode.stepped), huge);
      expect(result.trimmedHistory, hasLength(1));
      expect(result.cutoffIndex, 0);
    });

    test('the trigger and the step are shares of the context window', () {
      // 4000 of context, 1000 reserved for the reply: the trigger line (85 %
      // = 3400) is capped at the 3000 the reply leaves. A fixed part of 1500
      // leaves the history 1500 of room under the line; a step of 30 % of the
      // window (1200) is more than half of that room, so a jump frees half
      // the room — 750 — rather than cutting the history to 300.
      final history = _history(200);
      final result = _run(
        _calculator(mode: HistoryTrimMode.stepped),
        history,
        fixed: _fixed(1500),
      );
      expect(result.historyBudget, 1500);
      expect(result.historyTokens, lessThanOrEqualTo(750));
      expect(
        result.historyTokens,
        greaterThan(600),
        reason: 'half the room, less at most one message',
      );

      // The same prompt with no fixed part: a jump frees 1200 of the 3000 the
      // history may have, leaving 1800 — the step is the same number of
      // tokens whatever the fixed part takes.
      final roomy = _run(_calculator(mode: HistoryTrimMode.stepped), history);
      expect(roomy.historyTokens, lessThanOrEqualTo(1800));
      expect(roomy.historyTokens, greaterThan(1650));
    });

    test(
      'a trigger below the fixed part holds nothing: what fits, every turn',
      () {
        // A 50 % trigger (2000) under a fixed part of 2500: no window can sit
        // under the line, so the history is cut to what fits, like sliding.
        final first = _run(
          _calculator(mode: HistoryTrimMode.stepped, triggerPercent: 50),
          _history(120),
          fixed: _fixed(2500),
        );
        expect(first.historyTokens, lessThanOrEqualTo(first.historyBudget));
        expect(first.historyTokens, greaterThan(0));
        final later = _run(
          _calculator(
            mode: HistoryTrimMode.stepped,
            triggerPercent: 50,
            anchorId: first.historyAnchorId,
          ),
          _history(122),
          fixed: _fixed(2500),
        );
        expect(later.historyAnchorId, isNot(first.historyAnchorId));
        expect(later.historyTokens, lessThanOrEqualTo(later.historyBudget));
      },
    );

    test('a turn whose fixed part swells cuts deep; once it shrinks back, the '
        'anchor moves back to the refill level', () {
      final history = _history(200);
      final settled = _run(_calculator(mode: HistoryTrimMode.stepped), history);
      final anchor = settled.historyAnchorId!;

      // A turn with 2400 more of lorebook: 600 of room, a step frees half
      // of it, and the window is cut to a handful of messages.
      final spike = _run(
        _calculator(mode: HistoryTrimMode.stepped, anchorId: anchor),
        history,
        fixed: _fixed(2400),
      );
      expect(spike.historyTokens, lessThanOrEqualTo(300));
      final deep = spike.historyAnchorId!;
      expect(spike.cutoffIndex, greaterThan(settled.cutoffIndex));

      // The lorebook is gone again. The window the deep anchor opens is far
      // under the 1800 a step would have left, so the anchor moves back to
      // it instead of holding the cut for the rest of the chat.
      final recovered = _run(
        _calculator(mode: HistoryTrimMode.stepped, anchorId: deep),
        history,
      );
      expect(recovered.cutoffIndex, lessThan(spike.cutoffIndex));
      expect(recovered.historyTokens, lessThanOrEqualTo(1800));
      expect(
        recovered.historyTokens,
        greaterThan(1800 - 4000 * kHistoryAnchorRefillSlackPercent / 100),
      );
      expect(recovered.historyAnchorPinned, isFalse);
    });

    test('a window a few per cent under the refill level holds still', () {
      final history = _history(200);
      final settled = _run(
        _calculator(mode: HistoryTrimMode.stepped),
        history,
        fixed: _fixed(100),
      );
      final anchor = settled.historyAnchorId!;
      // The fixed part shrank by 100 tokens (2.5 % of the window): well
      // within the slack, so the start — and the cache — hold.
      final later = _run(
        _calculator(mode: HistoryTrimMode.stepped, anchorId: anchor),
        history,
      );
      expect(later.historyAnchorId, anchor);
    });

    test('a pinned anchor holds where the reader put it', () {
      final history = _history(200);
      // Far under the refill level — an unpinned anchor would move back.
      final pinnedOn = history[190].sourceMessageId!;
      final held = _run(
        _calculator(
          mode: HistoryTrimMode.stepped,
          anchorId: pinnedOn,
          pinned: true,
        ),
        history,
      );
      expect(held.historyAnchorId, pinnedOn);
      expect(held.historyAnchorPinned, isTrue);
      expect(held.trimmedHistory.first.sourceMessageId, pinnedOn);

      final unpinned = _run(
        _calculator(mode: HistoryTrimMode.stepped, anchorId: pinnedOn),
        history,
      );
      expect(unpinned.historyAnchorId, isNot(pinnedOn));
      expect(unpinned.historyAnchorPinned, isFalse);
    });

    test('a pin steps once its window stops fitting, and the pin goes', () {
      final history = _history(200);
      final result = _run(
        _calculator(
          mode: HistoryTrimMode.stepped,
          anchorId: 'm0',
          pinned: true,
        ),
        history,
      );
      expect(result.historyAnchorId, isNot('m0'));
      expect(result.historyAnchorPinned, isFalse);
      expect(result.historyTokens, lessThanOrEqualTo(result.historyBudget));
    });

    test('the pin survives a round trip through the breakdown payload', () {
      final history = _history(40);
      final result = _run(
        _calculator(
          mode: HistoryTrimMode.stepped,
          anchorId: 'm10',
          pinned: true,
        ),
        history,
      );
      expect(result.historyAnchorPinned, isTrue);
      final copy = TokenBreakdown.fromJson(result.toJson());
      expect(copy.historyAnchorId, 'm10');
      expect(copy.historyAnchorPinned, isTrue);
      expect(copy.withVectorLore(50).historyAnchorPinned, isTrue);
      expect(copy.copyWithVisible(const {}).historyAnchorPinned, isTrue);
    });
  });
}
