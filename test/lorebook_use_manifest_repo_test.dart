import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_use_manifest_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_deletion_repo.dart';
import 'package:glaze_flutter/core/llm/prompt/exact_lorebook_manifest.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';

void main() {
  late AppDatabase db;
  late LorebookUseManifestRepo repo;
  const identity = LorebookUseGenerationIdentity(
    sessionId: 'session',
    messageId: 'message',
    swipeId: 1,
    agentSwipeId: 2,
  );
  late LorebookUseManifestInput manifest;
  late List<LorebookUseManifestEntryInput> entries;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = LorebookUseManifestRepo(db);
    final durable = _manifest();
    manifest = LorebookUseManifestInput(
      manifestJson: durable.canonicalJson,
      manifestHash: durable.canonicalHash,
      manifestSchemaVersion: 1,
      finalPromptHash: durable.providerMessagesHash,
      presetSnapshotHash: durable.promptProvenance.presetSnapshotHash,
    );
    entries = [
      LorebookUseManifestEntryInput(
        lorebookId: durable.entries.single.lorebookId,
        entryId: durable.entries.single.entryId,
        entryOrder: 0,
        evidenceJson: jsonEncode(durable.entries.single.toJson()),
      ),
    ];
  });
  tearDown(() => db.close());

  test(
    'allows byte-identical manifest replay but rejects conflicting replay',
    () async {
      await repo.insertGenerationManifest(
        identity: identity,
        manifest: manifest,
        createdAt: 10,
        entries: entries,
      );
      await repo.insertGenerationManifest(
        identity: identity,
        manifest: manifest,
        createdAt: 10,
        entries: entries,
      );
      await expectLater(
        repo.insertGenerationManifest(
          identity: identity,
          manifest: const LorebookUseManifestInput(
            manifestJson: '{"different":true}',
            manifestHash: 'other',
            manifestSchemaVersion: 1,
            finalPromptHash: 'final-prompt-hash',
            presetSnapshotHash: 'preset-hash',
          ),
          createdAt: 10,
          entries: entries,
        ),
        throwsA(isA<LorebookUseManifestIntegrityConflict>()),
      );
      expect(await repo.getEvidence(identity), hasLength(1));
    },
  );

  test('enforces variation acceptance semantics and idempotency', () async {
    await repo.insertGenerationManifest(
      identity: identity,
      manifest: manifest,
      createdAt: 10,
      entries: entries,
    );
    await repo.insertVariationAcceptance(
      acceptanceId: 'variation',
      identity: identity,
      acceptedByUserMessageId: 'next-user',
      acceptedAt: 11,
    );
    await repo.insertVariationAcceptance(
      acceptanceId: 'variation',
      identity: identity,
      acceptedByUserMessageId: 'next-user',
      acceptedAt: 11,
    );
    await expectLater(
      repo.insertVariationAcceptance(
        acceptanceId: 'variation-two',
        identity: identity,
        acceptedByUserMessageId: 'other-next-user',
        acceptedAt: 12,
      ),
      throwsA(isA<LorebookUseManifestIntegrityConflict>()),
    );
    await expectLater(
      repo.insertVariationAcceptance(
        acceptanceId: 'variation',
        identity: identity,
        acceptedByUserMessageId: 'different-next-user',
        acceptedAt: 11,
      ),
      throwsA(isA<LorebookUseManifestIntegrityConflict>()),
    );
    final accepted = await repo.getVariationAcceptances('session');
    expect(accepted, hasLength(1));
    expect(accepted.single.acceptedByUserMessageId, 'next-user');
  });

  test('immutability and session cleanup retain no orphaned evidence', () async {
    await repo.insertGenerationManifest(
      identity: identity,
      manifest: manifest,
      createdAt: 10,
      entries: entries,
    );
    await expectLater(
      db.customStatement(
        "UPDATE lorebook_use_manifests SET manifest_json = '{}' WHERE session_id = 'session'",
      ),
      throwsA(anything),
    );
    await db.customStatement(
      "INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) VALUES ('session', 'char', 0, '[]')",
    );
    await SessionDeletionRepo(db).deleteSession('session');
    expect(await repo.getEvidence(identity), isEmpty);
    expect(await repo.getVariationAcceptances('session'), isEmpty);
  });

  test(
    'rejects raw hash and child projection bypasses before insertion',
    () async {
      await expectLater(
        repo.insertGenerationManifest(
          identity: identity,
          manifest: LorebookUseManifestInput(
            manifestJson: manifest.manifestJson,
            manifestHash: 'forged-hash',
            manifestSchemaVersion: 1,
            finalPromptHash: manifest.finalPromptHash,
            presetSnapshotHash: manifest.presetSnapshotHash,
          ),
          createdAt: 10,
          entries: entries,
        ),
        throwsA(isA<LorebookUseManifestIntegrityConflict>()),
      );
      await expectLater(
        repo.insertGenerationManifest(
          identity: identity,
          manifest: manifest,
          createdAt: 10,
          entries: [
            LorebookUseManifestEntryInput(
              lorebookId: 'book',
              entryId: 'entry',
              entryOrder: 0,
            ),
          ],
        ),
        throwsA(isA<LorebookUseManifestIntegrityConflict>()),
      );
      expect(await repo.getEvidence(identity), isEmpty);
    },
  );
}

ExactLorebookManifest _manifest() => ExactLorebookManifest(
  entries: [
    ExactLorebookManifestEntry.fromMergedEntry(
      entry: const LorebookEntry(
        id: 'entry',
        lorebookId: 'book',
        content: 'lore',
        position: 'worldInfoBefore',
        order: 1,
      ),
      source: 'keyword',
      classification: 'worldInfoBefore',
      injectionIndex: 0,
      renderedContent: 'rendered lore',
    ),
  ],
  promptProvenance: const ExactLorebookPromptProvenance(
    characterId: 'character',
    presetSnapshotHash: 'preset-hash',
  ),
  providerMessagesHash: 'final-prompt-hash',
);
