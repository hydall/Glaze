import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_canon_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/sync_session_consistency_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

void main() {
  test(
    'post-pull reconciliation removes orphan snapshots and restores Ledger',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      const sessionId = 'session';
      const chat = ChatSession(
        id: sessionId,
        characterId: 'character',
        sessionIndex: 0,
        messages: [
          ChatMessage(id: 'm0', role: 'user', content: 'before'),
          ChatMessage(id: 'm1', role: 'assistant', content: 'accepted'),
        ],
      );
      await ChatRepo(db).put(chat);
      final snapshots = TrackerSnapshotRepo(db);
      Tracker location(String messageId, String value) => Tracker(
        sessionId: sessionId,
        name: 'scene.location',
        value: value,
        scope: 'ledger',
        provenance: messageId,
      );
      await snapshots.upsertTrackers(
        sessionId: sessionId,
        messageId: 'm1',
        swipeId: 0,
        agentSwipeId: 0,
        trackers: [location('m1', 'accepted')],
        committed: true,
      );
      await snapshots.upsertTrackers(
        sessionId: sessionId,
        messageId: 'deleted',
        swipeId: 0,
        agentSwipeId: 0,
        trackers: [location('deleted', 'stale')],
        committed: true,
      );
      final trackers = TrackerRepo(db);
      await trackers.upsert(location('deleted', 'stale'));

      await SyncSessionConsistencyRepo(db).reconcile({sessionId});

      expect(
        (await snapshots.getBySessionId(sessionId)).map((s) => s.messageId),
        ['m1'],
      );
      expect(
        (await trackers.get(sessionId, 'scene.location'))?.value,
        'accepted',
      );
    },
  );

  test('rejects live snapshots from canon that was rolled back', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    const sessionId = 'session';
    const original = Character(
      id: 'original',
      name: 'Card',
      description: 'old',
    );
    const fork = Character(id: 'fork', name: 'Card', description: 'new');
    await db
        .into(db.characters)
        .insert(
          CharactersCompanion.insert(
            charId: 'original',
            name: 'Card',
            description: Value('old'),
          ),
        );
    await db
        .into(db.characters)
        .insert(
          CharactersCompanion.insert(
            charId: 'fork',
            name: 'Card',
            description: Value('new'),
          ),
        );
    final revisions = CharacterRevisionRepo(db);
    Future<void> addRevision(Character card) => revisions.insert(
      CharacterRevisionRecord(
        characterId: card.id,
        revision: 1,
        revisionHash: CardCanonicalizer.sha256(card),
        parentRevisionHash: '',
        snapshotJson: jsonEncode(card.toJson()),
        createdAt: 1,
      ),
    );
    await addRevision(original);
    await addRevision(fork);
    const chat = ChatSession(
      id: sessionId,
      characterId: 'fork',
      sessionIndex: 0,
      messages: [
        ChatMessage(id: 'old', role: 'assistant', content: 'old base'),
        ChatMessage(id: 'new', role: 'assistant', content: 'new turn'),
      ],
    );
    await ChatRepo(db).put(chat);
    final checkpoints = SessionCanonCheckpointRepo(db);
    final root = await checkpoints.appendRootInTransaction(
      sessionId: sessionId,
      characterId: original.id,
      characterRevision: 1,
      characterRevisionHash: CardCanonicalizer.sha256(original),
    );
    await checkpoints.appendInTransaction(
      sessionId: sessionId,
      expectedParentCheckpointId: root.id,
      characterId: fork.id,
      characterRevision: 1,
      characterRevisionHash: CardCanonicalizer.sha256(fork),
      rewriteJobId: 'rewrite',
      anchor: const SessionCanonCheckpointAnchor(
        messageId: 'deleted-anchor',
        swipeId: 0,
        agentSwipeId: 0,
      ),
    );
    final snapshots = TrackerSnapshotRepo(db);
    Tracker clock(String messageId, String value, String hash) => Tracker(
      sessionId: sessionId,
      name: 'world:time',
      value: value,
      scope: 'ledger',
      provenance: messageId,
      basisRevisionNumber: 1,
      basisRevisionHash: hash,
    );
    await snapshots.upsertTrackers(
      sessionId: sessionId,
      messageId: 'old',
      swipeId: 0,
      agentSwipeId: 0,
      trackers: [clock('old', '20:50', CardCanonicalizer.sha256(original))],
      committed: true,
    );
    await snapshots.upsertTrackers(
      sessionId: sessionId,
      messageId: 'new',
      swipeId: 0,
      agentSwipeId: 0,
      trackers: [clock('new', '23:48', CardCanonicalizer.sha256(fork))],
      committed: true,
    );

    await SyncSessionConsistencyRepo(db).reconcile({sessionId});

    expect((await ChatRepo(db).getById(sessionId))?.characterId, original.id);
    expect(
      (await snapshots.getBySessionId(sessionId)).map((s) => s.messageId),
      ['old'],
    );
    expect(
      (await TrackerRepo(db).get(sessionId, 'world:time'))?.value,
      '20:50',
    );
  });
}
