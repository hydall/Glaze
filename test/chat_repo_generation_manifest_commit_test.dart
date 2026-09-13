import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_use_manifest_repo.dart';
import 'package:glaze_flutter/core/llm/prompt/exact_lorebook_manifest.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';

void main() {
  late AppDatabase db;
  late ChatRepo chatRepo;
  late LorebookUseManifestRepo manifestRepo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chatRepo = ChatRepo(db);
    manifestRepo = LorebookUseManifestRepo(db);
  });
  tearDown(() => db.close());

  test('initial commit atomically stores the exact assistant variation manifest', () async {
    final base = _session();
    final generated = base.copyWith(
      updatedAt: 10,
      sessionVars: const {'generated': 'yes'},
      messages: [...base.messages, _assistant('assistant', 'generated')],
    );
    final manifest = _manifest();
    await chatRepo.put(base);

    final committed = await chatRepo.commitGenerationResult(
      baseSession: base,
      generatedSession: generated,
      regenTargetId: null,
      manifest: manifest,
    );

    expect(committed?.messages.last.content, 'generated');
    expect(committed?.sessionVars, {'generated': 'yes'});
    final identity = _identity('assistant', 0, 0);
    final rows = await _manifestRows(db);
    expect(rows, hasLength(1));
    expect(rows.single.manifestJson, manifest.canonicalJson);
    expect(rows.single.manifestHash, manifest.canonicalHash);
    final evidence = await manifestRepo.getEvidence(identity);
    expect(evidence, hasLength(1));
    expect(evidence.single.lorebookId, 'book');
    expect(evidence.single.entryId, 'entry');
  });

  test('invalid and conflicting manifests roll back the generation mutation', () async {
    final base = _session();
    final invalidGenerated = base.copyWith(
      updatedAt: 10,
      sessionVars: const {'generated': 'invalid'},
      messages: [...base.messages, _assistant('invalid', 'invalid result')],
    );
    await chatRepo.put(base);

    await expectLater(
      chatRepo.commitGenerationResult(
        baseSession: base,
        generatedSession: invalidGenerated,
        regenTargetId: null,
        manifest: _manifest(source: 'not-a-valid-source'),
      ),
      throwsFormatException,
    );
    expect(await chatRepo.getByCharacterId('character'), [base]);
    expect(await _manifestRows(db), isEmpty);

    final existing = _session(messages: [_assistant('assistant', 'old')]);
    final generated = existing.copyWith(
      updatedAt: 20,
      sessionVars: const {'generated': 'first'},
      messages: [_assistant('assistant', 'new', swipeId: 2, agentSwipeId: 3)],
    );
    await chatRepo.put(existing);
    await chatRepo.commitGenerationResult(
      baseSession: existing,
      generatedSession: generated,
      regenTargetId: 'assistant',
      manifest: _manifest(),
    );
    final beforeConflict = (await chatRepo.getByCharacterId('character')).single;

    await expectLater(
      chatRepo.commitGenerationResult(
        baseSession: beforeConflict,
        generatedSession: generated,
        regenTargetId: 'assistant',
        manifest: _manifest(providerHash: 'conflicting-provider-hash'),
      ),
      throwsA(isA<LorebookUseManifestIntegrityConflict>()),
    );
    expect((await chatRepo.getByCharacterId('character')).single, beforeConflict);
    expect(await _manifestRows(db), hasLength(1));
  });

  test('regen provenance uses the committed resulting swipe and agent swipe', () async {
    final base = _session(messages: [_assistant('assistant', 'old')]);
    final generated = base.copyWith(
      updatedAt: 10,
      messages: [_assistant('assistant', 'regenerated', swipeId: 4, agentSwipeId: 2)],
    );
    await chatRepo.put(base);

    await chatRepo.commitGenerationResult(
      baseSession: base,
      generatedSession: generated,
      regenTargetId: 'assistant',
      manifest: _manifest(),
    );

    final stored = (await chatRepo.getByCharacterId('character')).single.messages.single;
    expect(stored.swipeId, 4);
    expect(stored.agentSwipeId, 2);
    expect(await manifestRepo.getEvidence(_identity('assistant', 4, 2)), hasLength(1));
    expect(await _manifestRows(db), hasLength(1));
  });

  test('legacy no-manifest commits and identical manifest replays stay non-divergent', () async {
    final legacyBase = _session();
    final legacyGenerated = legacyBase.copyWith(
      updatedAt: 10,
      messages: [...legacyBase.messages, _assistant('legacy', 'legacy result')],
    );
    await chatRepo.put(legacyBase);
    expect(
      (await chatRepo.commitGenerationResult(
        baseSession: legacyBase,
        generatedSession: legacyGenerated,
        regenTargetId: null,
      ))?.messages.last.content,
      'legacy result',
    );
    expect(await _manifestRows(db), isEmpty);

    final base = _session(messages: [_assistant('assistant', 'old')]);
    final generated = base.copyWith(
      updatedAt: 20,
      messages: [_assistant('assistant', 'new', swipeId: 1, agentSwipeId: 1)],
    );
    await chatRepo.put(base);
    final manifest = _manifest();
    await chatRepo.commitGenerationResult(
      baseSession: base, generatedSession: generated, regenTargetId: 'assistant', manifest: manifest,
    );
    final replayBase = (await chatRepo.getByCharacterId('character')).single;
    await chatRepo.commitGenerationResult(
      baseSession: replayBase, generatedSession: generated, regenTargetId: 'assistant', manifest: manifest,
    );
    expect(await _manifestRows(db), hasLength(1));
    expect(await manifestRepo.getEvidence(_identity('assistant', 1, 1)), hasLength(1));
  });

  test('user send accepts the exact selected green and blue variation', () async {
    final session = _session();
    final generated = session.copyWith(
      messages: [_assistant('assistant', 'reply', swipeId: 3, agentSwipeId: 7)],
    );
    await chatRepo.put(session);
    await chatRepo.commitGenerationResult(
      baseSession: session,
      generatedSession: generated,
      regenTargetId: null,
      manifest: _manifest(),
    );

    final sent = await chatRepo.appendUserMessageAndAcceptCurrentVariation(
      sessionId: 'session',
      message: _user('user', 'next'),
      expectedPrecedingAssistant: _identity('assistant', 3, 7),
      updatedAt: 11,
    );

    expect(sent?.messages.last.id, 'user');
    final accepted = await manifestRepo.getVariationAcceptances('session');
    expect(accepted, hasLength(1));
    expect(accepted.single.messageId, 'assistant');
    expect(accepted.single.swipeId, 3);
    expect(accepted.single.agentSwipeId, 7);
    expect(accepted.single.acceptedByUserMessageId, 'user');
  });

  test('stale selected anchor appends neither user message nor mismatched acceptance', () async {
    final session = _session();
    final generated = session.copyWith(
      messages: [_assistant('assistant', 'reply', swipeId: 1, agentSwipeId: 1)],
    );
    await chatRepo.put(session);
    await chatRepo.commitGenerationResult(
      baseSession: session, generatedSession: generated, regenTargetId: null, manifest: _manifest(),
    );
    await chatRepo.put(generated.copyWith(
      messages: [_assistant('assistant', 'switched', swipeId: 2, agentSwipeId: 4)],
    ));

    expect(await chatRepo.appendUserMessageAndAcceptCurrentVariation(
      sessionId: 'session', message: _user('user', 'next'),
      expectedPrecedingAssistant: _identity('assistant', 1, 1), updatedAt: 11,
    ), isNull);
    expect((await chatRepo.getById('session'))?.messages, hasLength(1));
    expect(await manifestRepo.getVariationAcceptances('session'), isEmpty);
  });

  test('acceptance conflict rolls back user append and draft clear', () async {
    final session = _session().copyWith(draft: 'keep me');
    final generated = session.copyWith(
      messages: [_assistant('assistant', 'reply', swipeId: 1, agentSwipeId: 2)],
    );
    await chatRepo.put(session);
    await chatRepo.commitGenerationResult(
      baseSession: session, generatedSession: generated, regenTargetId: null, manifest: _manifest(),
    );
    await manifestRepo.insertVariationAcceptance(
      acceptanceId: 'variation:session:user', identity: _identity('assistant', 1, 2),
      acceptedByUserMessageId: 'other-user', acceptedAt: 11,
    );

    await expectLater(
      chatRepo.appendUserMessageAndAcceptCurrentVariation(
        sessionId: 'session', message: _user('user', 'next'),
        expectedPrecedingAssistant: _identity('assistant', 1, 2), updatedAt: 11,
      ),
      throwsA(isA<LorebookUseManifestIntegrityConflict>()),
    );
    final stored = await chatRepo.getById('session');
    expect(stored?.messages, hasLength(1));
    expect(stored?.draft, 'keep me');
  });

  test('legacy variation sends without acceptance', () async {
    final session = _session(messages: [_assistant('assistant', 'legacy')]);
    await chatRepo.put(session);
    final message = _user('user', 'next');
    final first = await chatRepo.appendUserMessageAndAcceptCurrentVariation(
      sessionId: 'session', message: message,
      expectedPrecedingAssistant: _identity('assistant', 0, 0), updatedAt: 11,
    );
    expect(first?.messages, hasLength(2));
    expect(await manifestRepo.getVariationAcceptances('session'), isEmpty);
  });

  test('retrying an accepted send appends one message and one acceptance', () async {
    final base = _session();
    final generated = base.copyWith(messages: [_assistant('assistant', 'reply')]);
    await chatRepo.put(base);
    await chatRepo.commitGenerationResult(
      baseSession: base, generatedSession: generated, regenTargetId: null, manifest: _manifest(),
    );
    final message = _user('user', 'next');
    await chatRepo.appendUserMessageAndAcceptCurrentVariation(
      sessionId: 'session', message: message,
      expectedPrecedingAssistant: _identity('assistant', 0, 0), updatedAt: 11,
    );
    final retry = await chatRepo.appendUserMessageAndAcceptCurrentVariation(
      sessionId: 'session', message: message,
      expectedPrecedingAssistant: _identity('assistant', 0, 0), updatedAt: 11,
    );
    expect(retry?.messages, hasLength(2));
    expect(await manifestRepo.getVariationAcceptances('session'), hasLength(1));
  });

  test('an idempotent retry still clears the draft', () async {
    final base = _session();
    final generated = base.copyWith(messages: [_assistant('assistant', 'reply')]);
    await chatRepo.put(base);
    await chatRepo.commitGenerationResult(
      baseSession: base, generatedSession: generated, regenTargetId: null, manifest: _manifest(),
    );
    final message = _user('user', 'next');
    await chatRepo.appendUserMessageAndAcceptCurrentVariation(
      sessionId: 'session', message: message,
      expectedPrecedingAssistant: _identity('assistant', 0, 0), updatedAt: 11,
    );
    // A draft debounce that landed after the append: the row is holding the
    // text of a message that has already been sent.
    await chatRepo.updateDraftIfMessageCount(
      sessionId: 'session', draft: 'next', expectedMessageCount: 2,
    );

    // This branch reports the send as accepted and its session is published
    // into `ChatState` and the session cache, so it owes the same draft clear
    // the appending branch does — otherwise the sent text is back in the
    // composer the next time the chat opens.
    final retry = await chatRepo.appendUserMessageAndAcceptCurrentVariation(
      sessionId: 'session', message: message,
      expectedPrecedingAssistant: _identity('assistant', 0, 0), updatedAt: 11,
    );

    expect(retry?.messages, hasLength(2));
    expect(retry?.draft, '');
    expect((await chatRepo.getById('session'))?.draft, '');
  });

}

Future<List<LorebookUseManifestRow>> _manifestRows(AppDatabase db) =>
    db.select(db.lorebookUseManifests).get();

ChatSession _session({List<ChatMessage> messages = const []}) => ChatSession(
  id: 'session', characterId: 'character', sessionIndex: 0, messages: messages,
);

ChatMessage _assistant(
  String id,
  String content, {
  int swipeId = 0,
  int agentSwipeId = 0,
}) => ChatMessage(
  id: id,
  role: 'assistant',
  content: content,
  swipeId: swipeId,
  agentSwipeId: agentSwipeId,
);

ChatMessage _user(String id, String content) => ChatMessage(
  id: id,
  role: 'user',
  content: content,
);

LorebookUseGenerationIdentity _identity(
  String messageId,
  int swipeId,
  int agentSwipeId,
) => LorebookUseGenerationIdentity(
  sessionId: 'session',
  messageId: messageId,
  swipeId: swipeId,
  agentSwipeId: agentSwipeId,
);

ExactLorebookManifest _manifest({
  String source = 'keyword',
  String providerHash = 'provider-hash',
}) => ExactLorebookManifest(
  entries: [
    ExactLorebookManifestEntry.fromMergedEntry(
      entry: const LorebookEntry(
        id: 'entry',
        lorebookId: 'book',
        lorebookName: 'Book',
        content: 'lore',
        position: 'worldInfoBefore',
        order: 1,
      ),
      source: source,
      classification: 'worldInfoBefore',
      injectionIndex: 0,
      renderedContent: 'rendered lore',
    ),
  ],
  promptProvenance: const ExactLorebookPromptProvenance(
    characterId: 'character',
    presetSnapshotHash: 'preset-hash',
  ),
  providerMessagesHash: providerHash,
);
