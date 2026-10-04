import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/widgets/memory/memory_draft_card.dart';
import 'package:glaze_flutter/features/chat/widgets/memory/memory_entry_card.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_sheet.dart';

import 'helpers/pump_localized.dart';

const _sessionId = 'session-search';
const _charId = 'char-search';

/// A chat that only has to answer "which session is open" — the memory sheet
/// reads nothing else off it at build time.
class _StubChat extends ChatNotifier {
  _StubChat(super.arg);

  @override
  Future<ChatState> build() async => const ChatState(
    session: ChatSession(id: _sessionId, characterId: _charId, sessionIndex: 0),
  );
}

/// One approved memory and one draft that share a word, plus one of each that
/// does not — so a query can be shown to cross the tab boundary and still
/// narrow.
Future<AppDatabase> _seedDb() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [appDbProvider.overrideWithValue(db)],
  );
  final repo = container.read(memoryBookRepoProvider);
  final book = await repo.ensureForSession(_sessionId);
  await repo.put(
    book.copyWith(
      entries: const [
        MemoryEntry(
          id: 'e1',
          title: 'Harbor theft',
          content: 'The key went missing on the pier.',
          status: 'active',
          createdAt: 1,
        ),
        MemoryEntry(
          id: 'e2',
          title: 'Guild contract',
          content: 'Signed under the seal.',
          status: 'active',
          createdAt: 2,
        ),
      ],
      pendingDrafts: const [
        MemoryDraft(
          id: 'd1',
          title: 'Harbor talk',
          content: 'They argued about the pier all evening.',
          status: 'pending_approval',
          createdAt: 3,
        ),
        MemoryDraft(
          id: 'd2',
          title: 'Campfire',
          content: 'A quiet night.',
          status: 'pending_approval',
          createdAt: 4,
        ),
      ],
    ),
  );
  container.dispose();
  return db;
}

Future<void> _pumpSheet(WidgetTester tester, AppDatabase db) async {
  await pumpLocalized(
    tester,
    const MemorySheet(charId: _charId, initialTab: MemoryTab.books),
    overrides: [
      appDbProvider.overrideWithValue(db),
      vectorSearchAvailableProvider.overrideWithValue(false),
      chatProvider(_charId).overrideWith(() => _StubChat(_charId)),
    ],
    surfaceSize: const Size(412, 1000),
  );
  // SheetView measures its header after layout and republishes the height as
  // MediaQuery padding, so the body needs a few frames before the first row
  // clears the header.
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  testWidgets('the search button replaces the tab strip with a search bar', (
    tester,
  ) async {
    final db = await _seedDb();
    addTearDown(db.close);
    await _pumpSheet(tester, db);

    // The books tab's own strip; the sheet's Summary/Books strip above it has
    // no search button of its own.
    expect(find.text('memory_books_search_hint'.tr()), findsNothing);
    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle();

    expect(find.text('memory_books_search_hint'.tr()), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsNothing);
  });

  testWidgets('search results list approved memories and drafts together', (
    tester,
  ) async {
    final db = await _seedDb();
    addTearDown(db.close);
    await _pumpSheet(tester, db);

    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'harbor');
    await tester.pumpAndSettle();

    // One of each, from the two tabs at once.
    expect(find.byType(MemoryEntryCard), findsOneWidget);
    expect(find.byType(MemoryDraftCard), findsOneWidget);
    expect(find.text('Harbor theft'), findsOneWidget);
    expect(find.text('Harbor talk'), findsOneWidget);
    expect(find.text('Guild contract'), findsNothing);
    expect(find.text('Campfire'), findsNothing);

    // Each row says which list it came from, under its title.
    expect(find.text('memory_books_status_approved'.tr()), findsOneWidget);
    expect(find.text('memory_books_pending_approval'.tr()), findsOneWidget);
  });

  testWidgets('the cross restores the tabs and drops the query', (
    tester,
  ) async {
    final db = await _seedDb();
    addTearDown(db.close);
    await _pumpSheet(tester, db);

    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'harbor');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(find.text('memory_books_search_hint'.tr()), findsNothing);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    // Back on the Approved tab, unnarrowed: the draft that the query had
    // matched is on the other tab again.
    expect(find.text('Harbor theft'), findsOneWidget);
    expect(find.text('Guild contract'), findsOneWidget);
    expect(find.byType(MemoryDraftCard), findsNothing);
  });
}
