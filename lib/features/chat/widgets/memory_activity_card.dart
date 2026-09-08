import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../state/memory_activity_provider.dart';
import 'agentic_operations_log_dialog.dart';
import 'memory_graph_panel.dart';

class MemoryActivityCard extends StatefulWidget {
  final MemoryActivityState activity;
  final bool expanded;
  final VoidCallback onToggle;
  final String? sessionId;

  const MemoryActivityCard({
    super.key,
    required this.activity,
    required this.expanded,
    required this.onToggle,
    this.sessionId,
  });

  @override
  State<MemoryActivityCard> createState() => _MemoryActivityCardState();
}

class _MemoryActivityCardState extends State<MemoryActivityCard> {
  final Set<String> _expandedEntryIds = {};
  final ScrollController _listScrollController = ScrollController();

  @override
  void didUpdateWidget(covariant MemoryActivityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activity.messageId != widget.activity.messageId) {
      _expandedEntryIds.clear();
    }
  }

  @override
  void dispose() {
    _listScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final diagnostics = widget.activity.diagnostics;
    final selectedCount = diagnostics['selectedCount'] as int? ?? 0;
    final selectedTokens = diagnostics['selectedTokens'] as int? ?? 0;
    final totalCandidates =
        diagnostics['eligibleCandidates'] as int? ??
        diagnostics['totalCandidates'] as int? ??
        0;
    final skippedCount =
        diagnostics['eligibleSkippedCount'] as int? ??
        diagnostics['skippedCount'] as int? ??
        0;
    final sourceVisibleCount =
        diagnostics['excludedBySourceWindow'] as int? ?? 0;
    final latencyMs = diagnostics['latencyMs'] as int? ?? 0;
    final title = selectedCount == 0
        ? 'Memory: no entries selected'
        : 'Memory: $selectedCount entries, $selectedTokens tokens';

    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.cs.surface.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: context.cs.primary.withValues(alpha: 0.22)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.24),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: widget.onToggle,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Icon(
                          Icons.psychology_alt_outlined,
                          size: 18,
                          color: context.cs.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              color: context.cs.onSurface,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Text(
                          '$totalCandidates candidates',
                          style: TextStyle(
                            color: context.cs.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          widget.expanded
                              ? Icons.expand_more_rounded
                              : Icons.chevron_left_rounded,
                          color: context.cs.onSurfaceVariant,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
                if (diagnostics['memoryMacroMissing'] == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _MemoryActivityWarning(
                      text:
                          'Память собрана, но не вставлена: в пресете нет '
                          '{{memory}}, а инжект настроен на макрос. Добавьте '
                          '{{memory}} в пресет или переключите инжект на блок.',
                    ),
                  ),
                if (widget.expanded) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _MemoryActivityChip(label: 'skipped $skippedCount'),
                            if (sourceVisibleCount > 0)
                              _MemoryActivityChip(
                                label: 'source visible $sourceVisibleCount',
                              ),
                            _MemoryActivityChip(
                              label: 'latency ${latencyMs}ms',
                            ),
                            _MemoryActivityChip(
                              label: _budgetLabel(diagnostics['budget']),
                            ),
                          ],
                        ),
                      ),
                      if (widget.sessionId != null &&
                          widget.sessionId!.isNotEmpty) ...[
                        IconButton(
                          onPressed: () => AgenticOperationsLogDialog.show(
                            context,
                            sessionId: widget.sessionId,
                          ),
                          icon: const Icon(Icons.smart_toy_outlined, size: 18),
                          tooltip: 'Agentic operations log',
                          visualDensity: VisualDensity.compact,
                        ),
                        IconButton(
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) =>
                                MemoryGraphPanel(sessionId: widget.sessionId!),
                          ),
                          icon: const Icon(
                            Icons.account_tree_outlined,
                            size: 18,
                          ),
                          tooltip: 'Memory Graph',
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  _candidateList(context, diagnostics),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _budgetLabel(Object? raw) {
    if (raw is! Map) return 'budget none';
    final source = raw['source'] ?? 'none';
    final tokens = raw['effectiveTokens'];
    return tokens is int ? 'budget $tokens ($source)' : 'budget $source';
  }

  Widget _candidateList(
    BuildContext context,
    Map<String, dynamic> diagnostics,
  ) {
    final raw = diagnostics['candidates'];
    if (raw is! List) return const SizedBox.shrink();
    final rows = raw
        .whereType<Map<String, dynamic>>()
        .map((candidate) => _candidateTile(context, candidate))
        .toList(growable: false);
    if (rows.isEmpty) return const SizedBox.shrink();
    // Cap the list height so a large memory book (dozens of entries) scrolls
    // inside the card instead of expanding into one giant screen-tall panel.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: Scrollbar(
        controller: _listScrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _listScrollController,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: rows,
          ),
        ),
      ),
    );
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
      return '$injected из $total';
    }
    final indexes = candidate['excerptChunkIndexes'];
    if (indexes is List && indexes.isNotEmpty) {
      return '${indexes.length} ch';
    }
    return '';
  }

  Widget _candidateTile(BuildContext context, Map<String, dynamic> candidate) {
    final title = (candidate['title'] as String?)?.trim();
    final entryId = candidate['entryId'] as String? ?? '';
    final messageRange = (candidate['messageRange'] as String?)?.trim() ?? '';
    final label = title == null || title.isEmpty
        ? (messageRange.isNotEmpty ? messageRange : entryId)
        : (title == messageRange || messageRange.isEmpty ? title : title);
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
    final keywordScore = candidate['keywordScore'];
    final vectorScore = candidate['vectorScore'];
    final catalogScore = candidate['catalogScore'];
    // Which retrieval layer actually fired for this entry. Keyword-triggered
    // entries previously had no visible marker (only vector excerpt overlap
    // terms were rendered), making it look like the badge "only shows vectors".
    final hasKeyword = matchedKeys.isNotEmpty || _isPositive(keywordScore);
    final hasVector = _isPositive(vectorScore);
    final hasCatalog = catalogTerms.isNotEmpty || _isPositive(catalogScore);
    final triggers = <String>[
      if (hasKeyword) 'key',
      if (hasVector) 'vec',
      if (hasCatalog) 'cat',
    ];
    final triggerLabel = triggers.isEmpty ? '' : triggers.join('+');
    final baseTypeLabel = switch (injectionType) {
      'excerpt' when chunkLabel.isNotEmpty => chunkLabel,
      'excerpt' => 'excerpt',
      'full_entry' => 'full',
      _ => reason,
    };
    final typeLabel = triggerLabel.isEmpty
        ? baseTypeLabel
        : '$baseTypeLabel · $triggerLabel';
    final matchedTerms = candidate['excerptMatchedTerms'];
    final chunkIndexes = candidate['excerptChunkIndexes'];
    final canExpand = selected;
    final expanded = _expandedEntryIds.contains(entryId);

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: canExpand
                  ? () {
                      setState(() {
                        if (expanded) {
                          _expandedEntryIds.remove(entryId);
                        } else {
                          _expandedEntryIds.add(entryId);
                        }
                      });
                    }
                  : null,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Row(
                  children: [
                    Icon(
                      selected
                          ? Icons.check_circle_outline
                          : Icons.cancel_outlined,
                      color: selected
                          ? Colors.greenAccent
                          : Colors.orangeAccent,
                      size: 16,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '$label · $typeLabel',
                        maxLines: expanded ? 4 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    if (canExpand)
                      Icon(
                        expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 16,
                        color: context.cs.onSurfaceVariant,
                      ),
                    const SizedBox(width: 4),
                    Text(
                      '$tokens tok · $scoreText',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded && canExpand)
            Padding(
              padding: const EdgeInsets.only(left: 25, top: 2, bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (chunkLabel.isNotEmpty)
                    Text(
                      'Чанки: $chunkLabel',
                      style: TextStyle(
                        fontSize: 11,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  if (injectionType == 'excerpt' &&
                      chunkIndexes is List &&
                      chunkIndexes.isNotEmpty)
                    Text(
                      'Индексы: ${chunkIndexes.map((index) => '#$index').join(', ')}',
                      style: TextStyle(
                        fontSize: 11,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  if (injectionType == 'full_entry')
                    Text(
                      'Полная запись ($tokens / $originalTokens tok)',
                      style: TextStyle(
                        fontSize: 11,
                        color: context.cs.onSurfaceVariant,
                      ),
                    ),
                  if (matchedKeys.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Ключи: ${matchedKeys.join(', ')}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (catalogTerms.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Каталог: ${catalogTerms.join(', ')}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (matchedTerms is List && matchedTerms.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Matched: ${matchedTerms.whereType<String>().join(', ')}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.cs.onSurfaceVariant.withValues(
                            alpha: 0.85,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MemoryActivityWarning extends StatelessWidget {
  final String text;

  const _MemoryActivityWarning({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.orangeAccent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 16,
            color: Colors.orangeAccent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11,
                color: context.cs.onSurface,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemoryActivityChip extends StatelessWidget {
  final String label;

  const _MemoryActivityChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: context.cs.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 11),
      ),
    );
  }
}
