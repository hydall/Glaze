import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/game_time.dart';
import 'package:glaze_flutter/core/llm/memory_selector.dart';
import 'package:glaze_flutter/core/llm/prompt/memory_context_resolver.dart';
import 'package:glaze_flutter/core/llm/prompt/recalled_message_chunk.dart';
import 'package:glaze_flutter/core/llm/prompt/recalled_messages_resolver.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';

void main() {
  MemoryContextResolution resolve(
    List<MemoryEntry> entries, {
    int? budget,
    String mode = 'full',
    GameTimeState clock = const GameTimeState(day: 37),
  }) => const MemoryContextResolver().resolve(
    selection: MemorySelection(
      entries: entries,
      allScores: [
        for (final entry in entries)
          MemoryCandidateScore(entry: entry, score: 1),
      ],
      budgetTokens: budget,
      entryCap: entries.length,
    ),
    visibleMessageIds: const {},
    disableSourceWindowExclusion: false,
    excerptingEnabled: mode != 'full',
    packingMode: mode,
    excerptTokensPerChunk: 500,
    excerptChunksPerEntry: 2,
    chunkFirstTopEntries: 3,
    chunkFirstTopChunks: 1,
    gameTime: clock,
  );

  test(
    'historical states retain distinct times and a shared partial current clock',
    () {
      final result = resolve(const [
        MemoryEntry(
          id: 'alive',
          content: 'Mara is alive.',
          ledgerRange: 'day 12',
        ),
        MemoryEntry(
          id: 'loss',
          content: 'Her signet is found.',
          ledgerRange: 'day 36',
        ),
      ]);
      for (final text in [
        result.content!.hardBlockContent,
        result.content!.macroContent,
      ]) {
        expect('Current story point:'.allMatches(text), hasLength(1));
        expect(text, contains('day 37'));
        expect(text, contains('Occurred: day 12\nMara is alive.'));
        expect(text, contains('Occurred: day 36'));
        expect(
          text,
          contains(
            'Current Ledger canon and Character Knowledge take precedence',
          ),
        );
        expect(text, isNot(contains('2026')));
      }
    },
  );

  for (final mode in ['full', 'hybrid', 'chunk_first']) {
    test(
      '$mode never admits an oversized first entry or free temporal headers',
      () {
        final entry = MemoryEntry(
          id: 'large',
          content: List.filled(1000, 'Mara recalls the old camp.').join(' '),
        );
        final result = resolve([entry], budget: 180, mode: mode);
        expect(result.excerptSelection.totalTokens, lessThanOrEqualTo(180));
        expect(result.excerptSelection.budgetTrimmed, isTrue);
        if (result.content case final content?) {
          expect(
            estimateTokens(content.hardBlockContent),
            result.excerptSelection.totalTokens,
          );
          expect(estimateTokens(content.macroContent), lessThanOrEqualTo(180));
        }
        final impossible = resolve([entry], budget: 1, mode: mode);
        expect(impossible.content, isNull);
        expect(impossible.triggeredEntries, isEmpty);
      },
    );
  }

  test('expanded clock macros are counted in the final memory budget', () {
    final result = resolve(
      const [
        MemoryEntry(id: 'macro', content: 'Clock: {{gameday}} / {{gametime}}'),
      ],
      budget: 500,
      clock: const GameTimeState(day: 37, time: '21:10'),
    );
    expect(result.content!.hardBlockContent, contains('Clock: 37 / 21:10'));
    expect(
      result.excerptSelection.totalTokens,
      estimateTokens(result.content!.hardBlockContent),
    );
  });

  test(
    'raw recall carries source time through serialization without changing claims',
    () {
      final chunk = RecalledMessageChunk.fromJson(
        const RecalledMessageChunk(
          text: 'Mara: I believe the gate is safe.',
          messageIds: ['m1'],
          ledgerRange: 'day 12',
        ).toJson(),
      );
      final text = const RecalledMessagesResolver().resolve(
        chunks: [chunk],
        visibleMessageIds: {},
        gameTime: const GameTimeState(day: 37),
      );
      expect(
        text,
        contains('Occurred: day 12\nMara: I believe the gate is safe.'),
      );
      expect(text, contains('not necessarily objective truth'));
    },
  );
}
