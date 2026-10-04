import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/memory_selector.dart';
import 'package:glaze_flutter/core/llm/prompt/memory_context_resolver.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';

void main() {
  const resolver = MemoryContextResolver();

  test('refilters source-window entries before formatting and diagnostics', () {
    const visibleEntry = MemoryEntry(
      id: 'visible',
      title: 'Visible memory',
      content: 'Already represented in visible history.',
      messageIds: ['message-1'],
    );
    const retainedEntry = MemoryEntry(
      id: 'retained',
      title: 'Older memory',
      content: 'A retained fact from an older scene.',
      messageIds: ['message-2'],
    );
    const selection = MemorySelection(
      entries: [visibleEntry, retainedEntry],
      allScores: [
        MemoryCandidateScore(entry: visibleEntry, score: 2),
        MemoryCandidateScore(entry: retainedEntry, score: 1),
      ],
      entryCap: 2,
    );

    final result = resolver.resolve(
      selection: selection,
      visibleMessageIds: const {'message-1'},
      disableSourceWindowExclusion: false,
      excerptingEnabled: false,
      packingMode: 'full',
      excerptTokensPerChunk: 500,
      excerptChunksPerEntry: 2,
      chunkFirstTopEntries: 3,
      chunkFirstTopChunks: 1,
      summaryExcerpt: 'Current summary.',
    );

    expect(result.selection.entries.map((entry) => entry.id), ['retained']);
    expect(result.excerptSelection.entries.map((entry) => entry.id), [
      'retained',
    ]);
    expect(result.content?.hardBlockContent, contains('Current summary.'));
    expect(result.content?.hardBlockContent, contains('Older memory'));
    expect(result.content?.hardBlockContent, isNot(contains('Visible memory')));
    expect(result.content?.macroContent, isNot(contains('Current summary.')));
    expect(result.triggeredEntries.single.id, 'retained');
  });

  test('source-window bypass retains overlapping entries', () {
    const entry = MemoryEntry(
      id: 'memory',
      title: 'Memory',
      content: 'Retained content.',
      messageIds: ['message-1'],
    );
    const selection = MemorySelection(
      entries: [entry],
      allScores: [MemoryCandidateScore(entry: entry, score: 1)],
      entryCap: 1,
    );

    final result = resolver.resolve(
      selection: selection,
      visibleMessageIds: const {'message-1'},
      disableSourceWindowExclusion: true,
      excerptingEnabled: false,
      packingMode: 'full',
      excerptTokensPerChunk: 500,
      excerptChunksPerEntry: 2,
      chunkFirstTopEntries: 3,
      chunkFirstTopChunks: 1,
    );

    expect(result.selection.entries.single.id, 'memory');
    expect(result.content, isNotNull);
  });

  test('empty selection returns no content or triggered entries', () {
    final result = resolver.resolve(
      selection: const MemorySelection(),
      visibleMessageIds: const {},
      disableSourceWindowExclusion: false,
      excerptingEnabled: true,
      packingMode: 'hybrid',
      excerptTokensPerChunk: 500,
      excerptChunksPerEntry: 2,
      chunkFirstTopEntries: 3,
      chunkFirstTopChunks: 1,
    );

    expect(result.content, isNull);
    expect(result.triggeredEntries, isEmpty);
  });
}
