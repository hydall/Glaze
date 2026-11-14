import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/session_lorebook_evolution_repo.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

void main() {
  late AppDatabase db;
  late SessionLorebookEvolutionRepo repo;

  const source = 'The district is dangerous.';
  const book = Lorebook(
    id: 'book',
    name: 'Book',
    entries: [LorebookEntry(id: 'district', content: source)],
  );

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = SessionLorebookEvolutionRepo(db);
  });
  tearDown(() => db.close());

  List<LorebookAnchoredPatch> patches() => [
    LorebookAnchoredPatch(
      anchor: 'dangerous',
      anchorSha256: CardCanonicalizer.scalarSha256('dangerous'),
      value: 'dangerous but lively',
    ),
  ];

  test('applies an overlay without changing the global source', () async {
    expect(
      await repo.applyPatchesInTransaction(
        sessionId: 'session-a',
        lorebookId: 'book',
        entryId: 'district',
        baseContent: source,
        expectedContentHash: CardCanonicalizer.scalarSha256(source),
        patches: patches(),
      ),
      isTrue,
    );

    final current = await repo.applyOverlays(
      sessionId: 'session-a',
      lorebooks: const [book],
    );
    final fresh = await repo.applyOverlays(
      sessionId: 'session-b',
      lorebooks: const [book],
    );

    expect(current.single.entries.single.content, 'The district is dangerous but lively.');
    expect(fresh.single.entries.single.content, source);
    expect(book.entries.single.content, source);
  });

  test('rejects a stale overlay hash', () async {
    expect(
      await repo.applyPatchesInTransaction(
        sessionId: 'session-a',
        lorebookId: 'book',
        entryId: 'district',
        baseContent: source,
        expectedContentHash: CardCanonicalizer.scalarSha256(source),
        patches: patches(),
      ),
      isTrue,
    );

    expect(
      await repo.applyPatchesInTransaction(
        sessionId: 'session-a',
        lorebookId: 'book',
        entryId: 'district',
        baseContent: source,
        expectedContentHash: CardCanonicalizer.scalarSha256(source),
        patches: patches(),
      ),
      isFalse,
    );
  });

  test('copies the current overlay into a session branch', () async {
    await repo.applyPatchesInTransaction(
      sessionId: 'session-a',
      lorebookId: 'book',
      entryId: 'district',
      baseContent: source,
      expectedContentHash: CardCanonicalizer.scalarSha256(source),
      patches: patches(),
    );

    await repo.copyForSessionBranch(
      fromSessionId: 'session-a',
      toSessionId: 'session-branch',
    );

    final branch = await repo.applyOverlays(
      sessionId: 'session-branch',
      lorebooks: const [book],
    );
    expect(branch.single.entries.single.content, 'The district is dangerous but lively.');
  });
}
