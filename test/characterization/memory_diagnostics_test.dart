import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/memory_budget.dart';
import 'package:glaze_flutter/core/llm/memory_diagnostics.dart';
import 'package:glaze_flutter/core/llm/memory_selector.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';

MemoryEntry _entry({
  required String id,
  String title = '',
  String content = 'word word word word',
  List<String> keys = const [],
  List<String> messageIds = const [],
  MessageRange? messageRange,
  int? createdAt,
  String arc = '',
  String kind = 'curated',
}) => MemoryEntry(
  id: id,
  title: title,
  content: content,
  keys: keys,
  messageIds: messageIds,
  messageRange: messageRange,
  createdAt: createdAt,
  arc: arc,
  kind: kind,
  status: 'active',
);

void main() {
  group('MemoryBudgetBreakdown diagnostics', () {
    test('describes percent-only, absolute-only, and min-composed budgets', () {
      expect(
        MemoryInjectionBudget.describeBudget(
          contextBudgetTokens: 1000,
          percent: 0.25,
          absoluteCap: null,
        ).toJson(),
        {
          'effectiveTokens': 250,
          'percentTokens': 250,
          'absoluteTokens': null,
          'source': 'percent',
        },
      );

      expect(
        MemoryInjectionBudget.describeBudget(
          contextBudgetTokens: null,
          percent: 0.25,
          absoluteCap: 600,
        ).source,
        'absolute',
      );

      final composed = MemoryInjectionBudget.describeBudget(
        contextBudgetTokens: 4000,
        percent: 0.5,
        absoluteCap: 600,
      );
      expect(composed.effectiveTokens, 600);
      expect(composed.percentTokens, 2000);
      expect(composed.absoluteTokens, 600);
      expect(composed.source, 'absolute_min');
    });
  });

  group('MemoryDiagnostics', () {
    test(
      'serializes selected and skipped candidates with score components',
      () {
        final selection = MemorySelector.select(
          MemorySelectionInput(
            entries: [
              _entry(
                id: 'visible',
                title: 'Visible source',
                content: 'visible ' * 8,
                keys: const ['visible'],
                messageIds: const ['m1'],
                messageRange: const MessageRange(start: 1, end: 3),
                createdAt: 1,
                arc: 'bridge',
                kind: 'episode',
              ),
              _entry(
                id: 'picked',
                title: 'Picked memory',
                content: 'picked ' * 8,
                keys: const ['picked'],
                createdAt: 2,
              ),
            ],
            visibleMessageIds: const {'m1'},
            maxInjectedEntries: 4,
            keywordWeight: 0,
            vectorWeight: 0,
            recencyBoost: false,
            importanceBoost: false,
            diversityAware: false,
          ),
        );

        final diagnostics = MemoryDiagnostics.fromSelection(
          selection,
          budget: const MemoryBudgetBreakdown(
            effectiveTokens: 100,
            percentTokens: 100,
            source: 'percent',
          ),
          tokenCounter: (_) => 12,
          latencyMs: 7,
        );

        expect(diagnostics.summary, 'Memory: 1 entries, 12 tokens');
        expect(diagnostics.selectedEntryIds, ['picked']);
        expect(diagnostics.selectedCount, 1);
        expect(diagnostics.skippedCount, 1);
        expect(diagnostics.reliableCandidateFound, isFalse);
        expect(diagnostics.missingContextSuspected, isFalse);
        expect(diagnostics.excludedBySourceWindow, 1);
        expect(diagnostics.latencyMs, 7);

        final json = diagnostics.toJson();
        expect(json['selectedTokens'], 12);
        expect(json['memoryMode'], 'fast');
        expect(json['missingContextSuspected'], isFalse);
        expect(json['missingContextReasons'], isEmpty);
        expect(json['reliableCandidateFound'], isFalse);
        expect(json['factualContinuityGuardActive'], isFalse);
        expect(json['budget'], containsPair('source', 'percent'));
        final candidates = json['candidates'] as List<dynamic>;
        final visible = candidates.cast<Map<String, dynamic>>().firstWhere(
          (c) => c['entryId'] == 'visible',
        );
        expect(visible['selected'], isFalse);
        expect(visible['reason'], 'source_visible_in_prompt');
        expect(visible['messageRange'], '1-3');
        expect(visible['arc'], 'bridge');
        expect(visible['kind'], 'episode');
      },
    );

    test(
      'marks old-context references suspicious without injecting random memory',
      () {
        final selection = MemorySelector.select(
          MemorySelectionInput(
            entries: [
              _entry(
                id: 'weak',
                title: 'Unrelated note',
                content: 'tiny',
                keys: const [],
              ),
            ],
            maxInjectedEntries: 0,
            keywordWeight: 0,
            vectorWeight: 0,
            recencyBoost: false,
            importanceBoost: false,
            diversityAware: false,
          ),
        );

        final diagnostics = MemoryDiagnostics.fromSelection(
          selection,
          budget: const MemoryBudgetBreakdown(source: 'none'),
          currentText: 'Do you remember what happened before?',
          memoryMode: 'balanced',
          factualContinuityGuardEnabled: true,
        );

        expect(selection.entries, isEmpty);
        expect(diagnostics.reliableCandidateFound, isFalse);
        expect(diagnostics.missingContextSuspected, isTrue);
        expect(diagnostics.factualContinuityGuardEnabled, isTrue);
        expect(diagnostics.factualContinuityGuardActive, isTrue);
        expect(
          diagnostics.missingContextReasons,
          containsAll([
            'old_context_reference_without_reliable_candidate',
            'weak_retrieval',
          ]),
        );
      },
    );

    test('marks empty retrieval suspicious but keeps selection empty', () {
      const selection = MemorySelection();

      final diagnostics = MemoryDiagnostics.fromSelection(
        selection,
        budget: const MemoryBudgetBreakdown(source: 'none'),
        currentText: 'Where were we last time?',
        memoryMode: 'balanced',
      );

      expect(selection.entries, isEmpty);
      expect(diagnostics.missingContextSuspected, isTrue);
      expect(
        diagnostics.missingContextReasons,
        containsAll([
          'old_context_reference_without_reliable_candidate',
          'empty_retrieval',
        ]),
      );
    });

    test('marks conflicting top candidates in diagnostics', () {
      final selection = MemorySelector.select(
        MemorySelectionInput(
          entries: [
            _entry(
              id: 'a',
              title: 'Bridge promise',
              content: 'bridge memory ' * 8,
              keys: const ['bridge'],
            ),
            _entry(
              id: 'b',
              title: 'Tavern debt',
              content: 'tavern memory ' * 8,
              keys: const ['tavern'],
            ),
          ],
          maxInjectedEntries: 2,
          keywordWeight: 0,
          vectorWeight: 0,
          recencyBoost: false,
          importanceBoost: false,
          diversityAware: false,
          catalogScores: const {'a': 0.7, 'b': 0.7},
        ),
      );

      final diagnostics = MemoryDiagnostics.fromSelection(
        selection,
        budget: const MemoryBudgetBreakdown(source: 'none'),
        memoryMode: 'balanced',
      );

      expect(diagnostics.reliableCandidateFound, isFalse);
      expect(
        diagnostics.missingContextReasons,
        contains('conflicting_top_candidates'),
      );
    });

    test(
      'marks scored candidates skipped after the selected tail is budget trimmed',
      () {
        final selection = MemorySelector.select(
          MemorySelectionInput(
            entries: [
              _entry(id: 'a', content: 'a ' * 8, createdAt: 3),
              _entry(id: 'b', content: 'b ' * 8, createdAt: 2),
              _entry(id: 'c', content: 'c ' * 8, createdAt: 1),
            ],
            maxInjectionTokens: 15,
            maxInjectedEntries: 3,
            keywordWeight: 0,
            vectorWeight: 0,
            recencyBoost: false,
            importanceBoost: false,
            diversityAware: false,
          ),
          tokenCounter: (_) => 10,
        );

        final diagnostics = MemoryDiagnostics.fromSelection(
          selection,
          budget: const MemoryBudgetBreakdown(
            effectiveTokens: 15,
            source: 'absolute',
          ),
          tokenCounter: (_) => 10,
        );

        expect(diagnostics.selectedEntryIds, ['a']);
        expect(diagnostics.budgetTrimmed, isTrue);
        expect(
          diagnostics.candidates.where((c) => c.reason == 'budget_trimmed'),
          hasLength(2),
        );
      },
    );
  });
}
