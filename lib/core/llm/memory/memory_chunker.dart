import '../tokenizer.dart';

/// A text chunk with its index and token cost.
class ExcerptChunk {
  final int index;
  final String text;
  final int tokenCost;

  const ExcerptChunk(this.index, this.text, this.tokenCost);
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
    final blocks = content
        .split(RegExp(r'\n\s*\n+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    final chunks = <ExcerptChunk>[];
    var index = 0;
    for (final block in blocks) {
      final tokenCost = tokenCounter(block);
      if (tokenCost <= maxTokens) {
        chunks.add(ExcerptChunk(index++, block, tokenCost));
        continue;
      }
      final sentences = MemoryChunker.sentences(block);
      var window = <String>[];
      for (final sentence in sentences) {
        final candidate = [...window, sentence].join(' ').trim();
        if (candidate.isEmpty) continue;
        if (tokenCounter(candidate) > maxTokens && window.isNotEmpty) {
          final text = window.join(' ').trim();
          chunks.add(ExcerptChunk(index++, text, tokenCounter(text)));
          window = [sentence];
        } else if (tokenCounter(candidate) > maxTokens) {
          final words = sentence.split(RegExp(r'\s+'));
          final shortText = words.take(maxTokens * 3).join(' ').trim();
          if (shortText.isNotEmpty) {
            chunks.add(
              ExcerptChunk(index++, shortText, tokenCounter(shortText)),
            );
          }
          window = [];
        } else {
          window.add(sentence);
        }
      }
      if (window.isNotEmpty) {
        final text = window.join(' ').trim();
        chunks.add(ExcerptChunk(index++, text, tokenCounter(text)));
      }
    }
    return chunks;
  }

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
