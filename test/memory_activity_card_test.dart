import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/state/memory_activity_provider.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_activity_card.dart';

void main() {
  Widget buildCard({required bool expanded}) {
    return MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Center(
          child: MemoryActivityCard(
            activity: const MemoryActivityState(
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
            expanded: expanded,
            onToggle: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('MemoryActivityCard is collapsed by default data shape', (
    tester,
  ) async {
    await tester.pumpWidget(buildCard(expanded: false));

    expect(find.text('Memory: 1 entries, 42 tokens'), findsOneWidget);
    expect(find.text('2 candidates'), findsOneWidget);
    expect(find.textContaining('Bridge memory'), findsNothing);
    expect(find.textContaining('source_visible_in_prompt'), findsNothing);
  });

  testWidgets('MemoryActivityCard expands selected and skipped details', (
    tester,
  ) async {
    await tester.pumpWidget(buildCard(expanded: true));

    expect(find.text('Memory: 1 entries, 42 tokens'), findsOneWidget);
    expect(find.text('skipped 1'), findsOneWidget);
    expect(find.text('latency 7ms'), findsOneWidget);
    expect(find.text('budget 1000 (absolute)'), findsOneWidget);
    expect(find.textContaining('Bridge memory · selected'), findsOneWidget);
    expect(
      find.textContaining('Visible memory · source_visible_in_prompt'),
      findsOneWidget,
    );
  });

  testWidgets('selected memory row expands independently from card header', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: Center(
            child: MemoryActivityCard(
              activity: const MemoryActivityState(
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
              expanded: true,
              onToggle: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('Чанки:'), findsNothing);
    await tester.tap(find.textContaining('Bridge memory · 2 из 12'));
    await tester.pump();
    expect(find.textContaining('Чанки: 2 из 12'), findsOneWidget);
    expect(find.textContaining('Индексы: #1, #3'), findsOneWidget);
  });

  testWidgets('keyword-injected entry shows key trigger and matched keys', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: Center(
            child: MemoryActivityCard(
              activity: const MemoryActivityState(
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
              expanded: true,
              onToggle: () {},
            ),
          ),
        ),
      ),
    );

    // The inline type label must advertise the keyword trigger so a
    // keyword-only injection is not mistaken for a vector-only badge.
    expect(find.textContaining('Keyword memory · full · key'), findsOneWidget);
    await tester.tap(find.textContaining('Keyword memory · full · key'));
    await tester.pump();
    expect(find.textContaining('Ключи: castle, king'), findsOneWidget);
  });
}
