import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/features/chat/widgets/memory/memory_entry_card.dart';

void main() {
  testWidgets('shows the Ledger range in an approved entry header', (
    tester,
  ) async {
    const range =
        '19.09.2026 · RP_Day 0 · 19:20 -> 19.09.2026 · RP_Day 0 · 19:35';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryEntryCard(
            entry: const MemoryEntry(
              id: 'entry-1',
              title: '1-15',
              content: 'Approved memory',
              ledgerRange: range,
            ),
            embeddingStatus: null,
            onEdit: () {},
            onDelete: () {},
          ),
        ),
      ),
    );

    expect(find.text('1-15 · $range'), findsOneWidget);
  });
}
