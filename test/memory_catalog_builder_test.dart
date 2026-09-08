import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_catalog_repo.dart';
import 'package:glaze_flutter/core/llm/embedding_types.dart';
import 'package:glaze_flutter/core/llm/memory_catalog_builder.dart';
import 'package:glaze_flutter/core/llm/memory_injection_service.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';

void main() {
  test('builder creates deterministic catalog row from memory entry', () {
    const book = MemoryBook(
      id: 'book1',
      sessionId: 'session1',
      entries: [
        MemoryEntry(
          id: 'mem1',
          title: 'Bridge collapse',
          keys: ['bridge', 'sable'],
          content: 'The bridge fell during the storm.',
          status: 'active',
          messageRange: MessageRange(start: 2, end: 5),
          importance: 0.8,
          temporallyBlind: true,
          arc: 'river arc',
          kind: 'event',
          sourceHash: 'source-hash',
        ),
      ],
    );

    final first = MemoryCatalogBuilder.build(book, nowSeconds: 10).single;
    final second = MemoryCatalogBuilder.build(book, nowSeconds: 10).single;

    expect(first.id.value, 'session1::mem1');
    expect(first.chatSessionId.value, 'session1');
    expect(first.memoryEntryId.value, 'mem1');
    expect(first.entryRevision.value, second.entryRevision.value);
    expect(first.sourceHash.value, 'source-hash');
    expect(first.title.value, 'Bridge collapse');
    expect(jsonDecode(first.keysJson.value), ['bridge', 'sable']);
    expect(jsonDecode(first.locationsJson.value), ['river arc']);
    expect(jsonDecode(first.topicsJson.value), ['event']);
    expect(first.messageRangeStart.value, 2);
    expect(first.messageRangeEnd.value, 5);
    expect(first.importance.value, 0.8);
    expect(first.temporallyBlind.value, true);
    expect(first.tokenCount.value, greaterThan(0));
    expect(first.abstractText.value, 'The bridge fell during the storm.');
    expect(first.status.value, 'active');
    expect(first.stale.value, false);
  });

  test(
    'entry revision changes when content keys status or sourceHash changes',
    () {
      const base = MemoryEntry(
        id: 'mem1',
        title: 'Memory',
        keys: ['alpha'],
        content: 'Original content',
        status: 'active',
        sourceHash: 'hash1',
      );

      String revision(MemoryEntry entry) => MemoryCatalogBuilder.buildRow(
        'session1',
        entry,
        nowSeconds: 1,
      ).entryRevision.value;

      final baseRevision = revision(base);
      expect(
        revision(base.copyWith(content: 'Changed content')),
        isNot(baseRevision),
      );
      expect(revision(base.copyWith(keys: ['beta'])), isNot(baseRevision));
      expect(revision(base.copyWith(status: 'disabled')), isNot(baseRevision));
      expect(revision(base.copyWith(sourceHash: 'hash2')), isNot(baseRevision));
    },
  );

  test('repo rebuild replaces stale session catalog rows', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = MemoryCatalogRepo(db);

    final initial = MemoryBook(
      id: 'book1',
      sessionId: 'session1',
      entries: const [
        MemoryEntry(
          id: 'mem1',
          title: 'Old title',
          keys: ['old'],
          content: 'Old content',
          status: 'active',
        ),
      ],
    );
    final updated = initial.copyWith(
      entries: const [
        MemoryEntry(
          id: 'mem1',
          title: 'New title',
          keys: ['new'],
          content: 'New content',
          status: 'active',
        ),
        MemoryEntry(
          id: 'mem2',
          title: 'Second',
          keys: ['second'],
          content: 'Second content',
          status: 'disabled',
        ),
      ],
    );

    final firstRows = await repo.rebuildForMemoryBook(initial);
    final oldRevision = firstRows.single.entryRevision;

    final secondRows = await repo.rebuildForMemoryBook(updated);

    expect(secondRows, hasLength(2));
    expect(secondRows.map((row) => row.memoryEntryId), ['mem1', 'mem2']);
    expect(secondRows.first.title, 'New title');
    expect(secondRows.first.keys, ['new']);
    expect(secondRows.first.entryRevision, isNot(oldRevision));
    expect(secondRows[1].status, 'disabled');
  });

  test(
    'catalog-assisted retrieval selects full memory entry content only',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      addTearDown(db.close);

      const book = MemoryBook(
        id: 'book1',
        sessionId: 'session1',
        settings: MemoryBookSettings(memoryMode: 'balanced'),
        entries: [
          MemoryEntry(
            id: 'mem1',
            title: 'Bridge collapse',
            keys: ['bridge', 'sable'],
            content:
                'FULL MEMORY: Sable promised to meet at the broken bridge.',
            status: 'active',
          ),
          MemoryEntry(
            id: 'mem2',
            title: 'Unrelated tavern',
            keys: ['tavern'],
            content: 'FULL MEMORY: The tavern had blue curtains.',
            status: 'active',
          ),
        ],
      );
      await container.read(memoryBookRepoProvider).put(book);
      await container
          .read(memoryCatalogRepoProvider)
          .rebuildForMemoryBook(book);
      await container
          .read(memoryCatalogRepoProvider)
          .updateAbstractText(
            sessionId: 'session1',
            memoryEntryId: 'mem1',
            abstractText: 'CATALOG ABSTRACT ONLY: do not inject this wording.',
          );

      final result = await container
          .read(memoryInjectionServiceProvider)
          .buildInjection(
            sessionId: 'session1',
            historyText: '',
            messageCount: 1,
            currentText: 'Do you remember Sable and the bridge?',
            history: const [
              ChatMessageForSearch(
                role: 'user',
                content: 'Do you remember Sable and the bridge?',
              ),
            ],
            contextBudgetTokens: 10000,
          );

      expect(result.entries.first.id, 'mem1');
      expect(result.content, contains('FULL MEMORY: Sable promised'));
      expect(result.content, isNot(contains('CATALOG ABSTRACT ONLY')));
      expect(result.content, isNot(contains('Sable and the bridge?')));
      expect(
        result.memoryDiagnostics!.candidates.first.catalogScore,
        greaterThan(0),
      );
      expect(
        result.memoryDiagnostics!.candidates.first.catalogMatchedTerms,
        containsAll(['bridge', 'sable']),
      );
    },
  );

  test('fast mode skips catalog-assisted scoring', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);

    const book = MemoryBook(
      id: 'book1',
      sessionId: 'session_fast',
      settings: MemoryBookSettings(memoryMode: 'fast'),
      entries: [
        MemoryEntry(
          id: 'mem1',
          title: 'Bridge collapse',
          keys: ['bridge'],
          content: 'FULL MEMORY: The bridge collapsed.',
          status: 'active',
        ),
      ],
    );
    await container.read(memoryBookRepoProvider).put(book);
    await container.read(memoryCatalogRepoProvider).rebuildForMemoryBook(book);

    final result = await container
        .read(memoryInjectionServiceProvider)
        .buildInjection(
          sessionId: 'session_fast',
          historyText: '',
          messageCount: 1,
          currentText: 'bridge',
          history: const [
            ChatMessageForSearch(role: 'user', content: 'bridge'),
          ],
          contextBudgetTokens: 10000,
        );

    expect(result.memoryDiagnostics!.memoryMode, 'fast');
    expect(result.memoryDiagnostics!.candidates.single.catalogScore, 0);
    expect(
      result.memoryDiagnostics!.candidates.single.catalogMatchedTerms,
      isEmpty,
    );
  });
}
