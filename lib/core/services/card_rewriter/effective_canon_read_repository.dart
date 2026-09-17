import 'dart:convert';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_canon_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/models/ledger_raw_tracker_state.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/historical_message_window.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_assembler.dart';

/// Aggregate effective-canon reads under one database transaction boundary.
class EffectiveCanonReadRepository {
  EffectiveCanonReadRepository({
    required this.db,
    required this.characterRepo,
    required this.revisionRepo,
    required this.baselineRepo,
    required this.factRepo,
    required this.transitionRepo,
    required this.transitionFactRefRepo,
    LedgerRawTrackerStateReader? rawTrackerStateReader,
  }) : _rawTrackerStateReader =
           rawTrackerStateReader ?? LedgerRawTrackerStateReader(db),
       _runtimeRawTrackerStateLoader = null {
    if (rawTrackerStateReader != null &&
        !identical(rawTrackerStateReader.db, db)) {
      throw ArgumentError.value(
        rawTrackerStateReader,
        'rawTrackerStateReader',
        'must use the same AppDatabase',
      );
    }
  }

  /// Runtime-only compatibility boundary. Apply uses the primary constructor,
  /// whose raw state is always read from its own [AppDatabase].
  EffectiveCanonReadRepository.runtime({
    required this.db,
    required this.characterRepo,
    required this.revisionRepo,
    required this.baselineRepo,
    required this.factRepo,
    required this.transitionRepo,
    required this.transitionFactRefRepo,
    required Future<LedgerRawTrackerState> Function(String sessionId)
    loadRawTrackerState,
  }) : _rawTrackerStateReader = LedgerRawTrackerStateReader(db),
       _runtimeRawTrackerStateLoader = loadRawTrackerState;

  final AppDatabase db;
  final CharacterRepo characterRepo;
  final CharacterRevisionRepo revisionRepo;
  final CharacterSessionBaselineRepo baselineRepo;
  final CharacterKnowledgeFactRepo factRepo;
  final AppliedCanonTransitionRepo transitionRepo;
  final CanonTransitionFactRefRepo transitionFactRefRepo;
  final LedgerRawTrackerStateReader _rawTrackerStateReader;
  final Future<LedgerRawTrackerState> Function(String sessionId)?
  _runtimeRawTrackerStateLoader;

  Future<EffectiveCanonAssemblyInput> read({
    required String sessionId,
    required String characterId,
  }) => db.transaction(
    () => _read(sessionId: sessionId, characterId: characterId),
  );

  /// Reads using the caller's existing transaction.  This deliberately does
  /// not reconcile source lineage or open a second transaction.
  Future<EffectiveCanonAssemblyInput> readInTransaction({
    required String sessionId,
    required String characterId,
  }) => _read(sessionId: sessionId, characterId: characterId);

  Future<EffectiveCanonAssemblyInput> readFromSource({
    required String sessionId,
    required Character sourceCharacter,
    String? excludeSnapshotMessageId,
  }) => db.transaction(
    () => _readFromSource(
      sessionId: sessionId,
      sourceCharacter: sourceCharacter,
      excludeSnapshotMessageId: excludeSnapshotMessageId,
    ),
  );

  Future<EffectiveCanonAssemblyInput> _read({
    required String sessionId,
    required String characterId,
  }) async {
    final sourceCharacter = await characterRepo.getById(characterId);
    if (sourceCharacter == null) {
      throw StateError(
        'Effective canon source character not found: $characterId',
      );
    }
    return _readFromSource(
      sessionId: sessionId,
      sourceCharacter: sourceCharacter,
    );
  }

  Future<EffectiveCanonAssemblyInput> _readFromSource({
    required String sessionId,
    required Character sourceCharacter,
    String? excludeSnapshotMessageId,
  }) async {
    if (excludeSnapshotMessageId != null) {
      return _readHistorical(
        sessionId,
        sourceCharacter,
        excludeSnapshotMessageId,
      );
    }
    final lineage = await revisionRepo.getForCharacter(sourceCharacter.id);
    final baseline = await baselineRepo.getBySessionId(sessionId);
    final facts = await factRepo.getReviewableForSession(sessionId);
    final raw =
        await (_runtimeRawTrackerStateLoader?.call(sessionId) ??
            _rawTrackerStateReader.read(sessionId));
    final transitions = await transitionRepo.getForContext(
      characterId: sourceCharacter.id,
      sessionId: sessionId,
    );
    final refs = await transitionFactRefRepo.getForTransitionIds(
      transitions.map((item) => item.id),
    );
    return EffectiveCanonAssemblyInput(
      sourceCharacter: sourceCharacter,
      lineage: lineage,
      baseline: baseline,
      facts: facts,
      committedTrackers: raw.committedTrackers,
      manualControls: raw.manualControls,
      transitions: transitions,
      transitionFactRefs: refs,
    );
  }

  Future<EffectiveCanonAssemblyInput> _readHistorical(
    String sessionId,
    Character source,
    String targetId,
  ) async {
    final session = await ChatRepo(db).getById(sessionId);
    if (session == null) {
      throw const EffectiveCanonAssemblyUnavailable(
        'Historical session is missing.',
      );
    }
    final window = HistoricalMessageWindow.before(session.messages, targetId);
    final checkpoint = await SessionCanonCheckpointRepo(
      db,
    ).getForHistoricalWindow(sessionId, window);
    var lineage = await revisionRepo.getForCharacter(
      checkpoint?.characterId ?? source.id,
    );
    final baseline = await baselineRepo.getBySessionId(sessionId);
    if (checkpoint != null) {
      lineage = lineage
          .where(
            (revision) => revision.revision <= checkpoint.characterRevision,
          )
          .toList();
      if (lineage.isEmpty ||
          lineage.last.revisionHash != checkpoint.characterRevisionHash) {
        throw const EffectiveCanonAssemblyUnavailable(
          'Historical card checkpoint is unmappable.',
        );
      }
    } else if (baseline != null) {
      final index = lineage.indexWhere(
        (revision) => revision.revisionHash == baseline.baselineHash,
      );
      if (index < 0) {
        throw const EffectiveCanonAssemblyUnavailable(
          'Historical card baseline is unmappable.',
        );
      }
      lineage = lineage.take(index + 1).toList();
    } else if (lineage.length > 1) {
      throw const EffectiveCanonAssemblyUnavailable(
        'Historical card has no anchored baseline.',
      );
    }
    final historicalCharacter = lineage.isEmpty
        ? source
        : Character.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(lineage.last.snapshotJson) as Map,
            ),
          );
    final raw = await _rawTrackerStateReader.read(
      sessionId,
      historicalWindow: window,
    );
    final facts = await factRepo.getForHistoricalWindow(sessionId, window);
    final transitions =
        (await transitionRepo.getForContext(
              characterId: historicalCharacter.id,
              sessionId: sessionId,
            ))
            .where(
              (transition) => lineage.any(
                (revision) =>
                    revision.revision == transition.revision &&
                    revision.revisionHash == transition.revisionHash,
              ),
            )
            .toList();
    return EffectiveCanonAssemblyInput(
      sourceCharacter: historicalCharacter,
      lineage: lineage,
      baseline: null,
      facts: facts,
      committedTrackers: raw.committedTrackers,
      manualControls: raw.manualControls,
      transitions: transitions,
      transitionFactRefs: await transitionFactRefRepo.getForTransitionIds(
        transitions.map((t) => t.id),
      ),
    );
  }
}
