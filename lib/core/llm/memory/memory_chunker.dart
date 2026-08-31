import '../tokenizer.dart';

/// A text chunk with its index and token cost.
class ExcerptChunk {
  final int index;
  final int paragraphIndex;
  final String text;
  final int tokenCost;

  const ExcerptChunk(
    this.index,
    this.paragraphIndex,
    this.text,
    this.tokenCost,
  );
}

/// Text chunking logic for memory excerpt selection.
///
/// Extracted from `MemoryExcerptSelector` (Phase 6b). Pure static methods.
/// Splits entry content into paragraph/sentence-based chunks that fit
/// within a per-chunk token budget.
class MemoryChunker {
  const MemoryChunker._();

  /// Split [content] into chunks of at most [maxTokens] tokens each.
  ///
  /// Strategy:
  /// 1. Split on blank lines (paragraph boundaries).
  /// 2. If a paragraph fits in [maxTokens], keep it as one chunk.
  /// 3. Otherwise, split into sentences and accumulate into windows.
  /// 4. If a single sentence exceeds [maxTokens], hard-split by words.
  static List<ExcerptChunk> chunk(
    String content,
    int maxTokens,
    int Function(String text) tokenCounter,
  ) {
    final blocks = paragraphs(content);
    final chunks = <ExcerptChunk>[];
    var index = 0;
    for (
      var paragraphIndex = 0;
      paragraphIndex < blocks.length;
      paragraphIndex++
    ) {
      final block = blocks[paragraphIndex];
      final tokenCost = tokenCounter(block);
      if (tokenCost <= maxTokens) {
        chunks.add(ExcerptChunk(index++, paragraphIndex, block, tokenCost));
        continue;
      }
      final sentences = MemoryChunker.sentences(block);
      var window = <String>[];
      for (final sentence in sentences) {
        final candidate = [...window, sentence].join(' ').trim();
        if (candidate.isEmpty) continue;
        if (tokenCounter(candidate) <= maxTokens) {
          window.add(sentence);
          continue;
        }
        if (window.isNotEmpty) {
          final text = window.join(' ').trim();
          chunks.add(
            ExcerptChunk(index++, paragraphIndex, text, tokenCounter(text)),
          );
          window = [];
        }
        if (tokenCounter(sentence) > maxTokens) {
          final words = sentence.split(RegExp(r'\s+'));
          var wordStart = 0;
          while (wordStart < words.length) {
            var wordEnd = wordStart + 1;
            while (wordEnd <= words.length &&
                tokenCounter(words.sublist(wordStart, wordEnd).join(' ')) <=
                    maxTokens) {
              wordEnd++;
            }
            final safeEnd = (wordEnd - 1).clamp(wordStart + 1, words.length);
            final shortText = words
                .sublist(wordStart, safeEnd)
                .join(' ')
                .trim();
            if (shortText.isNotEmpty) {
              chunks.add(
                ExcerptChunk(
                  index++,
                  paragraphIndex,
                  shortText,
                  tokenCounter(shortText),
                ),
              );
            }
            wordStart = safeEnd;
          }
          window = [];
          continue;
        }
        window.add(sentence);
      }
      if (window.isNotEmpty) {
        final text = window.join(' ').trim();
        chunks.add(
          ExcerptChunk(index++, paragraphIndex, text, tokenCounter(text)),
        );
      }
    }
    return chunks;
  }

  static List<String> paragraphs(String content) => content
      .split(RegExp(r'\n\s*\n+'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);

  /// Split text into sentences using punctuation boundaries.
  static List<String> sentences(String text) {
    final matches = RegExp(r'[^.!?\n]+(?:[.!?]+|$)').allMatches(text);
    final sentences = matches
        .map((match) => match.group(0)?.trim() ?? '')
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    return sentences.isEmpty ? [text.trim()] : sentences;
  }

  /// Count how many chunks [content] would produce for [maxTokensPerChunk].
  static int countChunks(
    String content,
    int maxTokensPerChunk, {
    int Function(String text)? tokenCounter,
  }) {
    final tokenFn = tokenCounter ?? estimateTokens;
    if (content.trim().isEmpty || maxTokensPerChunk <= 0) return 0;
    return chunk(content, maxTokensPerChunk, tokenFn).length;
  }
}
