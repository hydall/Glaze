import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/features/memory/controllers/memory_book_write_queue.dart';
import 'package:glaze_flutter/features/memory/controllers/memory_draft_generation_update.dart';

void main() {
  const original = MemoryDraft(
    id: 'draft-1',
    title: 'Current title',
    content: 'old content',
    keys: ['old'],
    status: 'pending_approval',
  );

  MemoryBook bookWith(List<MemoryDraft> drafts) =>
      MemoryBook(id: 'book-1', sessionId: 'session-1', pendingDrafts: drafts);

  test('successful regeneration replaces content by ID and clears error', () {
    final book = bookWith([
      const MemoryDraft(id: 'other', content: 'untouched'),
      original.copyWith(error: 'old error'),
    ]);
    const generated = MemoryDraft(
      id: 'draft-1',
      title: 'stale request title',
      content: 'new content',
      keys: ['new'],
      keyParagraphs: {
        'new': [0],
      },
      ledgerRange:
          '15.09.2026 · RP_Day 0 · 21:00 -> '
          '15.09.2026 · RP_Day 0 · 21:30',
      status: 'pending_approval',
      generatedAt: 20,
      updatedAt: 21,
    );

    final updated = applyGeneratedMemoryDraft(
      book,
      draftId: 'draft-1',
      generated: generated,
    )!;

    expect(updated.pendingDrafts.first.content, 'untouched');
    final draft = updated.pendingDrafts.last;
    expect(draft.content, 'new content');
    expect(draft.keys, ['new']);
    expect(draft.keyParagraphs, {
      'new': [0],
    });
    expect(draft.ledgerRange, generated.ledgerRange);
    expect(draft.title, 'Current title');
    expect(draft.status, 'pending_approval');
    expect(draft.error, isNull);
  });

  test('failed regeneration preserves old content and remains retryable', () {
    final updated = applyFailedMemoryDraftGeneration(
      bookWith([original]),
      draftId: 'draft-1',
      error: 'network failed',
      updatedAt: 30,
    )!;

    final draft = updated.pendingDrafts.single;
    expect(draft.content, 'old content');
    expect(draft.keys, ['old']);
    expect(draft.status, 'needs_regeneration');
    expect(draft.error, 'network failed');
  });

  test('completion after deletion is ignored without resurrecting draft', () {
    final book = bookWith([const MemoryDraft(id: 'other')]);

    expect(
      applyGeneratedMemoryDraft(book, draftId: 'draft-1', generated: original),
      isNull,
    );
    expect(
      applyFailedMemoryDraftGeneration(
        book,
        draftId: 'draft-1',
        error: 'late error',
        updatedAt: 40,
      ),
      isNull,
    );
    expect(book.pendingDrafts, hasLength(1));
  });

  test(
    'parallel completions from one initial snapshot preserve both results',
    () async {
      var current = bookWith([
        const MemoryDraft(id: 'draft-1'),
        const MemoryDraft(id: 'draft-2'),
      ]);
      final persisted = <MemoryBook>[];
      final writes = MemoryBookWriteQueue(
        readLatest: () => current,
        publish: (book) => current = book,
        persist: (book) async => persisted.add(book),
      );
      const firstResult = MemoryDraft(id: 'draft-1', content: 'first result');
      const secondResult = MemoryDraft(id: 'draft-2', content: 'second result');

      final first = writes.mutate(
        (latest) => applyGeneratedMemoryDraft(
          latest,
          draftId: 'draft-1',
          generated: firstResult,
        ),
      );
      final second = writes.mutate(
        (latest) => applyGeneratedMemoryDraft(
          latest,
          draftId: 'draft-2',
          generated: secondResult,
        ),
      );
      await Future.wait([first, second]);

      expect(current.pendingDrafts[0].content, 'first result');
      expect(current.pendingDrafts[1].content, 'second result');
      expect(persisted.last.pendingDrafts[0].content, 'first result');
      expect(persisted.last.pendingDrafts[1].content, 'second result');
    },
  );

  test('delete during an in-flight generation write wins', () async {
    var current = bookWith([original]);
    final firstWriteStarted = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    final persisted = <MemoryBook>[];
    final writes = MemoryBookWriteQueue(
      readLatest: () => current,
      publish: (book) => current = book,
      persist: (book) async {
        persisted.add(book);
        if (!firstWriteStarted.isCompleted) {
          firstWriteStarted.complete();
          await releaseFirstWrite.future;
        }
      },
    );

    final generation = writes.mutate(
      (latest) => applyGeneratedMemoryDraft(
        latest,
        draftId: 'draft-1',
        generated: original.copyWith(content: 'late result'),
      ),
    );
    await firstWriteStarted.future;

    current = current.copyWith(pendingDrafts: []);
    final deletion = writes.saveLatest();
    releaseFirstWrite.complete();
    await Future.wait([generation, deletion]);

    expect(current.pendingDrafts, isEmpty);
    expect(persisted.last.pendingDrafts, isEmpty);
  });
}
