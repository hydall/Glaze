import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/features/chat/widgets/memory/memory_draft_card.dart';

void main() {
  testWidgets('shows the Ledger range in the draft header before approval', (
    tester,
  ) async {
    const range =
        '19.09.2026 · RP_Day 0 · 19:20 -> 19.09.2026 · RP_Day 0 · 19:35';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryDraftCard(
            draft: const MemoryDraft(
              id: 'draft-1',
              title: '1-15',
              content: 'Generated memory',
              ledgerRange: range,
            ),
            isGenerating: false,
            generatingSince: null,
            onGenerate: () {},
            onRegenerate: () {},
            onCancel: () {},
            onApprove: () {},
            onEdit: () {},
            onDelete: () {},
          ),
        ),
      ),
    );

    expect(find.text('1-15 · $range'), findsOneWidget);
  });

  testWidgets('content-bearing pending draft offers explicit regeneration', (
    tester,
  ) async {
    var regenerations = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: MemoryDraftCard(
            draft: const MemoryDraft(
              id: 'draft-1',
              content: 'existing memory',
              status: 'pending_approval',
            ),
            isGenerating: false,
            generatingSince: null,
            onGenerate: () {},
            onRegenerate: () => regenerations++,
            onCancel: () {},
            onApprove: () {},
            onEdit: () {},
            onDelete: () {},
          ),
        ),
      ),
    );

    expect(find.text('memory_books_btn_regenerate'), findsOneWidget);
    expect(find.text('existing memory'), findsOneWidget);
    await tester.tap(find.text('memory_books_btn_regenerate'));
    expect(regenerations, 1);
  });

  testWidgets('failed regeneration keeps content, error, and retry action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: MemoryDraftCard(
            draft: const MemoryDraft(
              id: 'draft-1',
              content: 'safe old content',
              status: 'needs_regeneration',
              error: 'request failed',
            ),
            isGenerating: false,
            generatingSince: null,
            onGenerate: () {},
            onRegenerate: () {},
            onCancel: () {},
            onApprove: () {},
            onEdit: () {},
            onDelete: () {},
          ),
        ),
      ),
    );

    expect(find.text('safe old content'), findsOneWidget);
    expect(find.text('request failed'), findsOneWidget);
    expect(find.text('memory_books_btn_regenerate'), findsOneWidget);
  });

  testWidgets(
    'active generation hides approve and edit while keeping delete available',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: MemoryDraftCard(
              draft: const MemoryDraft(
                id: 'draft-1',
                content: 'existing content',
                status: 'pending_approval',
              ),
              isGenerating: true,
              generatingSince: null,
              onGenerate: () {},
              onRegenerate: () {},
              onCancel: () {},
              onApprove: () {},
              onEdit: () {},
              onDelete: () {},
            ),
          ),
        ),
      );

      expect(find.text('memory_books_btn_approve'), findsNothing);
      expect(find.text('memory_books_btn_regenerate'), findsNothing);
      expect(find.text('action_edit'), findsNothing);
      expect(find.text('memory_books_btn_stop'), findsOneWidget);
      expect(find.text('btn_delete'), findsOneWidget);
    },
  );
}
