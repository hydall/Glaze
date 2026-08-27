import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../db/repositories/character_knowledge_fact_repo.dart';
import '../../db/repositories/ledger_debug_run_repo.dart';
import '../../db/repositories/memory_book_repo.dart';
import '../../models/character_knowledge_fact.dart';
import '../../models/memory_book.dart';
import '../../models/pipeline_settings.dart';
import '../../models/studio_config.dart';
import '../../models/studio_ledger_export.dart';
import '../../utils/id_generator.dart';
import '../aux_llm_client.dart';
import '../knowledge_cleanup_parser.dart';
import '../macro_engine.dart';
import '../studio_ledger_export_parser.dart';
import '../transport/llm_capture_context.dart';
import 'ledger_canon_authority.dart';
import 'ledger_output_recovery.dart';
import 'ledger_prompt_factory.dart';
import 'ledger_run_diagnostics.dart';
import 'ledger_run_result.dart';
import 'ledger_turn_committer.dart';

enum LedgerAttemptPhase { initial, parserRepair }

typedef LedgerAttemptCallback =
    void Function(LedgerAttemptPhase phase, int attempt, int maxAttempts);

class LedgerTurnRequest {
  const LedgerTurnRequest({
    required this.sessionId,
    required this.settings,
    required this.config,
    required this.finalAssistantText,
    required this.recentHistoryText,
    required this.messageId,
    required this.swipeId,
    required this.agentSwipeId,
    required this.forceEnabled,
    required this.isStillCurrent,
    required this.cancelToken,
    required this.ledgerBlocks,
    required this.macroCtx,
    required this.commitSnapshot,
    required this.engine,
    this.onAttemptStart,
  });

  final String sessionId;
  final PipelineSettings settings;
  final AuxApiConfig config;
  final String finalAssistantText;
  final String recentHistoryText;
  final String messageId;
  final int swipeId;
  final int agentSwipeId;
  final bool forceEnabled;
  final FutureOr<bool> Function()? isStillCurrent;
  final CancelToken? cancelToken;
  final List<StudioPresetBlock> ledgerBlocks;
  final MacroContext? macroCtx;
  final bool commitSnapshot;
  final StudioLedgerEngine engine;
  final LedgerAttemptCallback? onAttemptStart;
}

class LedgerTurnRunner {
  factory LedgerTurnRunner({
    required AuxLlmClient llm,
    required MemoryBookRepo bookRepo,
    required CharacterKnowledgeFactRepo knowledgeFactRepo,
    required LedgerCanonAuthority canonAuthority,
    required LedgerTurnCommitter committer,
    required LedgerRunDiagnostics runDiagnostics,
    LedgerPromptFactory promptFactory = const LedgerPromptFactory(),
    LedgerOutputRecovery outputRecovery = const LedgerOutputRecovery(),
    StudioLedgerExportParser parser = const StudioLedgerExportParser(),
  }) => LedgerTurnRunner._(
    llm,
    bookRepo,
    knowledgeFactRepo,
    canonAuthority,
    committer,
    runDiagnostics,
    promptFactory,
    outputRecovery,
    parser,
  );

  const LedgerTurnRunner._(
    this._llm,
    this._bookRepo,
    this._knowledgeFactRepo,
    this._canonAuthority,
    this._committer,
    this._runDiagnostics,
    this._promptFactory,
    this._outputRecovery,
    this._parser,
  );

  final AuxLlmClient _llm;
  final MemoryBookRepo _bookRepo;
  final CharacterKnowledgeFactRepo _knowledgeFactRepo;
  final LedgerCanonAuthority _canonAuthority;
  final LedgerTurnCommitter _committer;
  final LedgerRunDiagnostics _runDiagnostics;
  final LedgerPromptFactory _promptFactory;
  final LedgerOutputRecovery _outputRecovery;
  final StudioLedgerExportParser _parser;

  Future<LedgerRunResult> run(LedgerTurnRequest request) async {
    final trace = LedgerRunTrace(
      sessionId: request.sessionId,
      kind: LedgerDebugRunKind.normal,
      messageId: request.messageId,
      swipeId: request.swipeId,
      agentSwipeId: request.agentSwipeId,
    );
    final result = await _runTraced(trace, request);
    unawaited(_runDiagnostics.recordDebugRun(trace, result));
    return result;
  }

  Future<LedgerRunResult> _runTraced(
    LedgerRunTrace trace,
    LedgerTurnRequest request,
  ) async {
    // Studio Ledger is always-on when Studio is enabled. forceEnabled is
    // still respected for manual triggers.

    if (request.finalAssistantText.trim().isEmpty) {
      debugPrint('[StudioLedger] skipping — empty assistant text');
      return LedgerRunResult.skipped;
    }

    final token = request.cancelToken ?? CancelToken();
    if (token.isCancelled) return LedgerRunResult.aborted;

    final sw = Stopwatch()..start();

    try {
      // ── 1. LLM config is resolved by the caller via StudioSlotResolver ──
      if (token.isCancelled ||
          await _canonAuthority.passesCurrentnessGuard(
                request.isStillCurrent,
              ) ==
              false) {
        return LedgerRunResult.aborted;
      }

      // ── 2. Load prompt base (committed canon + live manual overrides) ────
      final canon = await _canonAuthority.load(request.sessionId);
      final promptTrackers = _canonAuthority.projectPromptTrackers(
        canon.context,
      );
      final book = await _bookRepo.getBySessionId(request.sessionId);
      final recentEntries =
          book?.entries.where((e) => e.status == 'active').take(20).toList() ??
          const <MemoryEntry>[];
      final entityAliases = await _knowledgeFactRepo.getEntityAliases(
        request.sessionId,
      );

      if (token.isCancelled ||
          await _canonAuthority.passesCurrentnessGuard(
                request.isStillCurrent,
              ) ==
              false) {
        return LedgerRunResult.aborted;
      }
      if (!await _canonAuthority.isStillCurrent(request.sessionId, canon)) {
        return LedgerRunResult.aborted;
      }

      // ── 3. Build prompt ─────────────────────────────────────────────────
      final prompt = _promptFactory.buildLedgerPrompt(
        finalAssistantText: request.finalAssistantText,
        recentHistoryText: request.recentHistoryText,
        currentTrackers: promptTrackers,
        recentMemoryEntries: recentEntries,
        ledgerBlocks: request.ledgerBlocks,
        macroCtx: request.macroCtx,
        character: canon.source,
        entityAliases: entityAliases,
        engine: request.engine,
      );

      debugPrint(
        '[StudioLedger] prompt session=${request.sessionId} '
        'chars=${prompt.length} '
        'usingPresetBlocks=${request.ledgerBlocks.isNotEmpty && request.macroCtx != null} '
        'first500=${prompt.length > 500 ? prompt.substring(0, 500) : prompt}',
      );

      // ── 4. Call LLM ─────────────────────────────────────────────────────
      final maxTokens = request.settings.ledger.studioLedgerMaxTokens > 0
          ? request.settings.ledger.studioLedgerMaxTokens
          : 15000;
      final temperature = request.settings.ledger.studioLedgerTemperature >= 0
          ? request.settings.ledger.studioLedgerTemperature
          : 0.2;
      final timeoutMs = _llm.resolveLedgerTimeout(request.settings);

      debugPrint(
        '[StudioLedger] starting session=${request.sessionId} '
        'model=${request.config.model} '
        'timeoutMs=$timeoutMs '
        'textChars=${request.finalAssistantText.length}',
      );

      final outcome = await _llm.callOnceWithLog(
        config: request.config,
        prompt: prompt,
        maxTokens: maxTokens,
        temperature: temperature,
        timeoutMs: timeoutMs,
        cancelToken: token,
        omitReasoning: true,
        onAttemptStart: (attempt, maxAttempts) => request.onAttemptStart?.call(
          LedgerAttemptPhase.initial,
          attempt,
          maxAttempts,
        ),
        captureContext: LlmCaptureContext(
          stage: 'ledger.turn',
          sessionId: request.sessionId,
          messageId: request.messageId,
          pipelineRunId:
              'ledger:${request.messageId}:${request.swipeId}:${request.agentSwipeId}',
          logicalCallId:
              'ledger:${request.messageId}:${request.swipeId}:${request.agentSwipeId}',
          relatedArtifactId: request.messageId,
        ),
      );

      if (token.isCancelled ||
          await _canonAuthority.passesCurrentnessGuard(
                request.isStillCurrent,
              ) ==
              false) {
        return LedgerRunResult.aborted;
      }

      if (!outcome.isOk || outcome.text == null || outcome.text!.isEmpty) {
        final lastAttempt = outcome.attempts.lastOrNull;
        debugPrint(
          '[StudioLedger] LLM call failed session=${request.sessionId} '
          'status=${lastAttempt?.status} '
          'statusCode=${lastAttempt?.statusCode ?? 0} '
          'elapsedMs=${lastAttempt?.elapsedMs ?? 0} '
          'error=${lastAttempt?.error ?? "none"}',
        );
        return LedgerRunResult(
          status: 'error',
          error:
              'LLM call failed: ${lastAttempt?.status}'
              '${lastAttempt?.error != null ? ': ${lastAttempt!.error}' : ''}',
          elapsedMs: sw.elapsedMilliseconds,
          attempts: outcome.attempts,
          model: request.config.model,
        );
      }

      // ── 5. Parse + validate ─────────────────────────────────────────────
      final rawResponse = outcome.text!;
      debugPrint(
        '[StudioLedger] raw response session=${request.sessionId} '
        'chars=${rawResponse.length} '
        'first1000=${rawResponse.length > 1000 ? rawResponse.substring(0, 1000) : rawResponse}',
      );

      var effectiveResponse = rawResponse;
      var parseResult = _parser.parse(
        effectiveResponse,
        focalUserName: request.macroCtx?.userName ?? '',
      );
      await _runDiagnostics.recordLedgerParserVerdict(outcome, parseResult);
      trace.recordFirstResponse(
        model: request.config.model,
        responseText: rawResponse,
        parsed: parseResult,
      );
      final originalFailure = parseResult.failure;
      final originalVisibleLedger = parseResult.visibleLedger;
      var attempts = outcome.attempts;
      var repairAttempted = false;
      var totalPromptChars = prompt.length;
      var totalResponseChars = rawResponse.length;

      if (parseResult.failure.isRepairable) {
        if (token.isCancelled ||
            await _canonAuthority.passesCurrentnessGuard(
                  request.isStillCurrent,
                ) ==
                false) {
          return LedgerRunResult.aborted;
        }
        if (!await _canonAuthority.isStillCurrent(request.sessionId, canon)) {
          return LedgerRunResult.aborted;
        }
        if (_outputRecovery.isOversizedRepairInput(effectiveResponse)) {
          return LedgerRunResult(
            status: 'error',
            visibleLedger: originalVisibleLedger,
            error: 'Ledger output is too large for safe deterministic repair',
            elapsedMs: sw.elapsedMilliseconds,
            attempts: attempts,
            model: request.config.model,
            effectiveTimeoutMs: timeoutMs,
            promptChars: totalPromptChars,
            responseChars: totalResponseChars,
          );
        }
        repairAttempted = true;
        trace.recordRepairRequested(exportRepair: true);
        final repairPrompt = _outputRecovery.buildRepairPrompt(
          effectiveResponse,
        );
        totalPromptChars += repairPrompt.length;
        final repair = await _llm.callOnceWithLog(
          config: request.config,
          prompt: repairPrompt,
          maxTokens: maxTokens,
          temperature: 0,
          timeoutMs: timeoutMs,
          cancelToken: token,
          omitReasoning: true,
          onAttemptStart: (attempt, maxAttempts) => request.onAttemptStart
              ?.call(LedgerAttemptPhase.parserRepair, attempt, maxAttempts),
          captureContext: LlmCaptureContext(
            stage: 'ledger.turn_repair',
            sessionId: request.sessionId,
            messageId: request.messageId,
            pipelineRunId:
                'ledger:${request.messageId}:${request.swipeId}:${request.agentSwipeId}',
            logicalCallId:
                'ledger:${request.messageId}:${request.swipeId}:${request.agentSwipeId}:repair',
            relatedArtifactId: request.messageId,
          ),
        );
        attempts = _outputRecovery.combineAttempts(attempts, repair.attempts);
        totalResponseChars += repair.text?.length ?? 0;
        if (token.isCancelled ||
            await _canonAuthority.passesCurrentnessGuard(
                  request.isStillCurrent,
                ) ==
                false) {
          return LedgerRunResult.aborted;
        }
        if (!await _canonAuthority.isStillCurrent(request.sessionId, canon)) {
          return LedgerRunResult.aborted;
        }
        if (!repair.isOk || repair.text == null || repair.text!.isEmpty) {
          return LedgerRunResult(
            status: 'error',
            error: 'Ledger export repair call failed',
            elapsedMs: sw.elapsedMilliseconds,
            attempts: attempts,
            model: request.config.model,
            repairAttempted: true,
            effectiveTimeoutMs: timeoutMs,
            promptChars: totalPromptChars,
            responseChars: totalResponseChars,
          );
        }
        effectiveResponse = repair.text!;
        parseResult = _parser.parse(
          effectiveResponse,
          focalUserName: request.macroCtx?.userName ?? '',
        );
        await _runDiagnostics.recordLedgerParserVerdict(repair, parseResult);
        trace.recordRepairResponse(
          responseText: effectiveResponse,
          parsed: parseResult,
        );
        if (parseResult.export != null &&
            !_outputRecovery.repairPreservesStructuredEvidence(
              rawResponse,
              parseResult.export!,
            )) {
          return LedgerRunResult(
            status: 'error',
            visibleLedger: originalVisibleLedger,
            error:
                'Ledger repair introduced data absent from the original output',
            elapsedMs: sw.elapsedMilliseconds,
            attempts: attempts,
            model: request.config.model,
            repairAttempted: true,
            effectiveTimeoutMs: timeoutMs,
            promptChars: totalPromptChars,
            responseChars: totalResponseChars,
          );
        }
      }

      debugPrint(
        '[StudioLedger] parsed session=${request.sessionId} '
        'hasExport=${parseResult.hasExport} '
        'visibleLedgerChars=${parseResult.visibleLedger.length} '
        'rejection=${parseResult.rejectionReason ?? "none"}',
      );

      if (repairAttempted &&
          originalFailure == LedgerParseFailure.missingExport &&
          parseResult.failure == LedgerParseFailure.emptyExport) {
        return LedgerRunResult(
          status: 'error',
          visibleLedger: originalVisibleLedger,
          error:
              'Repair produced an empty export without explicit empty intent',
          elapsedMs: sw.elapsedMilliseconds,
          attempts: attempts,
          model: request.config.model,
          repairAttempted: true,
          effectiveTimeoutMs: timeoutMs,
          promptChars: totalPromptChars,
          responseChars: totalResponseChars,
        );
      }

      if (!parseResult.hasExport &&
          parseResult.failure != LedgerParseFailure.emptyExport) {
        return LedgerRunResult(
          status: 'error',
          visibleLedger: originalVisibleLedger.isNotEmpty
              ? originalVisibleLedger
              : parseResult.visibleLedger,
          error: parseResult.rejectionReason,
          elapsedMs: sw.elapsedMilliseconds,
          attempts: attempts,
          model: request.config.model,
          repairAttempted: repairAttempted,
          effectiveTimeoutMs: timeoutMs,
          promptChars: totalPromptChars,
          responseChars: totalResponseChars,
        );
      }

      if (token.isCancelled ||
          await _canonAuthority.passesCurrentnessGuard(
                request.isStillCurrent,
              ) ==
              false) {
        return LedgerRunResult.aborted;
      }

      // ── 6. Apply ops to tracker namespace ───────────────────────────────
      final export = parseResult.export ?? const StudioLedgerExport();
      // Parse optional knowledge cleanup (rename_entity) from the same
      // response. It is committed under the same target/canon fence as the
      // tracker patch so an obsolete swipe can never rename live facts.
      final cleanupOps = const KnowledgeCleanupParser().parse(
        output: effectiveResponse,
        reviewText:
            '${request.recentHistoryText}\n${request.finalAssistantText}',
        entityKeys: entityAliases.keys.toSet(),
      );
      final facts = export.knowledgeFacts
          .map(
            (fact) => CharacterKnowledgeFact(
              id: generateId(),
              chatSessionId: request.sessionId,
              knowerKey: fact.knowerKey,
              knowerName: fact.knowerName,
              subjectKey: fact.subjectKey,
              subjectName: fact.subjectName,
              factClass: CharacterKnowledgeFactClass.fromWireName(
                fact.factClass,
              ),
              scopeKey: fact.scopeKey,
              predicate: fact.predicate,
              object: fact.object,
              epistemicState: CharacterKnowledgeEpistemicState.fromWireName(
                fact.epistemicState,
              ),
              confidence: fact.confidence,
              importance: fact.importance,
              entities: fact.entities,
              topics: fact.topics,
              sourceMessageId: request.messageId,
              sourceSwipeId: request.swipeId,
              sourceAgentSwipeId: request.agentSwipeId,
              supersedesId: fact.supersedesId,
              basisRevisionNumber: canon.context.effectiveRevision.number,
              basisRevisionHash: canon.context.effectiveRevision.hash,
            ),
          )
          .toList(growable: false);
      final opsApplied = await _committer.commit(
        LedgerTurnCommitRequest(
          sessionId: request.sessionId,
          messageId: request.messageId,
          swipeId: request.swipeId,
          agentSwipeId: request.agentSwipeId,
          finalAssistantText: request.finalAssistantText,
          canon: canon,
          promptTrackers: promptTrackers,
          export: export,
          cleanupOps: cleanupOps,
          facts: facts,
          token: token,
          isStillCurrent: request.isStillCurrent,
          commitSnapshot: request.commitSnapshot,
        ),
      );

      debugPrint(
        '[StudioLedger] applied $opsApplied/${export.ops.length} ops session=${request.sessionId}',
      );

      sw.stop();
      debugPrint(
        '[StudioLedger] done session=${request.sessionId} '
        'ops=$opsApplied '
        'elapsedMs=${sw.elapsedMilliseconds}',
      );

      return LedgerRunResult(
        status: 'ok',
        visibleLedger: originalVisibleLedger.isNotEmpty
            ? originalVisibleLedger
            : parseResult.visibleLedger,
        opsApplied: opsApplied,
        elapsedMs: sw.elapsedMilliseconds,
        attempts: attempts,
        model: request.config.model,
        repairAttempted: repairAttempted,
        effectiveTimeoutMs: timeoutMs,
        promptChars: totalPromptChars,
        responseChars: totalResponseChars,
      );
    } on LedgerCommitStale {
      return LedgerRunResult.aborted;
    } on TimeoutException {
      sw.stop();
      debugPrint('[StudioLedger] timeout session=${request.sessionId}');
      return LedgerRunResult(
        status: 'timeout',
        elapsedMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      sw.stop();
      if (token.isCancelled || (e is DioException && CancelToken.isCancel(e))) {
        return LedgerRunResult.aborted;
      }
      debugPrint('[StudioLedger] error session=${request.sessionId}: $e');
      return LedgerRunResult(
        status: 'error',
        error: '$e',
        elapsedMs: sw.elapsedMilliseconds,
      );
    }
  }
}
