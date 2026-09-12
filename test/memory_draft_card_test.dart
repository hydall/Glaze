import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
      ProviderScope(
        // The row's buttons are GlassSurface, which reads the active theme
        // preset.
        child: MaterialApp(
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
      ),
    );

    expect(find.text('1-15 · $range'), findsOneWidget);
  });

  testWidgets('content-bearing pending draft offers explicit regeneration', (
    tester,
  ) async {
    var regenerations = 0;
    await tester.pumpWidget(
      ProviderScope(
        // The row's buttons are GlassSurface, which reads the active theme
        // preset.
        child: MaterialApp(
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
      ),
    );

    // The per-row actions are icon buttons; the word survives as the tooltip
    // and the semantics label, which is what the assertions target.
    expect(find.byTooltip('memory_books_btn_regenerate'), findsOneWidget);
    expect(find.text('existing memory'), findsOneWidget);
    await tester.tap(find.byTooltip('memory_books_btn_regenerate'));
    expect(regenerations, 1);
  });

  testWidgets('failed regeneration keeps content, error, and retry action', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        // The row's buttons are GlassSurface, which reads the active theme
        // preset.
        child: MaterialApp(
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
      ),
    );

    expect(find.text('safe old content'), findsOneWidget);
    expect(find.text('request failed'), findsOneWidget);
    expect(find.byTooltip('memory_books_btn_regenerate'), findsOneWidget);
  });

  testWidgets(
    'active generation hides approve and edit while keeping delete available',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          // The row's buttons are GlassSurface, which reads the active theme
          // preset.
          child: MaterialApp(
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
        ),
      );

      expect(find.byTooltip('memory_books_btn_approve'), findsNothing);
      expect(find.byTooltip('memory_books_btn_regenerate'), findsNothing);
      expect(find.byTooltip('action_edit'), findsNothing);
      expect(find.byTooltip('memory_books_btn_stop'), findsOneWidget);
      expect(find.byTooltip('btn_delete'), findsOneWidget);
    },
  );
  testWidgets('a retry in flight does not show the failure it is retrying', (
    tester,
  ) async {
    // The draft stays `needs_regeneration` until the new attempt lands, so the
    // card used to carry "Generating..." and the previous failure at once.
    await tester.pumpWidget(
      ProviderScope(
        // The row's buttons are GlassSurface, which reads the active theme
        // preset.
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: MemoryDraftCard(
              draft: const MemoryDraft(
                id: 'draft-1',
                content: 'safe old content',
                status: 'needs_regeneration',
                error: 'HTTP 400 - Bad Request',
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
      ),
    );

    expect(find.text('safe old content'), findsOneWidget);
    expect(find.text('HTTP 400 - Bad Request'), findsNothing);
    expect(find.byTooltip('memory_books_btn_stop'), findsOneWidget);
  });
}
