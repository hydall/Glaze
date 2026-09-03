import 'dart:async';

import 'package:dio/dio.dart';

import '../../db/repositories/character_repo.dart';
import '../../db/repositories/chat_repo.dart';
import '../../db/repositories/tracker_snapshot_repo.dart';
import '../../models/character.dart';
import '../../models/character_knowledge_fact.dart';
import '../../models/chat_message.dart';
import '../../models/tracker.dart';
import '../../services/card_rewriter/effective_canon_context_loader.dart';

class LedgerCanonAuthority {
  const LedgerCanonAuthority({
    required this.characterRepo,
    required this.chatRepo,
    required this.canonContextLoader,
    required this.snapshotRepo,
  });

  final CharacterRepo characterRepo;
  final ChatRepo chatRepo;
  final EffectiveCanonContextLoader canonContextLoader;
  final TrackerSnapshotRepo snapshotRepo;

  Future<LedgerCanonContext> load(String sessionId) async {
    final source = await _loadSourceCharacter(sessionId);
    final context = await canonContextLoader.load(
      sessionId: sessionId,
      sourceCharacter: source,
    );
    return LedgerCanonContext(source, context);
  }

  Future<LedgerCanonContext> loadReadOnly(String sessionId) async {
    final source = await _loadSourceCharacter(sessionId);
    final context = await canonContextLoader.loadReadOnly(
      sessionId: sessionId,
      sourceCharacter: source,
    );
    return LedgerCanonContext(source, context);
  }

  Future<LedgerCanonContext> loadReadOnlyFromReconciliationState({
    required String sessionId,
    required Character sourceCharacter,
    required List<Tracker> ledgerTrackers,
    required List<CharacterKnowledgeFact> knowledgeFacts,
  }) async {
    final context = await canonContextLoader
        .loadReadOnlyFromReconciliationState(
          sessionId: sessionId,
          sourceCharacter: sourceCharacter,
          ledgerTrackers: ledgerTrackers,
          knowledgeFacts: knowledgeFacts,
        );
    return LedgerCanonContext(sourceCharacter, context);
  }

  Future<bool> isStillCurrent(
    String sessionId,
    LedgerCanonContext canon,
  ) async {
    final currentSource = await characterRepo.getById(canon.source.id);
    if (currentSource == null) return false;
    return canonContextLoader.isStillCurrentReadOnly(
      sessionId: sessionId,
      sourceCharacter: currentSource,
      stamp: canon.context.stamp,
    );
  }

  Future<bool> passesCurrentnessGuard(FutureOr<bool> Function()? guard) async =>
      await guard?.call() ?? true;

  /// Transactional commit fence. The check order is part of the contract.
  Future<void> throwIfCommitStale({
    required String sessionId,
    required LedgerCanonContext canon,
    required CancelToken token,
    required FutureOr<bool> Function()? isStillCurrent,
    required LedgerTarget target,
    bool requireCommittedSnapshot = false,
    bool checkCanon = true,
  }) async {
    if (token.isCancelled ||
        await passesCurrentnessGuard(isStillCurrent) == false) {
      throw const LedgerCommitStale();
    }
    if (checkCanon && !await this.isStillCurrent(sessionId, canon)) {
      throw const LedgerCommitStale();
    }
    final session = await chatRepo.getById(sessionId);
    final message = session?.messages
        .where((item) => item.id == target.messageId)
        .firstOrNull;
    if (message == null ||
        message.swipeId != target.swipeId ||
        message.agentSwipeId != target.agentSwipeId ||
        message.content != target.content) {
      throw const LedgerCommitStale();
    }
    if (requireCommittedSnapshot) {
      final snapshot = await snapshotRepo.getByAnchor(
        sessionId: sessionId,
        messageId: target.messageId,
        swipeId: target.swipeId,
        agentSwipeId: target.agentSwipeId,
      );
      if (snapshot == null || !snapshot.committed) {
        throw const LedgerCommitStale();
      }
    }
  }

  List<Tracker> stampTrackers(
    LedgerCanonContext canon,
    List<Tracker> trackers,
  ) => trackers
      .map(
        (tracker) => Tracker(
          sessionId: tracker.sessionId,
          name: tracker.name,
          value: tracker.value,
          scope: tracker.scope,
          provenance: tracker.provenance,
          basisRevisionNumber: canon.context.effectiveRevision.number,
          basisRevisionHash: canon.context.effectiveRevision.hash,
          updatedAt: tracker.updatedAt,
        ),
      )
      .toList(growable: false);

  List<Tracker> projectPromptTrackers(EffectiveCanonContext context) => [
    ...context.resolution.activeTrackers,
    ...context.manualControls,
  ];

  /// Recent committed game-clock trajectory (oldest→newest), capped at [limit]
  /// entries. Each entry is `DD.MM.YYYY · day N · HH:MM`. Fed into the ledger
  /// prompt so the model sees that a prior timeskip already happened and where
  /// the clock currently stands — preventing a timeskip from being re-applied
  /// or time from being over-advanced on later turns.
  Future<List<String>> loadRecentGameClock(
    String sessionId, {
    int limit = 5,
  }) async {
    final snaps = await snapshotRepo.getBySessionId(sessionId);
    final committed = snaps.where((s) => s.committed).toList().reversed;
    final out = <String>[];
    for (final s in committed) {
      String? date;
      String? day;
      String? time;
      for (final t in s.trackers) {
        if (t.name == 'world:date') {
          date = t.value;
        } else if (t.name == 'world:day') {
          day = t.value;
        } else if (t.name == 'world:time') {
          time = t.value;
        }
      }
      if (date != null && time != null) {
        out.add('$date · day ${day ?? '?'} · $time');
      }
      if (out.length >= limit) break;
    }
    return out;
  }

  Future<Character> _loadSourceCharacter(String sessionId) async {
    final session = await chatRepo.getById(sessionId);
    if (session == null) {
      throw StateError('Ledger session not found: $sessionId');
    }
    final source = await characterRepo.getById(session.characterId);
    if (source == null) {
      throw StateError(
        'Ledger source character not found: ${session.characterId}',
      );
    }
    return source;
  }
}

class LedgerCanonContext {
  const LedgerCanonContext(this.source, this.context);

  final Character source;
  final EffectiveCanonContext context;
}

class LedgerCommitStale implements Exception {
  const LedgerCommitStale();
}

class LedgerTarget {
  const LedgerTarget({
    required this.messageId,
    required this.swipeId,
    required this.agentSwipeId,
    required this.content,
  });

  factory LedgerTarget.fromMessage(ChatMessage message) => LedgerTarget(
    messageId: message.id,
    swipeId: message.swipeId,
    agentSwipeId: message.agentSwipeId,
    content: message.content,
  );

  final String messageId;
  final int swipeId;
  final int agentSwipeId;
  final String content;
}
