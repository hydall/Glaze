import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_book_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/memory_entry_revisions.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final legacy = MemoryEntry(
    id: 'memory_1',
    title: 'Camp',
    content: 'Mara waits in camp.',
    keys: ['Mara'],
  );

  test(
    'legacy JSON gets a synthetic active revision without changing text',
    () {
      final decoded = MemoryEntry.fromJson(
        jsonDecode(jsonEncode(legacy.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.activeRevisionId, 'memory_1:r1');
      expect(decoded.revisions, hasLength(1));
      expect(decoded.revisions.single.reason, 'imported_legacy');
      expect(
        MemoryEntryRevisions.matchesText(decoded, decoded.revisions.single),
        isTrue,
      );
    },
  );

  test(
    'editing appends a revision and restoring old text appends another one',
    () {
      final initial = MemoryEntryRevisions.initialize(legacy);
      final edited = MemoryEntryRevisions.prepare(
        initial.copyWith(content: 'Mara left the camp.'),
        initial,
        author: 'user',
        reason: 'manual_edit',
        reviewer: 'user',
      );
      final restored = MemoryEntryRevisions.prepare(
        MemoryEntryRevisions.restoreText(edited, initial.revisions.single),
        edited,
        author: 'user',
        reason: 'restore_revision',
        reviewer: 'user',
      );

      expect(edited.revisions, hasLength(2));
      expect(edited.activeRevisionId, edited.revisions.last.id);
      expect(edited.revisions.first.content, 'Mara waits in camp.');
      expect(restored.revisions, hasLength(3));
      expect(restored.content, 'Mara waits in camp.');
      expect(restored.revisions[1].content, 'Mara left the camp.');
      expect(restored.revisions.last.reason, 'restore_revision');
    },
  );

  group('durable editor operation', () {
    late AppDatabase db;
    late ProviderContainer container;
    late MemoryBookRepo repo;
    const source = ChatMessage(
      id: 'm1',
      role: 'user',
      content: 'The camp is north.',
      time: 'day 12',
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = AppDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      repo = container.read(memoryBookRepoProvider);
      await container
          .read(chatRepoProvider)
          .put(
            const ChatSession(
              id: 'session',
              characterId: 'character',
              sessionIndex: 1,
              messages: [source],
            ),
          );
      await repo.put(
        MemoryBook(id: 'book', sessionId: 'session', entries: [legacy]),
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('revision is durable and stale editor cannot overwrite it', () async {
      final first = (await repo.getBySessionId('session'))!.entries.single;
      final revised = await repo.reviseEntry(
        sessionId: 'session',
        expected: first,
        proposed: first.copyWith(content: 'Mara leaves at dawn.'),
      );
      expect(revised, isNotNull);
      expect(revised!.revisions, hasLength(2));
      expect(revised.revisions.last.author, 'user');
      expect(revised.revisions.last.reviewer, 'user');
      expect(revised.revisions.last.reviewedAt, isNotNull);
      expect(revised.revisions.first.content, legacy.content);

      await expectLater(
        repo.reviseEntry(
          sessionId: 'session',
          expected: first,
          proposed: first.copyWith(content: 'Stale editor wins.'),
        ),
        throwsStateError,
      );
      final stored = (await repo.getBySessionId('session'))!.entries.single;
      expect(stored.content, 'Mara leaves at dawn.');
      expect(stored.revisions, hasLength(2));
    });

    test('unchanged full-book saves retain revision history', () async {
      final first = (await repo.getBySessionId('session'))!;
      expect(first.entries.single.revisions, hasLength(1));
      await repo.put(first);
      final stored = (await repo.getBySessionId('session'))!;
      expect(stored.entries.single.revisions, hasLength(1));
      expect(stored.entries.single.activeRevisionId, 'memory_1:r1');
    });

    test('rewriting an existing snapshot is rejected atomically', () async {
      final book = (await repo.getBySessionId('session'))!;
      final entry = book.entries.single;
      final forged = entry.copyWith(
        revisions: [entry.revisions.single.copyWith(content: 'Rewritten past')],
      );
      await expectLater(
        repo.put(book.copyWith(entries: [forged])),
        throwsStateError,
      );
      expect((await repo.getBySessionId('session'))!.entries.single, entry);
      expect(MemoryEntryRevisions.isUsable(forged), isFalse);
    });

    test(
      'restoring identical text still records the reviewed action',
      () async {
        final entry = (await repo.getBySessionId('session'))!.entries.single;
        final restored = await repo.restoreEntryRevision(
          sessionId: 'session',
          expected: entry,
          revisionId: entry.activeRevisionId!,
        );
        expect(restored!.revisions, hasLength(2));
        expect(restored.content, entry.content);
        expect(restored.revisions.first, entry.revisions.single);
      },
    );

    test(
      'branch copies retain snapshots and append independent history',
      () async {
        final book = (await repo.getBySessionId('session'))!;
        await repo.put(
          book.copyWith(
            entries: [
              book.entries.single.copyWith(messageIds: ['m1']),
            ],
          ),
        );
        await repo.copyForSessionBranch(
          fromSessionId: 'session',
          toSessionId: 'branch',
          messageIds: {'m1'},
        );
        final original = (await repo.getBySessionId('session'))!.entries.single;
        final branch = (await repo.getBySessionId('branch'))!.entries.single;
        expect(branch.revisions, original.revisions);
        final edited = await repo.reviseEntry(
          sessionId: 'branch',
          expected: branch,
          proposed: branch.copyWith(content: 'Only in branch'),
        );
        expect(edited!.revisions, hasLength(2));
        expect(
          (await repo.getBySessionId('session'))!.entries.single,
          original,
        );
      },
    );

    test(
      'restoring a revision appends instead of moving the active pointer back',
      () async {
        final first = (await repo.getBySessionId('session'))!.entries.single;
        final edited = await repo.reviseEntry(
          sessionId: 'session',
          expected: first,
          proposed: first.copyWith(content: 'Mara leaves at dawn.'),
        );
        final restored = await repo.restoreEntryRevision(
          sessionId: 'session',
          expected: edited!,
          revisionId: edited.revisions.first.id,
        );
        expect(restored!.revisions, hasLength(3));
        expect(restored.content, legacy.content);
        expect(restored.activeRevisionId, restored.revisions.last.id);
        expect(restored.revisions[1].content, 'Mara leaves at dawn.');
        expect(restored.revisions.last.reason, 'restore_revision');
      },
    );

    test(
      'legacy-shaped update appends instead of bypassing the history',
      () async {
        final first = (await repo.getBySessionId('session'))!.entries.single;
        final updated = first.copyWith(content: 'Changed through updateEntry.');
        expect(
          await repo.updateEntry(
            sessionId: 'session',
            entryId: first.id,
            updated: MemoryEntry(
              id: updated.id,
              title: updated.title,
              content: updated.content,
              keys: updated.keys,
            ),
          ),
          isTrue,
        );
        final stored = (await repo.getBySessionId('session'))!.entries.single;
        expect(stored.revisions, hasLength(2));
        expect(stored.content, updated.content);
      },
    );
  });
}
