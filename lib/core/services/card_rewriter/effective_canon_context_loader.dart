import 'dart:convert';

import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/ledger_raw_tracker_state.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_assembler.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_read_repository.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_fence_resolver.dart';

final class EffectiveCanonContextUnavailable implements Exception {
  const EffectiveCanonContextUnavailable(this.message);
  final String message;
  @override
  String toString() => 'EffectiveCanonContextUnavailable: $message';
}

final class EffectiveCanonContextStamp {
  const EffectiveCanonContextStamp(this.identity);
  final String identity;
}

final class EffectiveCanonContext {
  EffectiveCanonContext({
    required this.character,
    required this.effectiveRevision,
    required this.lineage,
    required this.resolution,
    required Iterable<Tracker> committedTrackers,
    required Iterable<Tracker> manualControls,
    required this.requiresBaselineDecision,
    required this.cacheIdentity,
    required this.stamp,
  }) : committedTrackers = List.unmodifiable(committedTrackers),
       manualControls = List.unmodifiable(manualControls);
  final Character character;
  final CanonRevisionIdentity effectiveRevision;
  final CanonRevisionLineage lineage;
  final EffectiveCanonFenceResolution resolution;
  final List<Tracker> committedTrackers;
  final List<Tracker> manualControls;
  final bool requiresBaselineDecision;
  final String cacheIdentity;
  final EffectiveCanonContextStamp stamp;
}

/// One persistence boundary for baseline policy, lineage, raw Ledger state and
/// fence resolution. It is deliberately Ref-free; provider wiring injects repos.
class EffectiveCanonContextLoader {
  EffectiveCanonContextLoader({
    required this.db,
    required this.characterRepo,
    required this.characterRevisionRepo,
    required this.baselineRepo,
    required this.factRepo,
    required this.transitionRepo,
    required this.transitionFactRefRepo,
    required this.loadRawTrackerState,
  });

  final AppDatabase db;
  final CharacterRepo characterRepo;
  final CharacterRevisionRepo characterRevisionRepo;
  final CharacterSessionBaselineRepo baselineRepo;
  final CharacterKnowledgeFactRepo factRepo;
  final AppliedCanonTransitionRepo transitionRepo;
  final CanonTransitionFactRefRepo transitionFactRefRepo;
  final Future<LedgerRawTrackerState> Function(String sessionId)
  loadRawTrackerState;
  static const _assembler = EffectiveCanonAssembler();

  late final EffectiveCanonReadRepository _readRepository =
      EffectiveCanonReadRepository.runtime(
        db: db,
        characterRepo: characterRepo,
        revisionRepo: characterRevisionRepo,
        baselineRepo: baselineRepo,
        factRepo: factRepo,
        transitionRepo: transitionRepo,
        transitionFactRefRepo: transitionFactRefRepo,
        loadRawTrackerState: loadRawTrackerState,
      );

  Future<EffectiveCanonContext> load({
    required String sessionId,
    required Character sourceCharacter,
  }) async => _load(
    sourceCharacter: sourceCharacter,
    sessionId: sessionId,
    reconcile: true,
  );

  /// Builds the current effective canon without reconciling or persisting a
  /// source revision. Intended for diagnostics and freshness checks.
  Future<EffectiveCanonContext> loadReadOnly({
    required String sessionId,
    required Character sourceCharacter,
  }) async => _load(
    sourceCharacter: sourceCharacter,
    sessionId: sessionId,
    reconcile: false,
  );

  /// Builds effective canon from an exact reconciliation state without
  /// changing source lineage, baselines, or any session-owned rows.
  Future<EffectiveCanonContext> loadReadOnlyFromReconciliationState({
    required String sessionId,
    required Character sourceCharacter,
    required List<Tracker> ledgerTrackers,
    required List<CharacterKnowledgeFact> knowledgeFacts,
  }) async {
    final source = await _readSource(sourceCharacter);
    final current = await _readRepository.readFromSource(
      sessionId: sessionId,
      sourceCharacter: sourceCharacter,
    );
    final controls = ledgerTrackers
        .where(
          (tracker) =>
              tracker.name.startsWith('canon_override:') ||
              tracker.name.startsWith('canon_lock:'),
        )
        .toList(growable: false);
    final committed = ledgerTrackers
        .where((tracker) => !controls.contains(tracker))
        .toList(growable: false);
    final reviewableFacts = knowledgeFacts
        .where(
          (fact) =>
              fact.lifecycle == CharacterKnowledgeFactLifecycle.active ||
              fact.lifecycle == CharacterKnowledgeFactLifecycle.tentative,
        )
        .toList(growable: false);
    final assembly = _assemble(
      EffectiveCanonAssemblyInput(
        sourceCharacter: current.sourceCharacter,
        lineage: source.lineage,
        baseline: current.baseline,
        facts: reviewableFacts,
        committedTrackers: committed,
        manualControls: controls,
        transitions: current.transitions,
        transitionFactRefs: current.transitionFactRefs,
      ),
    );
    return EffectiveCanonContext(
      character: assembly.character,
      effectiveRevision: assembly.effectiveRevision,
      lineage: assembly.lineage,
      resolution: assembly.resolution,
      committedTrackers: committed,
      manualControls: controls,
      requiresBaselineDecision: assembly.requiresBaselineDecision,
      cacheIdentity: assembly.identity,
      stamp: EffectiveCanonContextStamp(assembly.identity),
    );
  }

  /// Read-only freshness check. Unlike [load], this never reconciles source
  /// revisions or writes a baseline/revision row.
  Future<bool> isStillCurrentReadOnly({
    required String sessionId,
    required Character sourceCharacter,
    required EffectiveCanonContextStamp stamp,
  }) async =>
      (await _load(
        sourceCharacter: sourceCharacter,
        sessionId: sessionId,
        reconcile: false,
      )).stamp.identity ==
      stamp.identity;

  Future<EffectiveCanonContext> _load({
    required String sessionId,
    required Character sourceCharacter,
    required bool reconcile,
  }) async {
    final source = reconcile
        ? await _reconcileSource(sourceCharacter)
        : await _readSource(sourceCharacter);
    final input = await _readRepository.readFromSource(
      sessionId: sessionId,
      sourceCharacter: sourceCharacter,
    );
    final assembly = _assemble(
      EffectiveCanonAssemblyInput(
        sourceCharacter: input.sourceCharacter,
        lineage: source.lineage,
        baseline: input.baseline,
        facts: input.facts,
        committedTrackers: input.committedTrackers,
        manualControls: input.manualControls,
        transitions: input.transitions,
        transitionFactRefs: input.transitionFactRefs,
      ),
    );
    return EffectiveCanonContext(
      character: assembly.character,
      effectiveRevision: assembly.effectiveRevision,
      lineage: assembly.lineage,
      resolution: assembly.resolution,
      committedTrackers: input.committedTrackers,
      manualControls: input.manualControls,
      requiresBaselineDecision: assembly.requiresBaselineDecision,
      cacheIdentity: assembly.identity,
      stamp: EffectiveCanonContextStamp(assembly.identity),
    );
  }

  Future<bool> isStillCurrent({
    required String sessionId,
    required Character sourceCharacter,
    required EffectiveCanonContextStamp stamp,
  }) async =>
      (await load(
        sessionId: sessionId,
        sourceCharacter: sourceCharacter,
      )).stamp.identity ==
      stamp.identity;

  Future<_SourceLineage> _readSource(Character source) async {
    final existing = await characterRevisionRepo.getForCharacter(source.id);
    final hash = CardCanonicalizer.sha256(source);
    if (existing.isEmpty) {
      // Model the initial reconciliation in-memory only, so the comparison is
      // exact while preserving its no-write contract.
      return _SourceLineage([
        CharacterRevisionRecord(
          characterId: source.id,
          revision: 1,
          revisionHash: hash,
          parentRevisionHash: '',
          snapshotJson: jsonEncode(source.toJson()),
          createdAt: source.updatedAt,
        ),
      ]);
    }
    final latest = existing.last;
    if (latest.revisionHash == hash) return _SourceLineage(existing);
    return _SourceLineage([
      ...existing,
      CharacterRevisionRecord(
        characterId: source.id,
        revision: latest.revision + 1,
        revisionHash: hash,
        parentRevisionHash: latest.revisionHash,
        snapshotJson: jsonEncode(source.toJson()),
        createdAt: source.updatedAt,
      ),
    ]);
  }

  Future<_SourceLineage> _reconcileSource(Character source) async {
    final hash = CardCanonicalizer.sha256(source);
    final snapshot = jsonEncode(source.toJson());
    final existing = await characterRevisionRepo.getForCharacter(source.id);
    if (existing.isEmpty) {
      final root = CharacterRevisionRecord(
        characterId: source.id,
        revision: 1,
        revisionHash: hash,
        parentRevisionHash: '',
        snapshotJson: snapshot,
        createdAt: source.updatedAt,
      );
      await characterRevisionRepo.insert(root);
      return _SourceLineage([root]);
    }
    final latest = existing.last;
    if (latest.revisionHash != hash) {
      final next = CharacterRevisionRecord(
        characterId: source.id,
        revision: latest.revision + 1,
        revisionHash: hash,
        parentRevisionHash: latest.revisionHash,
        snapshotJson: snapshot,
        createdAt: source.updatedAt,
      );
      await characterRevisionRepo.insert(next);
      return _SourceLineage([...existing, next]);
    }
    return _SourceLineage(existing);
  }

  EffectiveCanonAssembly _assemble(EffectiveCanonAssemblyInput input) {
    try {
      return _assembler.assemble(input);
    } on EffectiveCanonAssemblyUnavailable catch (error) {
      throw EffectiveCanonContextUnavailable(error.message);
    }
  }
}

final class _SourceLineage {
  const _SourceLineage(this.lineage);
  final List<CharacterRevisionRecord> lineage;
}
