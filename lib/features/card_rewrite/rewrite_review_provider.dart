import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_db.dart';
import '../../core/db/repositories/manual_rewrite_apply_repo.dart';
import '../../core/db/repositories/card_evolution_repo.dart';
import '../../core/db/repositories/manual_rewrite_job_repo.dart';
import '../../core/models/character.dart';
import '../../core/services/card_rewriter/card_rewriter_contracts.dart';
import '../../core/services/card_rewriter/effective_canon_assembler.dart';
import '../../core/services/card_rewriter/effective_canon_read_repository.dart';
import '../../core/state/card_rewriter_providers.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/lorebook_embedding_provider.dart';

/// Durable review aggregate for one job: job row + operations joined with
/// their current immutable revision snapshots and evidence counts.
final rewriteJobSnapshotProvider =
    StreamProvider.family<ManualRewriteJobSnapshot?, String>((ref, jobId) {
      return ref.watch(manualRewriteJobRepoProvider).watchJob(jobId);
    });

/// The live source character, for advisory previews and canon re-checks.
final rewriteCharacterProvider = FutureProvider.family<Character?, String>((
  ref,
  charId,
) {
  return ref.watch(characterRepoProvider).getById(charId);
});

/// The durable job stores a session id, while chat navigation needs its index.
final rewriteSessionIndexProvider = FutureProvider.family<int?, String>(
  (ref, sessionId) async =>
      (await ref.watch(chatRepoProvider).getById(sessionId))?.sessionIndex,
);

/// Raw names of the session's manual canon controls (`canon_lock:<key>` /
/// `canon_override:<key>`). Advisory only — guarded apply re-checks these
/// transactionally.
final rewriteManualControlsProvider =
    FutureProvider.family<Set<String>, String>((ref, sessionId) async {
      final raw = await ref
          .watch(ledgerRawTrackerStateReaderProvider)
          .read(sessionId);
      return raw.manualControls.map((t) => t.name).toSet();
    });

/// Read-side canon reader composed from the context loader's own parts
/// (mirrors the db_provider wiring; this file may not edit that file).
final _canonReaderProvider = Provider<EffectiveCanonReadRepository>((ref) {
  final loader = ref.watch(effectiveCanonContextLoaderProvider);
  return EffectiveCanonReadRepository(
    db: loader.db,
    characterRepo: loader.characterRepo,
    revisionRepo: loader.characterRevisionRepo,
    baselineRepo: loader.baselineRepo,
    factRepo: loader.factRepo,
    transitionRepo: loader.transitionRepo,
    transitionFactRefRepo: loader.transitionFactRefRepo,
    rawTrackerStateReader: ref.watch(ledgerRawTrackerStateReaderProvider),
  );
});

enum RewriteCanonFreshness { unknown, checking, current, stale, unavailable }

class RewriteReviewUiState {
  const RewriteReviewUiState({
    this.selectedOperationId,
    this.busy = false,
    this.freshness = RewriteCanonFreshness.unknown,
  });

  final String? selectedOperationId;

  /// In-flight mutation/apply — the screen locks interactions while true.
  final bool busy;
  final RewriteCanonFreshness freshness;

  RewriteReviewUiState copyWith({
    String? Function()? selectedOperationId,
    bool? busy,
    RewriteCanonFreshness? freshness,
  }) => RewriteReviewUiState(
    selectedOperationId: selectedOperationId == null
        ? this.selectedOperationId
        : selectedOperationId(),
    busy: busy ?? this.busy,
    freshness: freshness ?? this.freshness,
  );
}

/// Transient review state and all side-effecting user actions for one job.
/// Durable facts come from [rewriteJobSnapshotProvider]; every mutation goes
/// through the job repo's typed-CAS methods and reports its conflict kind.
class RewriteReviewController extends Notifier<RewriteReviewUiState> {
  RewriteReviewController(this.jobId);

  final String jobId;

  @override
  RewriteReviewUiState build() => const RewriteReviewUiState();

  void selectOperation(String? id) =>
      state = state.copyWith(selectedOperationId: () => id);

  void markStaleCanon() =>
      state = state.copyWith(freshness: RewriteCanonFreshness.stale);

  /// Advisory re-check: fresh read-side assembly identity vs. the stamp the
  /// job was generated against. Never reconciles or writes lineage rows.
  Future<RewriteCanonFreshness> recheckCanon(RewriteJobRow job) async {
    state = state.copyWith(freshness: RewriteCanonFreshness.checking);
    final character = await ref
        .read(characterRepoProvider)
        .getById(job.characterId);
    if (character == null) {
      state = state.copyWith(freshness: RewriteCanonFreshness.unavailable);
      return state.freshness;
    }
    final fresh = await computeFreshCanonIdentity(
      sessionId: job.chatSessionId,
      character: character,
      stableStamp: isAutomatedEvolutionJob(job),
    );
    final next = fresh == null
        ? RewriteCanonFreshness.unavailable
        : job.canonStamp.isNotEmpty && fresh == job.canonStamp
        ? RewriteCanonFreshness.current
        : RewriteCanonFreshness.stale;
    state = state.copyWith(freshness: next);
    return next;
  }

  /// Fresh read-side canon stamp. Null when the assembly is unreadable.
  /// [stableStamp] mirrors the guarded apply: automated evolution jobs are
  /// compared against the stable identity that ignores per-turn Ledger
  /// tracker/fact drift; manual jobs use the full fence.
  Future<String?> computeFreshCanonIdentity({
    required String sessionId,
    required Character character,
    bool stableStamp = false,
  }) async {
    try {
      final input = await ref
          .read(_canonReaderProvider)
          .readFromSource(sessionId: sessionId, sourceCharacter: character);
      return const EffectiveCanonAssembler()
          .assemble(input, stampVolatileState: !stableStamp)
          .identity;
    } catch (_) {
      return null;
    }
  }

  /// Returns the typed conflict kind (`updated`, `staleRevision`, …).
  Future<String> decide(
    ManualRewriteOperationView view,
    String decision,
  ) async {
    final op = view.operation;
    final outcome = await ref
        .read(manualRewriteJobRepoProvider)
        .setDecision(
          operationId: op.id,
          expectedCurrentRevision: op.currentRevision,
          expectedDecision: op.decision,
          decision: decision,
        );
    return outcome.kind;
  }

  /// Approves every still-`pending`, reviewable, durably-valid operation that
  /// is not advisory-lock-blocked. Returns the number actually approved.
  Future<int> approveAllValid({
    required List<ManualRewriteOperationView> ops,
    required Set<String> manualControlNames,
  }) async {
    var approved = 0;
    for (final view in ops) {
      final op = view.operation;
      if (op.status != 'reviewable' ||
          op.decision != 'pending' ||
          op.validationStatus != 'valid') {
        continue;
      }
      final snapshot = decodeRewriteOperationSnapshot(view.currentSnapshotJson);
      if (snapshot == null) continue;
      if (snapshot is CardRewriteOperationSnapshot &&
          lockOverlap(snapshot, manualControlNames).isNotEmpty) {
        continue;
      }
      final kind = await decide(view, 'approved');
      // After the first decision the job version moved on; re-read each op
      // through the stream on the next frame. Kinds other than `updated`
      // (e.g. a concurrent mutation) simply don't count.
      if (kind == 'updated') approved++;
    }
    return approved;
  }

  /// Rejects remaining reviewable operations before closing a proposal without
  /// applying any card or session-lorebook changes.
  Future<int> rejectAllPending({
    required List<ManualRewriteOperationView> ops,
  }) async {
    var rejected = 0;
    for (final view in ops) {
      final op = view.operation;
      if (op.status != 'reviewable' || op.decision != 'pending') continue;
      if (await decide(view, 'rejected') == 'updated') rejected++;
    }
    return rejected;
  }

  /// Reviewer edit: immutable revision +1 through the repo (decision and
  /// validation reset, advisory-revalidated against the live card).
  Future<String> saveEdit(
    ManualRewriteOperationView view,
    List<String> newValues,
  ) async {
    final snapshot = decodeOperationSnapshot(view.currentSnapshotJson);
    if (snapshot == null || snapshot.patches.length != newValues.length) {
      return 'invalidSnapshot';
    }
    final updated = CardRewriteOperationSnapshot(
      field: snapshot.field,
      patches: [
        for (var i = 0; i < snapshot.patches.length; i++)
          AnchoredScalarPatch(
            scopeKey: snapshot.patches[i].scopeKey,
            field: snapshot.field,
            anchor: snapshot.patches[i].anchor,
            anchorSha256: snapshot.patches[i].anchorSha256,
            value: newValues[i],
          ),
      ],
      transition: snapshot.transition,
    );
    final outcome = await ref
        .read(manualRewriteJobRepoProvider)
        .editAndRevalidate(
          operationId: view.operation.id,
          expectedCurrentRevision: view.operation.currentRevision,
          newSnapshotJson: ManualRewriteOperationSnapshotCodec.encode(updated),
        );
    return outcome.kind;
  }

  /// Removes one bad patch while preserving the operation's other patches.
  /// This is stored as a new immutable operation revision and revalidated.
  Future<String> deletePatch(
    ManualRewriteOperationView view,
    int patchIndex,
  ) async {
    final snapshot = decodeOperationSnapshot(view.currentSnapshotJson);
    if (snapshot == null ||
        patchIndex < 0 ||
        patchIndex >= snapshot.patches.length) {
      return 'invalidSnapshot';
    }
    if (snapshot.patches.length == 1) return 'lastPatch';
    final updated = CardRewriteOperationSnapshot(
      field: snapshot.field,
      patches: [
        for (var index = 0; index < snapshot.patches.length; index++)
          if (index != patchIndex) snapshot.patches[index],
      ],
      transition: snapshot.transition,
    );
    final outcome = await ref
        .read(manualRewriteJobRepoProvider)
        .editAndRevalidate(
          operationId: view.operation.id,
          expectedCurrentRevision: view.operation.currentRevision,
          newSnapshotJson: ManualRewriteOperationSnapshotCodec.encode(updated),
        );
    return outcome.kind;
  }

  /// Atomic apply of all approved operations. The expected canon stamp is re-
  /// derived from a FRESH read-side assembly right before the call (Oracle
  /// contract), never reused from the stored job stamp.
  Future<ManualRewriteApplyOutcome> apply(ManualRewriteJobSnapshot snap) async {
    if (state.busy) {
      return const ManualRewriteApplyOutcome.blocked('uiBusy');
    }
    final character = await ref
        .read(characterRepoProvider)
        .getById(snap.job.characterId);
    if (character == null) {
      return const ManualRewriteApplyOutcome.blocked('characterNotFound');
    }
    state = state.copyWith(busy: true);
    try {
      final stamp = await computeFreshCanonIdentity(
        sessionId: snap.job.chatSessionId,
        character: character,
        stableStamp: isAutomatedEvolutionJob(snap.job),
      );
      if (stamp == null) {
        return const ManualRewriteApplyOutcome.blocked('invalidCanonContext');
      }
      final outcome = await ref
          .read(manualRewriteApplyRepoProvider)
          .applyApproved(
            jobId: snap.job.id,
            expectedCanonStamp: stamp,
            expectedJobVersion: snap.job.version,
          );
      if (outcome.isApplied) {
        unawaited(ref.read(sessionLorebookEmbeddingWorkerProvider).drain());
      }
      return outcome;
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> cancelJob(String jobId) async {
    await ref.read(manualRewriteServiceProvider).cancelJob(jobId);
  }

  /// Re-attaches a stranded `generating` manual job after process restart.
  /// The service's request-key idempotency guarantees this joins a live run or
  /// adopts the durable row without creating another job.
  Future<String> resumeGenerating(RewriteJobRow job) async {
    if (job.status != 'generating' || isAutomatedEvolutionJob(job)) {
      return 'invalidState';
    }
    final request = parseRewriteJobRequest(job.requestJson);
    final requestKey = job.requestKey;
    if (request == null || requestKey == null || requestKey.isEmpty) {
      return 'resumeUnavailable';
    }
    unawaited(
      ref
          .read(manualRewriteServiceProvider)
          .run(
            requestKey: requestKey,
            chatSessionId: job.chatSessionId,
            characterId: job.characterId,
            field: request.field,
            instruction: request.instruction,
          ),
    );
    return 'started';
  }

  Future<CardEvolutionDeleteOutcome> deleteAutomatedProposal(
    RewriteJobRow job,
  ) async {
    if (state.busy) return const CardEvolutionDeleteOutcome('uiBusy');
    state = state.copyWith(busy: true);
    try {
      return await ref
          .read(cardEvolutionRepoProvider)
          .deleteReplaceableProposal(job.id);
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<CardEvolutionFinalizeOutcome> regenerateAutomatedProposal(
    RewriteJobRow job,
  ) async {
    if (state.busy) {
      return const CardEvolutionFinalizeOutcome('uiBusy');
    }
    state = state.copyWith(busy: true);
    try {
      // Capture dependencies before deleting the watched job. Its removal can
      // unmount the review body and dispose this family controller mid-await.
      final evolutionRepo = ref.read(cardEvolutionRepoProvider);
      final evolutionService = ref.read(automatedCardEvolutionServiceProvider);
      final deleted = await evolutionRepo.deleteReplaceableProposal(job.id);
      if (!deleted.isDeleted) {
        return CardEvolutionFinalizeOutcome(deleted.kind);
      }
      return await evolutionService.runOneBatch(job.chatSessionId);
    } finally {
      if (ref.mounted) state = state.copyWith(busy: false);
    }
  }

  /// `failed → generating` retry, then re-attaches the writer lane using the
  /// job's original durable request. Returns a typed kind; `retryUnavailable`
  /// when the job lacks the data needed to re-attach (legacy keyless job or
  /// an unreadable request payload).
  Future<String> retry(RewriteJobRow job) async {
    final request = parseRewriteJobRequest(job.requestJson);
    final requestKey = job.requestKey;
    if (request == null || requestKey == null || requestKey.isEmpty) {
      return 'retryUnavailable';
    }
    final outcome = await ref
        .read(manualRewriteJobRepoProvider)
        .retry(jobId: job.id, expectedVersion: job.version);
    if (!outcome.isUpdated) return outcome.kind;
    unawaited(
      ref
          .read(manualRewriteServiceProvider)
          .run(
            requestKey: requestKey,
            chatSessionId: job.chatSessionId,
            characterId: job.characterId,
            field: request.field,
            instruction: request.instruction,
          ),
    );
    return 'updated';
  }
}

final rewriteReviewUiProvider =
    NotifierProvider.family<
      RewriteReviewController,
      RewriteReviewUiState,
      String
    >(RewriteReviewController.new);

/// Typed view of a job's durable request payload (`{field, instruction}`).
typedef RewriteJobRequest = ({CardRewriteField field, String instruction});

RewriteJobRequest? parseRewriteJobRequest(String requestJson) {
  try {
    final json = jsonDecode(requestJson);
    if (json is! Map) return null;
    final wireName = json['field'];
    final instruction = json['instruction'];
    if (wireName is! String) return null;
    CardRewriteField? field;
    for (final candidate in CardRewriteField.values) {
      if (candidate.wireName == wireName) field = candidate;
    }
    if (field == null) return null;
    return (
      field: field,
      instruction: instruction is String ? instruction : '',
    );
  } catch (_) {
    return null;
  }
}

bool isAutomatedEvolutionJob(RewriteJobRow job) {
  try {
    final request = jsonDecode(job.requestJson);
    return request is Map && request['provenance'] == 'automatedEvolution';
  } catch (_) {
    return false;
  }
}

CardRewriteOperationSnapshot? decodeOperationSnapshot(String snapshotJson) {
  final snapshot = decodeRewriteOperationSnapshot(snapshotJson);
  return snapshot is CardRewriteOperationSnapshot ? snapshot : null;
}

RewriteOperationSnapshot? decodeRewriteOperationSnapshot(String snapshotJson) {
  try {
    return RewriteOperationSnapshotCodec.tryDecode(jsonDecode(snapshotJson));
  } catch (_) {
    return null;
  }
}

/// Advisory set of a transition's tracker keys that currently sit under a
/// manual canon lock or override.
Set<String> lockOverlap(
  CardRewriteOperationSnapshot snapshot,
  Set<String> manualControlNames,
) => {
  for (final key in snapshot.transition.affectedTrackerKeys)
    if (manualControlNames.contains('canon_lock:$key') ||
        manualControlNames.contains('canon_override:$key'))
      key,
};

/// Advisory per-operation validation against the live card values. Guarded
/// apply re-validates authoritatively; this only drives chips and gating.
List<CardPatchViolation> advisoryViolations(
  CardRewriteOperationSnapshot snapshot,
  Character character,
) {
  final validation = AnchoredScalarPatchValidator.validate(
    patches: snapshot.patches,
    currentCardValues: rewriteFieldValues(character),
  );
  return validation.violations;
}

Map<CardRewriteField, String?> rewriteFieldValues(Character c) => {
  for (final field in CardRewriteField.values)
    field: rewrittenFieldValue(c, field),
};

String rewrittenFieldValue(Character c, CardRewriteField field) =>
    switch (field) {
      CardRewriteField.description => c.description ?? '',
      CardRewriteField.personality => c.personality ?? '',
      CardRewriteField.scenario => c.scenario ?? '',
      CardRewriteField.systemPrompt => c.systemPrompt ?? '',
      CardRewriteField.postHistoryInstructions =>
        c.postHistoryInstructions ?? '',
      CardRewriteField.creatorNotes => c.creatorNotes ?? '',
    };
