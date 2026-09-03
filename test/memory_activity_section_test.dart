import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/state/memory_activity_provider.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_activity_section.dart';

/// Localization is not initialized here, so `.tr()` returns the key itself —
/// the expectations below assert on keys, not on English copy.
void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  Widget buildSection() => wrap(
    const MemoryActivitySection(
      activity: MemoryActivityState(
        sessionId: 's1',
        messageId: 'a1',
        diagnostics: {
          'selectedCount': 1,
          'selectedTokens': 42,
          'totalCandidates': 2,
          'skippedCount': 1,
          'latencyMs': 7,
          'budget': {'effectiveTokens': 1000, 'source': 'absolute'},
          'candidates': [
            {
              'entryId': 'm1',
              'title': 'Bridge memory',
              'selected': true,
              'reason': 'selected',
              'tokenCost': 42,
              'score': 3.25,
            },
            {
              'entryId': 'm2',
              'title': 'Visible memory',
              'selected': false,
              'reason': 'source_visible_in_prompt',
              'tokenCost': 20,
              'score': 0.0,
            },
          ],
        },
        updatedAtMillis: 123,
      ),
    ),
  );

  testWidgets('renders the run stats and every candidate', (tester) async {
    await tester.pumpWidget(buildSection());

    expect(find.text('memory_chip_skipped'), findsOneWidget);
    expect(find.text('memory_chip_latency'), findsOneWidget);
    expect(find.text('memory_chip_budget'), findsOneWidget);
    expect(find.textContaining('Bridge memory · selected'), findsOneWidget);
    expect(
      find.textContaining('Visible memory · source_visible_in_prompt'),
      findsOneWidget,
    );
  });

  testWidgets('a selected row expands its own details', (tester) async {
    await tester.pumpWidget(
      wrap(
        const MemoryActivitySection(
          activity: MemoryActivityState(
            sessionId: 's1',
            messageId: 'a1',
            diagnostics: {
              'selectedCount': 1,
              'selectedTokens': 42,
              'totalCandidates': 1,
              'skippedCount': 0,
              'latencyMs': 7,
              'budget': {'effectiveTokens': 1000, 'source': 'absolute'},
              'candidates': [
                {
                  'entryId': 'm1',
                  'title': 'Bridge memory',
                  'selected': true,
                  'reason': 'selected',
                  'tokenCost': 42,
                  'originalTokenCost': 900,
                  'score': 3.25,
                  'injectionType': 'excerpt',
                  'excerptChunkIndexes': [1, 3],
                  'excerptChunksTotal': 12,
                  'excerptChunksInjected': 2,
                  'messageRange': '10-24',
                },
              ],
            },
            updatedAtMillis: 123,
          ),
        ),
      ),
    );

    expect(find.text('memory_detail_chunks'), findsNothing);
    await tester.tap(find.textContaining('Bridge memory · memory_chunks_of'));
    await tester.pump();
    expect(find.text('memory_detail_chunks'), findsOneWidget);
    expect(find.text('memory_detail_indexes'), findsOneWidget);
  });

  testWidgets('a keyword-injected entry advertises the key trigger', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const MemoryActivitySection(
          activity: MemoryActivityState(
            sessionId: 's1',
            messageId: 'a1',
            diagnostics: {
              'selectedCount': 1,
              'selectedTokens': 42,
              'totalCandidates': 1,
              'skippedCount': 0,
              'latencyMs': 7,
              'budget': {'effectiveTokens': 1000, 'source': 'absolute'},
              'candidates': [
                {
                  'entryId': 'm1',
                  'title': 'Keyword memory',
                  'selected': true,
                  'reason': 'selected',
                  'tokenCost': 42,
                  'score': 6.5,
                  'keywordScore': 6.0,
                  'vectorScore': 0.0,
                  'injectionType': 'full_entry',
                  'matchedKeys': ['castle', 'king'],
                },
              ],
            },
            updatedAtMillis: 123,
          ),
        ),
      ),
    );

    // The inline type label must advertise the keyword trigger so a
    // keyword-only injection is not mistaken for a vector-only badge.
    expect(find.textContaining('Keyword memory · full · key'), findsOneWidget);
    await tester.tap(find.textContaining('Keyword memory · full · key'));
    await tester.pump();
    expect(find.text('memory_detail_keys'), findsOneWidget);
  });
}
