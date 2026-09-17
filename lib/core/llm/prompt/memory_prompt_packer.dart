import '../game_time.dart';
import '../memory_excerpt_selector.dart';
import '../memory_formatting.dart';
import '../memory_selector.dart';
import '../tokenizer.dart';

final class ResolvedMemoryContent {
  final String hardBlockContent;
  final String macroContent;

  const ResolvedMemoryContent({
    required this.hardBlockContent,
    required this.macroContent,
  });
}

/// Packs bodies with room for their actual, expanded prompt envelopes.
/// The final guard also covers legacy first-entry fallbacks in the selector.
final class MemoryPromptPacker {
  const MemoryPromptPacker();

  MemoryExcerptSelection pack({
    required MemorySelection selection,
    required bool excerptingEnabled,
    required String packingMode,
    required int excerptTokensPerChunk,
    required int excerptChunksPerEntry,
    required int chunkFirstTopEntries,
    required int chunkFirstTopChunks,
    GameTimeState gameTime = const GameTimeState(),
    String? summaryExcerpt,
  }) {
    MemoryExcerptSelection select(MemorySelection input) =>
        !excerptingEnabled && packingMode != 'chunk_first'
        ? MemoryExcerptSelector.fullEntries(input)
        : MemoryExcerptSelector.select(
            input,
            packingMode: packingMode,
            maxExcerptTokensPerEntry: excerptTokensPerChunk,
            maxExcerptChunksPerEntry: excerptChunksPerEntry,
            chunkFirstTopEntries: chunkFirstTopEntries,
            chunkFirstTopChunks: chunkFirstTopChunks,
          );
    int cost(List<MemoryInjectionItem> items) => items.isEmpty
        ? 0
        : estimateTokens(
            format(
              items,
              gameTime: gameTime,
              summaryExcerpt: summaryExcerpt,
            ).hardBlockContent,
          );

    var packed = select(selection);
    final budget = selection.budgetTokens;
    var bodyBudget = budget ?? 0;
    var trimmed = packed.budgetTrimmed;
    if (budget != null && budget > 0) {
      // Repack excerpts using measured overhead, not a fixed per-entry guess.
      for (var attempt = 0; attempt < 4; attempt++) {
        final excess = cost(packed.items) - budget;
        if (excess <= 0) break;
        trimmed = true;
        bodyBudget -= excess;
        if (bodyBudget <= 0 ||
            (!excerptingEnabled && packingMode != 'chunk_first') ||
            packingMode == 'full') {
          break;
        }
        packed = select(
          MemorySelection(
            selectionMode: selection.selectionMode,
            entries: selection.entries,
            allScores: selection.allScores,
            totalTokens: selection.totalTokens,
            budgetTokens: bodyBudget,
            entryCap: selection.entryCap,
            budgetTrimmed: true,
            excludedBySourceWindow: selection.excludedBySourceWindow,
          ),
        );
      }
    }
    final items = packed.items
        .where((item) => item.text.trim().isNotEmpty)
        .toList();
    final scores = {
      for (final score in selection.allScores) score.entry.id: score.score,
    };
    while (budget != null && budget > 0 && cost(items) > budget) {
      var weakest = items.length - 1;
      for (var i = items.length - 2; i >= 0; i--) {
        if ((scores[items[i].entry.id] ?? 0) <
            (scores[items[weakest].entry.id] ?? 0)) {
          weakest = i;
        }
      }
      items.removeAt(weakest);
      trimmed = true;
    }
    return MemoryExcerptSelection(
      items: items,
      totalTokens: cost(items),
      budgetTrimmed: trimmed || packed.budgetTrimmed,
    );
  }

  ResolvedMemoryContent format(
    List<MemoryInjectionItem> items, {
    GameTimeState gameTime = const GameTimeState(),
    String? summaryExcerpt,
  }) {
    String memory(bool header) => gameTime.expandMacros(
      formatMemoryItems(
        items,
        includeContextHeader: header,
        gameTime: gameTime,
      ),
    );
    return ResolvedMemoryContent(
      hardBlockContent: [
        if (summaryExcerpt?.trim().isNotEmpty == true)
          gameTime.expandMacros('Summary excerpt:\n$summaryExcerpt'),
        memory(true),
      ].join('\n\n'),
      macroContent: memory(false),
    );
  }
}
