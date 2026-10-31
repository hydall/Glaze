import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/history_assembler.dart';
import 'package:glaze_flutter/core/llm/prompt/summary_in_place.dart';
import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/summary_block.dart';

/// A summary in `in_place` mode goes into the history where the messages it
/// covers were — one message per unbroken run of blocks, in story order —
/// instead of at a fixed spot in the preset. See `docs/INVARIANTS.md` INV-S6.
void main() {
  final messages = [
    for (var i = 1; i <= 8; i++)
      ChatMessage(
        id: 'm$i',
        role: i.isOdd ? 'user' : 'assistant',
        content: 'Message $i',
      ),
  ];
  final byId = SummaryChain.index(messages);

  SummaryBlock block(String id, List<String> ids, {int level = 1}) =>
      SummaryBlock(
        id: id,
        level: level,
        content: 'Summary of ${ids.join(', ')}.',
        messageIds: ids,
        sourceHash: SummaryChain.fingerprint(ids, byId),
        createdAt: 1,
      );

  group('segments', () {
    test('adjacent blocks make one run, before the first fresh message', () {
      final view = SummaryChain.promptView([
        block('b1', ['m1', 'm2']),
        block('b2', ['m3', 'm4']),
      ], messages);

      expect(view.segments, hasLength(1));
      expect(view.segments.single.beforeMessageId, 'm5');
      expect(view.segments.single.content, view.content);
    });

    test('a message the prompt carries between blocks cuts the run', () {
      final view = SummaryChain.promptView([
        block('b1', ['m1', 'm2']),
        block('b2', ['m4', 'm5']),
      ], messages);

      expect(view.segments.map((s) => s.beforeMessageId), ['m3', 'm6']);
      expect(view.segments.first.content, 'Summary of m1, m2.');
      expect(view.segments.last.content, 'Summary of m4, m5.');
    });

    test('a hidden message between blocks does not cut the run', () {
      final withHidden = [
        ...messages.take(2),
        messages[2].copyWith(isHidden: true),
        ...messages.skip(3),
      ];
      final hiddenIndex = SummaryChain.index(withHidden);
      SummaryBlock over(String id, List<String> ids) => SummaryBlock(
        id: id,
        level: 1,
        content: id,
        messageIds: ids,
        sourceHash: SummaryChain.fingerprint(ids, hiddenIndex),
      );

      final view = SummaryChain.promptView([
        over('b1', ['m1', 'm2']),
        over('b2', ['m4', 'm5']),
      ], withHidden);

      expect(view.segments, hasLength(1));
      expect(view.segments.single.beforeMessageId, 'm6');
    });

    test('a picture between blocks stays between them', () {
      final withPicture = [
        ...messages.take(2),
        messages[2].copyWith(content: '', imagePath: 'a.png'),
        ...messages.skip(3),
      ];
      final pictureIndex = SummaryChain.index(withPicture);
      SummaryBlock over(String id, List<String> ids) => SummaryBlock(
        id: id,
        level: 1,
        content: id,
        messageIds: ids,
        sourceHash: SummaryChain.fingerprint(ids, pictureIndex),
      );

      final view = SummaryChain.promptView([
        over('b1', ['m1', 'm2']),
        over('b2', ['m4', 'm5']),
      ], withPicture);

      expect(view.segments.map((s) => s.beforeMessageId), ['m3', 'm6']);
    });

    test('a stale block in the middle gives its messages back in place', () {
      final stale = SummaryBlock(
        id: 'b2',
        level: 1,
        content: 'Old retelling',
        messageIds: const ['m3', 'm4'],
        sourceHash: 'outdated',
      );

      final view = SummaryChain.promptView([
        block('b1', ['m1', 'm2']),
        stale,
        block('b3', ['m5', 'm6']),
      ], messages);

      expect(view.segments.map((s) => s.beforeMessageId), ['m3', 'm7']);
    });

    test('a merge stands in for its parts', () {
      final parts = [
        block('b1', ['m1', 'm2']).copyWith(archived: true),
        block('b2', ['m3', 'm4']).copyWith(archived: true),
      ];
      final merged = SummaryBlock(
        id: 'b12',
        level: 2,
        content: 'Merged.',
        messageIds: const ['m1', 'm2', 'm3', 'm4'],
        sourceHash: SummaryChain.fingerprint(const [
          'm1',
          'm2',
          'm3',
          'm4',
        ], byId),
        childIds: const ['b1', 'b2'],
      );

      final view = SummaryChain.promptView([...parts, merged], messages);

      expect(view.segments.single.content, 'Merged.');
      expect(view.segments.single.beforeMessageId, 'm5');
    });

    test('a reader note is not in any run', () {
      const note = SummaryBlock(id: 'n', level: 0, content: 'Note.');

      final view = SummaryChain.promptView([
        note,
        block('b1', ['m1', 'm2']),
      ], messages);

      expect(view.segments.single.content, 'Summary of m1, m2.');
      expect(view.segments.single.beforeMessageId, 'm3');
    });

    test('notes alone put nothing in the prompt', () {
      const note = SummaryBlock(id: 'n', level: 0, content: 'Note.');

      final view = SummaryChain.promptView([note], messages);

      expect(view.content, isEmpty);
      expect(view.segments, isEmpty);
    });

    test('segments survive the trip to the prompt isolate', () {
      const segments = [
        SummarySegment(content: 'One', beforeMessageId: 'm3'),
        SummarySegment(content: 'Two'),
      ];

      final decoded = SummarySegment.decodeList(
        SummarySegment.encodeList(segments),
      );

      expect(decoded.map((s) => s.content), ['One', 'Two']);
      expect(decoded.map((s) => s.beforeMessageId), ['m3', null]);
    });
  });

  group('placement', () {
    PromptMessage history(String id) => PromptMessage(
      role: 'user',
      content: id,
      isHistory: true,
      sourceMessageId: id,
    );
    InPlaceSummaryMessage summary(String content, String? before) => (
      message: PromptMessage(
        role: 'system',
        content: content,
        blockId: 'summary',
      ),
      beforeMessageId: before,
    );

    test('each run goes right before its anchor, in story order', () {
      final list = [
        const PromptMessage(role: 'system', content: 'Main'),
        history('m3'),
        history('m4'),
        history('m6'),
      ];

      placeInPlaceSummary(list, [summary('A', 'm3'), summary('B', 'm6')]);

      expect(list.map((m) => m.content), ['Main', 'A', 'm3', 'm4', 'B', 'm6']);
    });

    test('a run with no anchor goes after the last history message', () {
      final list = [
        history('m1'),
        const PromptMessage(role: 'system', content: 'After'),
      ];

      placeInPlaceSummary(list, [summary('A', null)]);

      expect(list.map((m) => m.content), ['m1', 'A', 'After']);
    });

    test('a run whose anchor is gone follows the run before it', () {
      final list = [history('m3'), history('m4')];

      placeInPlaceSummary(list, [summary('A', 'm3'), summary('B', 'gone')]);

      expect(list.map((m) => m.content), ['A', 'B', 'm3', 'm4']);
    });
  });

  group('prompt', () {
    PromptPayload payload({
      required String insertionMode,
      required List<ChatMessage> history,
      List<SummarySegment> segments = const [],
      String summary = 'Summary of m1, m2.',
      int contextSize = 100000,
    }) => PromptPayload(
      character: const Character(id: 'c1', name: 'Alice'),
      preset: Preset(
        id: 'p1',
        name: 'Preset',
        blocks: [
          const PresetBlock(
            id: 'main',
            name: 'Main',
            role: 'system',
            content: 'Main prompt',
          ),
          PresetBlock(
            id: 'summary',
            name: 'Summary',
            role: 'system',
            content: '',
            depth: 1,
            insertionMode: insertionMode,
            prefix: 'Summary: ',
          ),
          const PresetBlock(
            id: 'chat_history',
            name: 'History',
            role: 'system',
            content: '',
          ),
        ],
      ),
      history: history,
      summaryContent: summary,
      summarySegments: segments,
      apiConfig: ApiConfig(id: 'api', contextSize: contextSize, maxTokens: 100),
    );

    List<String> contents(PromptPayload p) =>
        buildPrompt(p).messages.map((m) => m.content).toList();

    test('the summary sits where its messages were', () {
      final result = contents(
        payload(
          insertionMode: summaryInPlaceInsertion,
          history: messages.sublist(2, 5),
          segments: const [
            SummarySegment(
              content: 'Summary of m1, m2.',
              beforeMessageId: 'm3',
            ),
          ],
        ),
      );

      expect(result, [
        'Main prompt',
        '[Summary: Summary of m1, m2.]',
        'Message 3',
        'Message 4',
        'Message 5',
      ]);
    });

    test('runs split by a carried message keep the story order', () {
      final result = contents(
        payload(
          insertionMode: summaryInPlaceInsertion,
          summary: 'A\n\nB',
          history: [messages[2], messages[5], messages[6]],
          segments: const [
            SummarySegment(content: 'A', beforeMessageId: 'm3'),
            SummarySegment(content: 'B', beforeMessageId: 'm6'),
          ],
        ),
      );

      expect(result, [
        'Main prompt',
        '[Summary: A]',
        'Message 3',
        '[Summary: B]',
        'Message 6',
        'Message 7',
      ]);
    });

    test('without segments the whole summary opens the history', () {
      final result = contents(
        payload(
          insertionMode: summaryInPlaceInsertion,
          history: messages.sublist(2, 4),
        ),
      );

      expect(result, [
        'Main prompt',
        '[Summary: Summary of m1, m2.]',
        'Message 3',
        'Message 4',
      ]);
    });

    test('trimming the history never drops the summary', () {
      final long = [
        for (var i = 3; i <= 8; i++)
          ChatMessage(
            id: 'm$i',
            role: i.isOdd ? 'user' : 'assistant',
            content: List.filled(150, 'word $i').join(' '),
          ),
      ];

      final result = buildPrompt(
        payload(
          insertionMode: summaryInPlaceInsertion,
          history: long,
          contextSize: 1500,
          segments: const [
            SummarySegment(
              content: 'Summary of m1, m2.',
              beforeMessageId: 'm3',
            ),
          ],
        ),
      );
      final sent = result.messages.map((m) => m.content).toList();

      // The oldest raw messages are cut; the summary keeps its place in
      // front of the ones left.
      expect(result.breakdown.cutoffIndex, greaterThan(0));
      expect(sent.length, lessThan(2 + long.length));
      expect(sent.take(2), ['Main prompt', '[Summary: Summary of m1, m2.]']);
      expect(sent.last, long.last.content);
    });

    test('the summary is counted on its own row', () {
      final result = buildPrompt(
        payload(
          insertionMode: summaryInPlaceInsertion,
          history: messages.sublist(2, 4),
        ),
      );

      expect(result.breakdown.sourceTokens['summary'], greaterThan(0));
    });

    test('depth mode still places the whole summary by depth', () {
      final result = contents(
        payload(insertionMode: 'depth', history: messages.sublist(2, 4)),
      );

      expect(result, [
        'Main prompt',
        'Message 3',
        '[Summary: Summary of m1, m2.]',
        'Message 4',
      ]);
    });
  });
}
