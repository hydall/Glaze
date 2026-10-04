import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/memory_injection_service.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/memory_source_manifest.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const first = ChatMessage(
    id: 'a',
    role: 'user',
    content: 'Where is Mara?',
    time: 'day 12',
  );
  const second = ChatMessage(
    id: 'b',
    role: 'assistant',
    content: 'In camp.',
    swipeId: 2,
    agentSwipeId: 1,
  );
  final sources = [first, second];
  final manifest = MemorySourceManifest.capture('s', sources, ['a', 'b']);

  test(
    'manifest survives full book JSON and distinguishes missing provenance',
    () {
      final book = MemoryBook(
        id: 'book',
        sessionId: 's',
        entries: [
          MemoryEntry(
            id: 'verified',
            messageIds: ['a', 'b'],
            sourceManifest: manifest,
          ),
          const MemoryEntry(id: 'legacy'),
        ],
      );
      final restored = MemoryBook.fromJson(
        jsonDecode(jsonEncode(book.toJson())) as Map<String, dynamic>,
      );
      expect(restored.entries.first.sourceManifest, manifest);
      expect(
        restored.entries.first.sourceManifest!.validate(['a', 'b'], sources),
        MemorySourceValidity.verified,
      );
      expect(restored.entries.last.sourceManifest, isNull);
    },
  );

  test(
    'selected text, swipe, visibility, clock, deletion and order invalidate evidence',
    () {
      for (final changed in [
        second.copyWith(content: 'Elsewhere.'),
        second.copyWith(swipeId: 1),
        second.copyWith(agentSwipeId: 0),
        second.copyWith(isHidden: true),
        second.copyWith(time: 'day 37'),
        second.copyWith(isError: true),
      ]) {
        expect(
          manifest.validate(['a', 'b'], [first, changed]),
          MemorySourceValidity.invalid,
        );
      }
      expect(
        manifest.validate(['a', 'b'], [first]),
        MemorySourceValidity.invalid,
      );
      expect(
        manifest.validate(['a', 'b'], [second, first]),
        MemorySourceValidity.invalid,
      );
      expect(manifest.validate(['b'], sources), MemorySourceValidity.invalid);
      expect(
        manifest.validate(
          ['a', 'b'],
          [first, second.copyWith(tokens: 100, genTime: '10s')],
        ),
        MemorySourceValidity.verified,
      );
    },
  );

  test(
    'malformed provenance is retained as invalid instead of dropping its book',
    () {
      final book = MemoryBook.fromJson({
        'id': 'book',
        'sessionId': 's',
        'entries': [
          {'id': 'broken', 'sourceManifest': 'not-a-map'},
        ],
      });
      expect(book.entries, hasLength(1));
      expect(book.entries.single.sourceManifest?.invalidated, isTrue);
    },
  );

  test('deleting an earlier swipe shifts only its own source anchor', () {
    final shifted = manifest.removeVariation('b', 0, null);
    expect(
      shifted.validate(['a', 'b'], [first, second.copyWith(swipeId: 1)]),
      MemorySourceValidity.verified,
    );
    final deleted = manifest.removeVariation('b', 2, 1);
    expect(deleted.validate(['a', 'b'], sources), MemorySourceValidity.invalid);
    expect(
      deleted.messages.last.contentHash,
      manifest.messages.last.contentHash,
    );
  });

  group('durable approval and retention', () {
    late AppDatabase db;
    late ProviderContainer container;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = AppDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      await container
          .read(chatRepoProvider)
          .put(
            ChatSession(
              id: 's',
              characterId: 'c',
              sessionIndex: 1,
              messages: sources,
            ),
          );
    });
    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('ordinary retrieval does not rescan old evidence text', () async {
      final repo = container.read(memoryBookRepoProvider);
      await repo.put(
        MemoryBook(
          id: 'book',
          sessionId: 's',
          entries: [
            MemoryEntry(
              id: 'verified',
              content: 'Mara in camp',
              keys: ['Mara'],
              messageIds: ['a', 'b'],
              sourceManifest: manifest,
            ),
            const MemoryEntry(
              id: 'legacy',
              content: 'Mara legacy history',
              keys: ['Mara'],
            ),
          ],
        ),
      );
      final service = container.read(memoryInjectionServiceProvider);
      final valid = await service.buildCandidates(
        sessionId: 's',
        history: sources,
        currentText: 'Mara',
      );
      expect(valid.allScores.map((s) => s.entry.id), contains('verified'));
      final invalid = await service.buildCandidates(
        sessionId: 's',
        history: [
          first,
          second.copyWith(content: 'Changed'),
        ],
        currentText: 'Mara',
      );
      expect(invalid.allScores.map((s) => s.entry.id), contains('verified'));
      expect(invalid.allScores.map((s) => s.entry.id), contains('legacy'));
    });

    test(
      'approval preserves stamps without rescanning old text and deletion retains history',
      () async {
        final repo = container.read(memoryBookRepoProvider);
        final draft = MemoryDraft(
          id: 'draft_1',
          content: 'Mara was in camp.',
          messageIds: ['a', 'b'],
          sourceManifest: manifest,
          status: 'pending_approval',
        );
        await repo.put(
          MemoryBook(id: 'book', sessionId: 's', pendingDrafts: [draft]),
        );
        await container
            .read(chatRepoProvider)
            .put(
              ChatSession(
                id: 's',
                characterId: 'c',
                sessionIndex: 1,
                messages: [
                  first,
                  second.copyWith(content: 'Dead.'),
                ],
              ),
            );
        final approved = await repo.approveDraft('s', draft.id, draft);
        expect(approved!.entries.single.sourceManifest, manifest);
        expect(await repo.areEntriesCurrent('s', approved.entries), isTrue);
        await repo.updateEntry(
          sessionId: 's',
          entryId: approved.entries.single.id,
          updated: approved.entries.single.copyWith(
            content: 'Edited after preparation',
          ),
        );
        expect(await repo.areEntriesCurrent('s', approved.entries), isFalse);
        await repo.deleteForMessage('s', 'b');
        final retained = (await repo.getBySessionId('s'))!.entries.single;
        expect(retained.content, 'Edited after preparation');
        expect(retained.sourceManifest!.invalidated, isTrue);
      },
    );

    test(
      'late generated text stays reviewable and branch copy retains evidence',
      () async {
        final repo = container.read(memoryBookRepoProvider);
        await container
            .read(chatRepoProvider)
            .put(
              ChatSession(
                id: 's',
                characterId: 'c',
                sessionIndex: 1,
                messages: [first],
              ),
            );
        await repo.put(
          MemoryBook(
            id: 'book',
            sessionId: 's',
            pendingDrafts: [
              MemoryDraft(
                id: 'draft',
                content: 'Late result',
                messageIds: ['a', 'b'],
                sourceManifest: manifest,
                status: 'pending_approval',
              ),
            ],
            entries: [
              MemoryEntry(
                id: 'entry',
                content: 'Stored history',
                messageIds: ['a', 'b'],
                sourceManifest: manifest,
              ),
            ],
          ),
        );
        final book = (await repo.getBySessionId('s'))!;
        expect(book.pendingDrafts.single.status, 'pending_approval');
        expect(book.pendingDrafts.single.content, 'Late result');
        await repo.copyForSessionBranch(
          fromSessionId: 's',
          toSessionId: 'branch',
          messageIds: {'a', 'b'},
        );
        expect(
          (await repo.getBySessionId('branch'))!.entries.single.sourceManifest,
          manifest,
        );
      },
    );
  });
}
