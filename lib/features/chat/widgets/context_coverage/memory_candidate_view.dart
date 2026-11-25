import 'package:easy_localization/easy_localization.dart';

import '../../state/memory_activity_provider.dart';
import 'coverage_reasons.dart';

/// How a detail line of an opened memory record is set.
enum MemoryDetailTone {
  /// The verdict sentence: bold, in the row's verdict colour.
  verdict,

  /// An ordinary detail.
  normal,

  /// A detail one step quieter (the matched excerpt terms).
  dim,
}

/// One line of an opened memory record.
typedef MemoryDetailLine = ({
  String text,
  MemoryDetailTone tone,

  /// A little room above it: the keys and terms lists stand apart.
  bool spaced,
});

/// What one memory candidate shows, in words: the row's title and verdict,
/// its cost, and the lines of its opened record.
///
/// Shared by the two places that list a memory run's candidates — the coverage
/// card under the chat header (drawn by the chat page) and the memory block of
/// the requests screen ([MemoryActivitySection]) — so the two read the
/// diagnostics the same way.
class MemoryCandidateView {
  const MemoryCandidateView._({
    required this.entryId,
    required this.label,
    required this.selected,
    required this.shortReason,
    required this.trailing,
    required this.details,
  });

  final String entryId;

  /// The entry's title, or its message range, or its id.
  final String label;
  final bool selected;

  /// Why it was left out, in a couple of words; null when it was selected.
  final String? shortReason;

  /// `42 tok · 3.25`.
  final String trailing;

  /// The opened record: the verdict first, then whatever the run recorded.
  final List<MemoryDetailLine> details;

  factory MemoryCandidateView.of(Map<String, dynamic> candidate) {
    final title = (candidate['title'] as String?)?.trim();
    final entryId = candidate['entryId'] as String? ?? '';
    final messageRange = (candidate['messageRange'] as String?)?.trim() ?? '';
    final label = title == null || title.isEmpty
        ? (messageRange.isNotEmpty ? messageRange : entryId)
        : title;
    final selected = candidate['selected'] == true;
    final reason = candidate['reason'] as String? ?? 'not_selected';
    final tokens = candidate['tokenCost'] as int? ?? 0;
    final originalTokens = candidate['originalTokenCost'] as int? ?? tokens;
    final injectionType = candidate['injectionType'] as String? ?? 'none';
    final score = candidate['score'];
    final scoreText = score is num ? score.toStringAsFixed(2) : '0.00';
    final chunkLabel = _chunkLabel(candidate);
    final matchedKeys = _stringList(candidate['matchedKeys']);
    final catalogTerms = _stringList(candidate['catalogMatchedTerms']);
    // Which retrieval layer actually fired for this entry. Keyword-triggered
    // entries previously had no visible marker (only vector excerpt overlap
    // terms were rendered), making it look like the badge "only shows vectors".
    final hasKeyword =
        matchedKeys.isNotEmpty || _isPositive(candidate['keywordScore']);
    final hasVector = _isPositive(candidate['vectorScore']);
    final hasCatalog =
        catalogTerms.isNotEmpty || _isPositive(candidate['catalogScore']);
    final matchedTerms = candidate['excerptMatchedTerms'];
    final chunkIndexes = candidate['excerptChunkIndexes'];

    MemoryDetailLine line(
      String text, [
      MemoryDetailTone tone = MemoryDetailTone.normal,
      bool spaced = false,
    ]) => (text: text, tone: tone, spaced: spaced);

    final injection = memoryInjectionLabel(injectionType);
    final trigger = memoryTriggerLabel(
      keyword: hasKeyword,
      vector: hasVector,
      catalog: hasCatalog,
    );
    final details = <MemoryDetailLine>[
      // The verdict first, in words. It used to be the raw diagnostic code
      // appended to the row's title, where it was untranslated and clipped by
      // the single line.
      line(memoryReasonLabel(reason), MemoryDetailTone.verdict),
      if (injection != null && injection.isNotEmpty) line(injection),
      if (trigger != null && trigger.isNotEmpty) line(trigger),
      if (chunkLabel.isNotEmpty)
        line('memory_detail_chunks'.tr(args: [chunkLabel])),
      if (injectionType == 'excerpt' &&
          chunkIndexes is List &&
          chunkIndexes.isNotEmpty)
        line(
          'memory_detail_indexes'.tr(
            args: [chunkIndexes.map((index) => '#$index').join(', ')],
          ),
        ),
      if (injectionType == 'full_entry')
        line(
          'memory_detail_full_entry'.tr(args: ['$tokens', '$originalTokens']),
        ),
      if (matchedKeys.isNotEmpty)
        line(
          'memory_detail_keys'.tr(args: [matchedKeys.join(', ')]),
          MemoryDetailTone.normal,
          true,
        ),
      if (catalogTerms.isNotEmpty)
        line(
          'memory_detail_catalog'.tr(args: [catalogTerms.join(', ')]),
          MemoryDetailTone.normal,
          true,
        ),
      if (matchedTerms is List && matchedTerms.isNotEmpty)
        line(
          'memory_detail_matched'.tr(
            args: [matchedTerms.whereType<String>().join(', ')],
          ),
          MemoryDetailTone.dim,
          true,
        ),
    ];

    return MemoryCandidateView._(
      entryId: entryId,
      label: label,
      selected: selected,
      // Every row opens, selected or not: the opened record carries the full
      // sentence. The row itself only shows the short form, and only when the
      // candidate missed.
      shortReason: selected ? null : memoryReasonShortLabel(reason),
      trailing: '$tokens tok · $scoreText',
      details: details,
    );
  }

  /// The run's candidates, in the order the run recorded them.
  static List<MemoryCandidateView> listOf(Map<String, dynamic> diagnostics) {
    final raw = diagnostics['candidates'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(MemoryCandidateView.of)
        .toList(growable: false);
  }

  /// The run's stat chips: skipped, already visible, latency and budget.
  static List<String> chipsOf(
    MemoryActivitySummary summary,
    Map<String, dynamic> diagnostics,
  ) => [
    'memory_chip_skipped'.tr(args: ['${summary.skippedCount}']),
    if (summary.sourceVisibleCount > 0)
      'memory_chip_source_visible'.tr(args: ['${summary.sourceVisibleCount}']),
    'memory_chip_latency'.tr(args: ['${summary.latencyMs}']),
    budgetLabel(diagnostics['budget']),
  ];

  static String budgetLabel(Object? raw) {
    if (raw is! Map) return 'memory_chip_budget_none'.tr();
    final source = '${raw['source'] ?? 'none'}';
    final tokens = raw['effectiveTokens'];
    return tokens is int
        ? 'memory_chip_budget'.tr(args: ['$tokens', source])
        : 'memory_chip_budget_source'.tr(args: [source]);
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  static bool _isPositive(Object? raw) => raw is num && raw > 0;

  static String _chunkLabel(Map<String, dynamic> candidate) {
    final injected = candidate['excerptChunksInjected'] as int? ?? 0;
    final total = candidate['excerptChunksTotal'] as int? ?? 0;
    if (injected > 0 && total > 0) {
      return 'memory_chunks_of'.tr(args: ['$injected', '$total']);
    }
    final indexes = candidate['excerptChunkIndexes'];
    if (indexes is List && indexes.isNotEmpty) {
      return 'memory_chunks_count'.tr(args: ['${indexes.length}']);
    }
    return '';
  }
}
