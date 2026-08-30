import 'dart:async';

import 'package:dio/dio.dart';

import '../db/repositories/character_knowledge_fact_repo.dart';
import '../db/repositories/character_repo.dart';
import '../db/repositories/chat_repo.dart';
import '../db/repositories/ledger_debug_run_repo.dart';
import '../db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import '../db/repositories/ledger_reconciliation_lease_repo.dart';
import '../db/repositories/ledger_reconciliation_run_repo.dart';
import '../db/repositories/memory_book_repo.dart';
import '../db/repositories/reconciliation_replacement_repo.dart';
import '../db/repositories/tracker_repo.dart';
import '../db/repositories/tracker_snapshot_repo.dart';
import '../models/pipeline_settings.dart';
import '../models/studio_config.dart';
import '../models/studio_regex.dart';
import '../services/card_rewriter/effective_canon_context_loader.dart';
import 'aux_llm_client.dart';
import 'ledger/ledger_canon_authority.dart';
import 'ledger/ledger_in_flight_registry.dart';
import 'ledger/ledger_op_applier.dart';
import 'ledger/ledger_output_recovery.dart';
import 'ledger/ledger_prompt_factory.dart';
import 'ledger/ledger_reconciliation_committer.dart';
import 'ledger/ledger_reconciliation_runner.dart';
import 'ledger/ledger_replacement_basis_resolver.dart';
import 'ledger/ledger_run_diagnostics.dart';
import 'ledger/ledger_run_result.dart';
import 'ledger/ledger_turn_committer.dart';
import 'ledger/ledger_turn_runner.dart';
import 'macro_engine.dart';
import 'studio_ledger_export_parser.dart';
import 'studio_ledger_reconciliation.dart';

export 'ledger/ledger_op_applier.dart';
export 'ledger/ledger_run_result.dart';

// ─────────────────────────────────────────────────────────────────────────────
// StudioLedgerService
//
// Runs the Studio Ledger after each final assistant response (after the
// POST-cleaner when enabled). Maintains compact continuity state so long-
// running chats do not reset NPCs to card baseline.
//
// Pipeline placement: after final assistant text is settled —
//   1. Assistant response saved.
//   2. POST-cleaner runs if enabled.
//   3. User auto InfBlocks run if configured.
//   4. Studio Ledger runs on final cleaned text. ← this service
//   5. Visible ledger returned for internal diagnostics.
//   6. Export parsed and validated.
//   7. Entity/relationship/arc/world/scene state written to tracker namespace.
//   8. Snapshot of tracker state saved for rollback/swipe safety.
// Ledger must not run on pre-cleaner text. Manual user InfBlocks do not delay
// canon state writes. User InfBlocks are auxiliary evidence only — the ledger
// can read them but must not promote their contents to canon unless supported
// by the final assistant text, visible accepted chat, or existing canon.
//
// Ledger canon lives in tracker_rows → <studio_session_state>. MemoryBook
// remains a separate, user-controlled long-term range-summary workflow.
//
// Failure behaviour:
//   - Ledger failure MUST NOT fail chat generation.
//   - On export-parse failure, return the visible ledger without writes.
//   - On LLM failure, keep previous ledger. No writes.
//   - Cancelled/aborted: clean up, no writes.
// ─────────────────────────────────────────────────────────────────────────────

/// Studio Ledger service.
///
/// Thin orchestrator:
///   1. Resolve LLM config.
///   2. Build prompt (via [LedgerPromptFactory]).
///   3. Call LLM (via [AuxLlmClient]).
///   4. Parse + validate (via [StudioLedgerExportParser]).
///   5. Apply ops to [TrackerRepo].
///   6. Snapshot tracker state for rollback safety.
///
/// Constructor-injected deps (no `Ref` — all repos/client are injected).
class StudioLedgerService {
  final AuxLlmClient _llm;
  final TrackerRepo _trackerRepo;
  final MemoryBookRepo _bookRepo;
  final TrackerSnapshotRepo _snapshotRepo;
  final CharacterKnowledgeFactRepo _knowledgeFactRepo;
  final LedgerReconciliationCheckpointRepo _reconciliationCheckpointRepo;
  final LedgerReconciliationRunRepo _reconciliationRunRepo;
  final LedgerCanonAuthority _canonAuthority;
  final LedgerInFlightRegistry _inFlightRegistry;
  final LedgerOutputRecovery _outputRecovery;
  final LedgerRunDiagnostics _runDiagnostics;
  final LedgerReconciliationLeaseRepo _reconciliationLeaseRepo;
  final ReconciliationReplacementRepo _replacementRepo;
  late final LedgerReplacementBasisResolver _replacementBasisResolver;
  late final LedgerReconciliationCommitter _reconciliationCommitter;
  late final LedgerReconciliationRunner _reconciliationRunner;
  late final LedgerTurnRunner _turnRunner;

  StudioLedgerService({
    required this._llm,
    required this._trackerRepo,
    required this._bookRepo,
    required this._snapshotRepo,
    required this._knowledgeFactRepo,
    required this._reconciliationCheckpointRepo,
    required this._reconciliationRunRepo,
    required CharacterRepo characterRepo,
    required ChatRepo chatRepo,
    required EffectiveCanonContextLoader canonContextLoader,
    LedgerDebugRunRepo? debugRunRepo,
    LedgerReconciliationLeaseRepo? reconciliationLeaseRepo,
    ReconciliationReplacementRepo? replacementRepo,
    LedgerInFlightRegistry? inFlightRegistry,
    LedgerPromptFactory? promptFactory,
    LedgerOutputRecovery? outputRecovery,
    LedgerRunDiagnostics? runDiagnostics,
    LedgerCanonAuthority? canonAuthority,
    LedgerReplacementBasisResolver? replacementBasisResolver,
    LedgerReconciliationCommitter? reconciliationCommitter,
    LedgerReconciliationRunner? reconciliationRunner,
    LedgerTurnRunner? turnRunner,
    List<StudioRegex> Function()? readStudioRegexes,
  }) : _inFlightRegistry = inFlightRegistry ?? const LedgerInFlightRegistry(),
       _outputRecovery = outputRecovery ?? const LedgerOutputRecovery(),
       _runDiagnostics =
           runDiagnostics ??
           LedgerRunDiagnostics(
             debugRunRepo ?? LedgerDebugRunRepo(_trackerRepo.db),
           ),
       _reconciliationLeaseRepo =
           reconciliationLeaseRepo ??
           LedgerReconciliationLeaseRepo(_trackerRepo.db),
       _replacementRepo =
           replacementRepo ?? ReconciliationReplacementRepo(_trackerRepo.db),
       _canonAuthority =
           canonAuthority ??
           LedgerCanonAuthority(
             characterRepo: characterRepo,
             chatRepo: chatRepo,
             canonContextLoader: canonContextLoader,
             snapshotRepo: _snapshotRepo,
           ) {
    _replacementBasisResolver =
        replacementBasisResolver ??
        LedgerReplacementBasisResolver(
          reconciliationCheckpointRepo: _reconciliationCheckpointRepo,
          reconciliationRunRepo: _reconciliationRunRepo,
          replacementRepo: _replacementRepo,
          snapshotRepo: _snapshotRepo,
          canonAuthority: _canonAuthority,
        );
    _reconciliationCommitter =
        reconciliationCommitter ??
        LedgerReconciliationCommitter(
          trackerRepo: _trackerRepo,
          snapshotRepo: _snapshotRepo,
          knowledgeFactRepo: _knowledgeFactRepo,
          reconciliationCheckpointRepo: _reconciliationCheckpointRepo,
          reconciliationRunRepo: _reconciliationRunRepo,
          reconciliationLeaseRepo: _reconciliationLeaseRepo,
          replacementRepo: _replacementRepo,
          canonAuthority: _canonAuthority,
          replacementBasisResolver: _replacementBasisResolver,
          opApplier: const LedgerOpApplier(),
        );
    _reconciliationRunner =
        reconciliationRunner ??
        LedgerReconciliationRunner(
          llm: _llm,
          snapshotRepo: _snapshotRepo,
          reconciliationLeaseRepo: _reconciliationLeaseRepo,
          canonAuthority: _canonAuthority,
          outputRecovery: _outputRecovery,
          committer: _reconciliationCommitter,
          replacementBasisResolver: _replacementBasisResolver,
          runDiagnostics: _runDiagnostics,
          parser: const StudioLedgerExportParser(),
          readStudioRegexes: readStudioRegexes,
        );
    _turnRunner =
        turnRunner ??
        LedgerTurnRunner(
          llm: _llm,
          bookRepo: _bookRepo,
          knowledgeFactRepo: _knowledgeFactRepo,
          canonAuthority: _canonAuthority,
          committer: LedgerTurnCommitter(
            trackerRepo: _trackerRepo,
            snapshotRepo: _snapshotRepo,
            knowledgeFactRepo: _knowledgeFactRepo,
            canonAuthority: _canonAuthority,
          ),
          runDiagnostics: _runDiagnostics,
          promptFactory: promptFactory ?? const LedgerPromptFactory(),
          outputRecovery: _outputRecovery,
          readStudioRegexes: readStudioRegexes,
        );
  }

  Future<LedgerRunResult> reconcile({
    required String sessionId,
    required PipelineSettings settings,
    required AuxApiConfig config,
    required LedgerReconciliationPlan plan,
    List<StudioPresetBlock> ledgerBlocks = const [],
    MacroContext? macroCtx,
    FutureOr<bool> Function()? isStillCurrent,
    CancelToken? cancelToken,
    String? operationIdentity,
  }) {
    final request = LedgerReconciliationRequest(
      sessionId: sessionId,
      settings: settings,
      config: config,
      plan: plan,
      ledgerBlocks: ledgerBlocks,
      macroCtx: macroCtx,
      isStillCurrent: isStillCurrent,
      cancelToken: cancelToken,
      purpose: operationIdentity?.startsWith('manual:') == true
          ? 'manual'
          : 'normal',
    );
    if (operationIdentity == null) {
      return _reconciliationRunner.reconcile(request);
    }
    final end = plan.endMessage;
    final key = _inFlightRegistry.reconciliationKey(
      operationIdentity: operationIdentity,
      sessionId: sessionId,
      rangeHash: plan.rangeHash,
      endMessageId: end.id,
      endSwipeId: end.swipeId,
      endAgentSwipeId: end.agentSwipeId,
      settings: settings,
      config: config,
      ledgerBlocks: ledgerBlocks,
      macroCtx: macroCtx,
    );
    return _inFlightRegistry.join(
      key,
      () => _reconciliationRunner.reconcile(request),
    );
  }

  /// Regenerates only the expected current logical reconciliation head.
  /// Generation reads the immutable before-state; replacement writes happen
  /// later in one short transaction after all guards are revalidated.
  Future<LedgerRunResult> replaceLatestReconciliation({
    required String sessionId,
    required String expectedRunId,
    required PipelineSettings settings,
    required AuxApiConfig config,
    List<StudioPresetBlock> ledgerBlocks = const [],
    MacroContext? macroCtx,
    FutureOr<bool> Function()? isStillCurrent,
    CancelToken? cancelToken,
    String? operationIdentity,
  }) {
    final request = LedgerReconciliationReplacementRequest(
      sessionId: sessionId,
      expectedRunId: expectedRunId,
      settings: settings,
      config: config,
      ledgerBlocks: ledgerBlocks,
      macroCtx: macroCtx,
      isStillCurrent: isStillCurrent,
      cancelToken: cancelToken,
    );
    final key = _inFlightRegistry.replacementKey(
      operationIdentity: operationIdentity,
      sessionId: sessionId,
      expectedRunId: expectedRunId,
      settings: settings,
      config: config,
      ledgerBlocks: ledgerBlocks,
      macroCtx: macroCtx,
    );
    return _inFlightRegistry.join(
      key,
      () => _reconciliationRunner.replaceLatest(request),
    );
  }

  /// Run the Studio Ledger for [sessionId] on [finalAssistantText].
  ///
  /// [messageId], [swipeId], [agentSwipeId] are the provenance anchor for
  /// state writes — required for rollback.
  ///
  /// [isStillCurrent] is called before each write; returns false when a newer
  /// generation has started (abort guard).
  ///
  /// Never throws — all errors are captured in [LedgerRunResult].
  Future<LedgerRunResult> run({
    required String sessionId,
    required PipelineSettings settings,
    required AuxApiConfig config,
    required String finalAssistantText,
    required String recentHistoryText,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    bool forceEnabled = false,
    FutureOr<bool> Function()? isStillCurrent,
    CancelToken? cancelToken,
    List<StudioPresetBlock> ledgerBlocks = const [],
    MacroContext? macroCtx,
    bool commitSnapshot = false,
    StudioLedgerEngine engine = StudioLedgerEngine.currentReconciled,
    String? operationIdentity,
    LedgerAttemptCallback? onAttemptStart,
  }) {
    final request = LedgerTurnRequest(
      sessionId: sessionId,
      settings: settings,
      config: config,
      finalAssistantText: finalAssistantText,
      recentHistoryText: recentHistoryText,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
      forceEnabled: forceEnabled,
      isStillCurrent: isStillCurrent,
      cancelToken: cancelToken,
      ledgerBlocks: ledgerBlocks,
      macroCtx: macroCtx,
      commitSnapshot: commitSnapshot,
      engine: engine,
      onAttemptStart: onAttemptStart,
    );
    if (operationIdentity == null) {
      return _turnRunner.run(request);
    }
    final key = _inFlightRegistry.runKey(
      operationIdentity: operationIdentity,
      sessionId: sessionId,
      messageId: messageId,
      swipeId: swipeId,
      agentSwipeId: agentSwipeId,
      finalAssistantText: finalAssistantText,
      recentHistoryText: recentHistoryText,
      forceEnabled: forceEnabled,
      commitSnapshot: commitSnapshot,
      engine: engine,
      settings: settings,
      config: config,
      ledgerBlocks: ledgerBlocks,
      macroCtx: macroCtx,
    );
    return _inFlightRegistry.join(key, () => _turnRunner.run(request));
  }
}
