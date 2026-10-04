import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../db/repositories/card_evolution_repo.dart';
import '../../llm/aux_retry_runner.dart';
import '../../llm/transport/llm_call_event.dart';
import '../../llm/transport/llm_capture_context.dart';
import '../../utils/time_helpers.dart';

final class CardEvolutionDiagnostics {
  const CardEvolutionDiagnostics(this._repo);

  final CardEvolutionRepo _repo;

  Future<void> recordCollectorParserVerdict({
    required LlmCaptureContext? context,
    required bool accepted,
    required String code,
    required String source,
    String? detail,
    String? responseText,
  }) {
    if (context?.callId == null || context?.pipelineRunId == null) {
      return Future<void>.value();
    }
    return LlmCallEventCapture.record(
      LlmCallEvent.parserVerdict(
        context: context!,
        parserName: 'AutomatedCardEvolutionService.collectorResponse',
        accepted: accepted,
        code: code,
        detail: detail,
        responseText: responseText,
        payload: {'source': source},
      ),
    );
  }

  Future<void> recordWriterParserVerdict({
    required LlmCaptureContext context,
    required bool accepted,
    required String source,
    String? detail,
    String? responseText,
  }) => LlmCallEventCapture.record(
    LlmCallEvent.parserVerdict(
      context: context,
      parserName: 'CardRewriteOperationParser.writerCheckpoint',
      accepted: accepted,
      code: accepted ? 'accepted' : 'invalidOutput',
      detail: detail,
      responseText: responseText,
      payload: {'source': source},
    ),
  );

  Future<void> saveModelOutcome({
    required String sessionId,
    required String stage,
    required String model,
    required AuxCallOutcome outcome,
  }) async {
    try {
      await _repo.saveDebugRun(
        sessionId: sessionId,
        stage: stage,
        status: outcome.status.name,
        model: model,
        output: outcome.text,
        attemptsJson: jsonEncode([
          for (final attempt in outcome.attempts) attempt.toJson(),
        ]),
        updatedAt: currentTimestampSeconds(),
      );
    } catch (error) {
      debugPrint('[CardRewriter] failed to persist model diagnostics: $error');
    }
  }

  Future<void> saveSelectionBail({
    required String sessionId,
    required String outcome,
    required String? reason,
    required int throughCollectorOrdinal,
    required List<String> reconciliationRunIds,
  }) async {
    final detail = reason == null || reason.isEmpty ? 'unattributed' : reason;
    debugPrint(
      '[CardRewriter] writer bailed before model session=$sessionId '
      'outcome=$outcome reason=$detail '
      'collectorBoundary=$throughCollectorOrdinal '
      'runs=${reconciliationRunIds.length}',
    );
    try {
      await _repo.saveDebugRun(
        sessionId: sessionId,
        stage: 'selection',
        status: outcome,
        model: '',
        output: null,
        attemptsJson: jsonEncode([
          {
            'outcome': outcome,
            'reason': detail,
            'collectorBoundary': throughCollectorOrdinal,
            'reconciliationRunIds': reconciliationRunIds,
            'at': currentTimestampSeconds(),
          },
        ]),
        updatedAt: currentTimestampSeconds(),
      );
    } catch (error) {
      debugPrint('[CardRewriter] failed to persist selection bail: $error');
    }
  }
}
