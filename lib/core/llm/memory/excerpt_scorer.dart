import '../../models/memory_book.dart';
import '../memory_selector.dart';
import 'memory_chunker.dart';

/// A chunk paired with its computed relevance score.
class ScoredChunk {
  final ExcerptChunk chunk;
  final double score;

  const ScoredChunk(this.chunk, this.score);
}

/// A globally-ranked chunk candidate from a memory entry.
class GlobalChunkCandidate {
  final MemoryEntry entry;
  final double entryScore;
  final double recencyScore;
  final double vectorScore;
  final int chunkIndex;
  final String text;
  final int tokenCost;
  final double relevance;

  const GlobalChunkCandidate({
    required this.entry,
    required this.entryScore,
    this.recencyScore = 0,
    this.vectorScore = 0,
    required this.chunkIndex,
    required this.text,
    required this.tokenCost,
    required this.relevance,
  });
}

/// Scoring helpers for memory excerpt selection.
///
/// Extracted from `MemoryExcerptSelector` (Phase 6b). Pure static methods
/// that compute chunk relevance, term extraction, and durable-term boosts.
class ExcerptScorer {
  const ExcerptScorer._();

  /// Terms that signal durable, plot-relevant content.
  static const durableTerms = <String>{
    'promise',
    'promised',
    'secret',
    'injury',
    'wound',
    'debt',
    'map',
    'ritual',
    'location',
    'relationship',
    'trust',
  };

  /// Extract all relevant terms (keys, catalog terms, title, arc) from a
  /// candidate score, lowercased and tokenized (min 3 chars).
  static Set<String> termsFor(MemoryCandidateScore score) {
    final raw = <String>[
      ...score.matchedKeys,
      ...score.catalogMatchedTerms,
      ...score.entry.keys,
      score.entry.title,
      score.entry.arc,
    ];
    final terms = <String>{};
    for (final value in raw) {
      for (final token in value.toLowerCase().split(
        RegExp(r'[^\p{L}\p{N}_]+', unicode: true),
      )) {
        if (token.length >= 3) terms.add(token);
      }
    }
    return terms;
  }

  /// Boost score for chunks that overlap with vector-matched chunk texts.
  static double vectorChunkBoost(String text, List<String> vectorChunks) {
    if (vectorChunks.isEmpty) return 0;
    final lower = text.toLowerCase();
    for (final vectorChunk in vectorChunks) {
      final chunk = vectorChunk.trim().toLowerCase();
      if (chunk.isEmpty) continue;
      if (lower.contains(chunk) || chunk.contains(lower)) return 100.0;
      final chunkTerms = chunk
          .split(RegExp(r'[^\p{L}\p{N}_]+', unicode: true))
          .where((term) => term.length >= 4)
          .toSet();
      if (chunkTerms.isEmpty) continue;
      final overlap = chunkTerms.where(lower.contains).length;
      if (overlap > 0) return overlap.clamp(0, 12) * 2.0;
    }
    return 0;
  }

  /// Entry-level signals (recency, vector, importance, catalog) that can
  /// justify injection even when the current turn has no direct keyword
  /// overlap.
  static double entryChunkPrior(MemoryCandidateScore score) {
    return score.recencyScore * 4.0 +
        score.vectorScore * 0.6 +
        score.importanceScore * 2.0 +
        score.catalogScore * 0.4;
  }

  /// Combined chunk relevance: term score + vector boost + entry prior.
  static double chunkRelevance(
    String text,
    MemoryCandidateScore score,
    Set<String> terms,
  ) {
    return scoreChunk(text, terms) +
        vectorChunkBoost(text, score.vectorMatchedChunks) +
        entryChunkPrior(score);
  }

  /// Score a chunk text against a set of terms.
  ///
  /// - +2.0 per term match
  /// - +0.5 per durable term match
  /// - +0.35 for capitalized words (proper nouns)
  /// - +0.2 for digits
  /// - -0.2 for very short text (<40 chars)
  static double scoreChunk(String text, Set<String> terms) {
    final lower = text.toLowerCase();
    var score = 0.0;
    for (final term in terms) {
      if (lower.contains(term)) score += 2.0;
    }
    for (final durable in durableTerms) {
      if (lower.contains(durable)) score += 0.5;
    }
    if (RegExp(r'\b[A-Z][a-z]{2,}\b').hasMatch(text)) score += 0.35;
    if (RegExp(r'\d').hasMatch(text)) score += 0.2;
    if (text.length < 40) score -= 0.2;
    return score;
  }
}
