import 'dart:async';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_book_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/widgets/memory/memory_draft_card.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_sheet.dart';
import 'package:glaze_flutter/features/memory/state/memory_active_drafts_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_book_revision_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_draft_jobs_provider.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';

/// The memory sheet used to own the draft-generation lifecycle, so closing it
/// mid-request threw the finished draft away: the completion wrote through the
/// sheet's own `WidgetRef`, and a ref whose widget is gone throws instead of
/// persisting. These cover what replaced it.
const _charId = 'char-jobs';
const _sessionId = 'session-jobs';
const _draftId = 'draft-1';

class _Harness {
  _Harness(this.container, this.db, this.generation);

  final ProviderContainer container;
  final AppDatabase db;

  /// Completed by the test when the "LLM" is supposed to answer.
  final Completer<MemoryDraft> generation;

  MemoryBookRepo get repo => container.read(memoryBookRepoProvider);

  bool get isRunning => container
      .read(memoryDraftJobsProvider)
      .isGenerating(_sessionId, _draftId);

  Future<MemoryDraft> get persistedDraft async =>
      (await repo.getBySessionId(_sessionId))!.pendingDrafts.single;

  Future<void> startGeneration() => container
      .read(memoryDraftJobsProvider.notifier)
      .generate(sessionId: _sessionId, charId: _charId, draftId: _draftId);
}

Future<_Harness> _seed({String draftContent = ''}) async {
  SharedPreferences.setMockInitialValues({});
  ChatSessionService.clearCache();
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final generation = Completer<MemoryDraft>();
  final container = ProviderContainer(
    overrides: [
      appDbProvider.overrideWithValue(db),
      vectorSearchAvailableProvider.overrideWithValue(false),
      memoryDraftGeneratorProvider.overrideWithValue(
        ({
          required draft,
          required settings,
          required pipeline,
          required messages,
          required charId,
          required sessionId,
          required sessionVars,
          cancelToken,
        }) => generation.future,
      ),
    ],
  );
  addTearDown(() async {
    container.dispose();
    ChatSessionService.clearCache();
    await db.close();
  });

  await container
      .read(characterRepoProvider)
      .put(Character(id: _charId, name: 'Alice'));
  await container
      .read(chatRepoProvider)
      .put(
        const ChatSession(
          id: _sessionId,
          characterId: _charId,
          sessionIndex: 0,
          messages: [
            ChatMessage(id: 'm1', role: 'user', content: 'Hello', timestamp: 1),
          ],
        ),
      );
  await container
      .read(memoryBookRepoProvider)
      .put(
        MemoryBook(
          id: 'memorybook_$_sessionId',
          sessionId: _sessionId,
          pendingDrafts: [
            MemoryDraft(
              id: _draftId,
              title: 'First night',
              messageIds: const ['m1'],
              content: draftContent,
            ),
          ],
        ),
      );
  await container.read(chatProvider(_charId).future);
  return _Harness(container, db, generation);
}

/// Opens the memory sheet on the Books tab and switches to Scan drafts, which
/// is the list the rows under test live on.
Future<void> _openSheet(WidgetTester tester, _Harness harness) async {
  await tester.binding.setSurfaceSize(const Size(412, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.runAsync(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: EasyLocalization(
          supportedLocales: const [Locale('en'), Locale('ru')],
          path: 'assets/translations',
          fallbackLocale: const Locale('en'),
          startLocale: const Locale('ru'),
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: AppTheme.dark(const ThemePreset(id: 'd', name: 'D')),
              home: const Scaffold(
                body: MemorySheet(charId: _charId, initialTab: MemoryTab.books),
              ),
            ),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
  });
  await tester.tap(find.byIcon(Icons.drafts_outlined).last);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _closeSheet(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

/// Settles the harness's futures outside the fake clock the widget binding
/// uses, so the generation's own awaits can finish.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  await tester.pump();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('a generation started from the sheet outlives closing it', (
    tester,
  ) async {
    final harness = await _seed();
    await _openSheet(tester, harness);
    unawaited(harness.startGeneration());
    await _settle(tester);
    expect(harness.isRunning, isTrue);

    await _closeSheet(tester);
    harness.generation.complete(
      const MemoryDraft(
        id: _draftId,
        content: 'GENERATED',
        keys: ['night'],
        generatedAt: 5,
        updatedAt: 5,
      ),
    );
    await _settle(tester);

    final draft = await harness.persistedDraft;
    expect(draft.content, 'GENERATED');
    expect(draft.status, 'pending_approval');
    expect(harness.isRunning, isFalse);
    // And the session lease is handed back, so auto-generation is not blocked
    // out of the session for the rest of the app's life.
    expect(harness.container.read(memoryActiveDraftsProvider), isEmpty);
  });

  testWidgets('reopening the sheet finds the generation still running', (
    tester,
  ) async {
    final harness = await _seed();
    await _openSheet(tester, harness);
    unawaited(harness.startGeneration());
    await _settle(tester);

    await _closeSheet(tester);
    await _openSheet(tester, harness);

    // The row is back on its generating face: Stop, not Generate — and it
    // still counts from when the request actually went out.
    final row = find.byType(MemoryDraftCard);
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.stop_rounded)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.byIcon(Icons.auto_awesome_rounded),
      ),
      findsNothing,
    );
    expect(
      harness.container
          .read(memoryDraftJobsProvider)
          .startedAt(_sessionId, _draftId),
      isNotNull,
    );

    harness.generation.complete(
      const MemoryDraft(id: _draftId, content: 'GENERATED', updatedAt: 5),
    );
    await _settle(tester);
  });

  testWidgets('a generation that lands while the sheet is open shows up', (
    tester,
  ) async {
    final harness = await _seed();
    await _openSheet(tester, harness);
    unawaited(harness.startGeneration());
    await _settle(tester);

    harness.generation.complete(
      const MemoryDraft(id: _draftId, content: 'GENERATED', updatedAt: 5),
    );
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('GENERATED'), findsOneWidget);
  });

  testWidgets('drafts written from outside reach an open sheet', (
    tester,
  ) async {
    // What the auto-create stage does during a chat turn: it writes to the
    // repository and publishes the change. The sheet holds the book it read
    // when it opened, so without that it showed neither.
    final harness = await _seed();
    await _openSheet(tester, harness);
    expect(find.text('Auto draft'), findsNothing);

    await tester.runAsync(() async {
      await harness.repo.appendDrafts(_sessionId, const [
        MemoryDraft(id: 'draft-2', title: 'Auto draft', messageIds: ['m1']),
      ]);
    });
    harness.container.read(memoryBookRevisionProvider.notifier).state++;
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Auto draft'), findsOneWidget);

    harness.generation.complete(
      const MemoryDraft(id: _draftId, content: 'x', updatedAt: 5),
    );
  });
}
