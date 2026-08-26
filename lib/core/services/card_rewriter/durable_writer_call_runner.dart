import 'dart:convert';

import 'package:dio/dio.dart';

import '../../db/app_db.dart';
import '../../db/repositories/card_evolution_repo.dart';
import '../../db/repositories/card_evolution_writer_call_repo.dart';
import '../../llm/aux_llm_client.dart';
import '../../llm/aux_retry_runner.dart';
import '../../llm/transport/llm_capture_context.dart';
import '../../models/agent_operation_record.dart';
import '../../utils/cast_helpers.dart';
import '../../utils/id_generator.dart';
import '../../utils/time_helpers.dart';
import 'card_evolution_diagnostics.dart';
import 'card_rewrite_operation_parser.dart';
import 'card_rewriter_contracts.dart';
import 'manual_rewrite_service.dart';

const _writerMaxTokens = 40000;

/// Runs one durable Card Evolution writer checkpoint from preparation through
/// parsing and completion while preserving claim ownership.
final class DurableWriterCallRunner {
  const DurableWriterCallRunner({
    required this.repo,
    required this.writerCallRepo,
    required this.executor,
    required this.diagnostics,
    required this.timeoutMs,
    required this.leaseSeconds,
  });

  final CardEvolutionRepo repo;
  final CardEvolutionWriterCallRepo writerCallRepo;
  final CardRewriteLlmExecutor executor;
  final CardEvolutionDiagnostics diagnostics;
  final int timeoutMs;
  final int leaseSeconds;

  Future<DurableWriterCallResult> runTextCall({
    required CardEvolutionClaim claim,
    required String owner,
    required LazyWriterModel model,
    required CancelToken token,
    required List<CardEvolutionWriterCallRow> chain,
    required int chainIndex,
    required int ordinal,
    required String stage,
    required int stageOrdinal,
    required String captureStage,
    required String prompt,
    required String? parentCallId,
    required String? manualCallId,
    required String? manualResponse,
  }) async {
    final prepared = await _prepareCall(
      claim: claim,
      owner: owner,
      chain: chain,
      chainIndex: chainIndex,
      ordinal: ordinal,
      stage: stage,
      stageOrdinal: stageOrdinal,
      prompt: prompt,
      parentCallId: parentCallId,
    );
    if (prepared.failure != null || prepared.call!.status == 'completed') {
      return prepared;
    }
    return _executePreparedCall(
      claim: claim,
      owner: owner,
      model: model,
      token: token,
      call: prepared.call!,
      captureStage: captureStage,
      manualResponse: manualCallId == prepared.call!.id ? manualResponse : null,
      parse: (response) =>
          ParsedWriterCallResult.accepted(jsonEncode({'handoff': response})),
    );
  }

  Future<DurableWriterCallResult> runOperationCall({
    required CardEvolutionClaim claim,
    required String owner,
    required LazyWriterModel model,
    required CancelToken token,
    required List<CardEvolutionWriterCallRow> chain,
    required int chainIndex,
    required int ordinal,
    required String stage,
    required String captureStage,
    required String prompt,
    required String? parentCallId,
    required String cardContext,
    Set<CardRewriteField>? allowedCardFields,
    required String? manualCallId,
    required String? manualResponse,
  }) async {
    final prepared = await _prepareCall(
      claim: claim,
      owner: owner,
      chain: chain,
      chainIndex: chainIndex,
      ordinal: ordinal,
      stage: stage,
      stageOrdinal: 1,
      prompt: prompt,
      parentCallId: parentCallId,
    );
    if (prepared.failure != null) return prepared;
    if (prepared.call!.status == 'completed') {
      final decoded = _decodeOperations(prepared.call!.resultJson);
      if (prepared.call!.parserCode == 'invalidOutput' &&
          stage == 'card_writer') {
        return DurableWriterCallResult.completed(prepared.call!);
      }
      if (decoded == null) {
        return failClosed(
          claim,
          owner,
          'checkpointMalformed',
          'Stored $stage resultJson is malformed',
        );
      }
      return DurableWriterCallResult.completed(prepared.call!, decoded);
    }
    return _executePreparedCall(
      claim: claim,
      owner: owner,
      model: model,
      token: token,
      call: prepared.call!,
      captureStage: captureStage,
      manualResponse: manualCallId == prepared.call!.id ? manualResponse : null,
      completeRejected: stage == 'card_writer',
      parse: (response) {
        final parsed = allowedCardFields == null
            ? CardRewriteOperationParser.parseLorebookEvolutionBatch(response)
            : CardRewriteOperationParser.parseEvolutionBatch(
                response,
                allowedFields: allowedCardFields,
              );
        final detail = parsed == null
            ? allowedCardFields == null
                  ? 'Lorebook response is not a valid operation batch'
                  : CardRewriteOperationParser.explainEvolutionBatchFailure(
                      response,
                      allowedFields: allowedCardFields,
                    )
            : allowedCardFields == null
            ? null
            : _scopeAllowlistFailure(
                parsed.whereType<CardRewriteOperationSnapshot>().toList(),
                cardContext,
              );
        if (parsed == null || detail != null) {
          return ParsedWriterCallResult.rejected(detail ?? 'invalid output');
        }
        return ParsedWriterCallResult.accepted(
          _encodeOperations(parsed),
          parsed,
        );
      },
    );
  }

  Future<DurableWriterCallResult> _prepareCall({
    required CardEvolutionClaim claim,
    required String owner,
    required List<CardEvolutionWriterCallRow> chain,
    required int chainIndex,
    required int ordinal,
    required String stage,
    required int stageOrdinal,
    required String prompt,
    required String? parentCallId,
  }) async {
    final outcome = await writerCallRepo.prepareNextCall(
      claimId: claim.row.id,
      ownerId: owner,
      now: currentTimestampSeconds(),
      ordinal: ordinal,
      stage: stage,
      stageOrdinal: stageOrdinal,
      prompt: prompt,
      parentCallId: parentCallId,
    );
    final call = outcome.row;
    if (call == null) {
      return failClosed(claim, owner, outcome.kind, 'Unable to prepare $stage');
    }
    if (call.ordinal != ordinal ||
        call.stage != stage ||
        call.stageOrdinal != stageOrdinal ||
        call.promptHash != computeHash(prompt) ||
        call.prompt != prompt ||
        chainIndex < chain.length && chain[chainIndex].id != call.id) {
      return failClosed(
        claim,
        owner,
        'checkpointMismatch',
        'Stored writer checkpoint does not match recomputed $stage request',
      );
    }
    if (call.status == 'failed') {
      return failClosed(
        claim,
        owner,
        'writerCallFailed',
        'Writer checkpoint ${call.id} requires explicit recovery',
      );
    }
    return DurableWriterCallResult.completed(call);
  }

  Future<DurableWriterCallResult> _executePreparedCall({
    required CardEvolutionClaim claim,
    required String owner,
    required LazyWriterModel model,
    required CancelToken token,
    required CardEvolutionWriterCallRow call,
    required String captureStage,
    required ParsedWriterCallResult Function(String response) parse,
    String? manualResponse,
    bool completeRejected = false,
  }) async {
    final now = currentTimestampSeconds();
    if (!await repo.renewClaimLease(
      claimId: claim.row.id,
      ownerId: owner,
      now: now,
      leaseSeconds: leaseSeconds,
    )) {
      await markWriterFailure(
        claim,
        owner,
        'leaseLost',
        'Writer lease could not be renewed before ${call.stage}',
      );
      return const DurableWriterCallResult.failure(
        CardEvolutionFinalizeOutcome('leaseLost'),
      );
    }
    final context = LlmCaptureContext(
      stage: captureStage,
      sessionId: claim.row.sessionId,
      pipelineRunId: claim.row.id,
      callId: manualResponse == null ? null : 'llm-call-${generateId()}',
      parentCallId: call.lastCallId ?? call.parentCallId ?? call.id,
      logicalCallId: '${claim.row.id}:${call.stage}:${call.stageOrdinal}',
      relatedArtifactId: claim.row.id,
      stageOrdinal: call.stageOrdinal,
    );
    AuxCallOutcome? outcome;
    final config = manualResponse == null ? await model.resolve() : null;
    final response =
        manualResponse ??
        (outcome = await executor(
          config: config!,
          prompt: call.prompt,
          maxTokens: _writerMaxTokens,
          temperature: 0.2,
          timeoutMs: timeoutMs,
          cancelToken: token,
          captureContext: context,
        )).text;
    if (manualResponse == null) {
      final modelOutcome = outcome!;
      if (token.isCancelled ||
          modelOutcome.status == AgentOperationStatus.aborted ||
          !modelOutcome.isOk ||
          response == null) {
        final code = token.isCancelled
            ? 'cancelled'
            : '${call.stage}ModelFailed';
        final detail = _modelFailureDetail(modelOutcome);
        await writerCallRepo.failCall(
          id: call.id,
          claimId: claim.row.id,
          ownerId: owner,
          now: currentTimestampSeconds(),
          code: code,
          detail: detail,
          lastCallId: modelOutcome.selectedCaptureContext?.callId ?? call.id,
        );
        await diagnostics.saveModelOutcome(
          sessionId: claim.row.sessionId,
          stage: call.stage == 'lorebook_writer' ? 'lorebook' : 'card',
          model: config!.model,
          outcome: modelOutcome,
        );
        await markWriterFailure(claim, owner, code, detail);
        return DurableWriterCallResult.failure(
          CardEvolutionFinalizeOutcome(
            token.isCancelled ? 'cancelled' : _publicModelFailure(call.stage),
            null,
            detail,
          ),
        );
      }
    }
    final responseText = response!;
    final parserContext = outcome?.selectedCaptureContext ?? context;
    final parsed = parse(responseText);
    await diagnostics.recordWriterParserVerdict(
      context: parserContext,
      accepted: parsed.accepted,
      detail: parsed.detail,
      responseText: manualResponse == null ? null : responseText,
      source: manualResponse != null
          ? 'manual_correction'
          : call.source == 'exact_retry'
          ? 'exact_retry'
          : 'model',
    );
    if (!parsed.accepted && (!completeRejected || manualResponse != null)) {
      await writerCallRepo.failCall(
        id: call.id,
        claimId: claim.row.id,
        ownerId: owner,
        now: currentTimestampSeconds(),
        code: 'parserRejected',
        detail: parsed.detail,
        lastCallId: parserContext.callId,
        responseText: responseText,
        parserCode: 'invalidOutput',
        parserDetail: parsed.detail,
      );
      await markWriterFailure(claim, owner, 'parserRejected', parsed.detail);
      return DurableWriterCallResult.failure(
        CardEvolutionFinalizeOutcome(
          call.stage == 'lorebook_writer'
              ? 'invalidLorebookOutput'
              : 'invalidCardOutput',
          null,
          parsed.detail,
        ),
      );
    }
    final completed = await writerCallRepo.completeCall(
      id: call.id,
      claimId: claim.row.id,
      ownerId: owner,
      now: currentTimestampSeconds(),
      responseText: responseText,
      resultJson: parsed.resultJson ?? jsonEncode({'rejected': parsed.detail}),
      source: manualResponse != null
          ? 'manual_correction'
          : call.source == 'exact_retry'
          ? 'exact_retry'
          : 'model',
      parserCode: parsed.accepted ? 'accepted' : 'invalidOutput',
      parserDetail: parsed.detail,
      lastCallId: parserContext.callId,
    );
    if (!completed) {
      return failClosed(
        claim,
        owner,
        'leaseLost',
        'Call completion lost ownership',
      );
    }
    if (outcome != null) {
      await diagnostics.saveModelOutcome(
        sessionId: claim.row.sessionId,
        stage: call.stage == 'lorebook_writer' ? 'lorebook' : 'card',
        model: config!.model,
        outcome: outcome,
      );
    }
    final stored = await writerCallRepo.getById(call.id);
    return DurableWriterCallResult.completed(stored!, parsed.operations);
  }

  Future<DurableWriterCallResult> failClosed(
    CardEvolutionClaim claim,
    String owner,
    String code,
    String detail,
  ) async {
    await markWriterFailure(claim, owner, code, detail);
    return DurableWriterCallResult.failure(
      CardEvolutionFinalizeOutcome(code, null, detail),
    );
  }

  Future<void> markWriterFailure(
    CardEvolutionClaim claim,
    String owner,
    String code,
    String? detail,
  ) => repo.markWriterFailed(
    claimId: claim.row.id,
    ownerId: owner,
    now: currentTimestampSeconds(),
    code: code,
    detail: detail,
  );

  static String _publicModelFailure(String stage) =>
      stage == 'lorebook_writer' ? 'lorebookModelFailed' : 'cardModelFailed';

  static String _encodeOperations(List<RewriteOperationSnapshot> operations) =>
      jsonEncode([
        for (final operation in operations)
          jsonDecode(RewriteOperationSnapshotCodec.encode(operation)),
      ]);

  static List<RewriteOperationSnapshot>? _decodeOperations(String? value) {
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) return null;
      final operations = <RewriteOperationSnapshot>[];
      for (final raw in decoded) {
        final operation = RewriteOperationSnapshotCodec.tryDecode(raw);
        if (operation == null) return null;
        operations.add(operation);
      }
      return operations;
    } catch (_) {
      return null;
    }
  }

  static String? _scopeAllowlistFailure(
    List<CardRewriteOperationSnapshot> operations,
    String selectedInputJson,
  ) {
    final targets = _retrievalTargets(selectedInputJson);
    if (targets == null || targets.isEmpty) return null;
    final allowed = targets.keys.where(_isCardScopeTarget).toSet();
    if (allowed.isEmpty) return null;
    for (final operation in operations) {
      final scope = operation.transition.scopeKey;
      if (!allowed.contains(scope)) {
        return 'scopeKey "$scope" is not an available retrieval target';
      }
    }
    return null;
  }

  static Map<String, String>? _retrievalTargets(String selectedInputJson) {
    try {
      final decoded = jsonDecode(selectedInputJson);
      if (decoded is! Map ||
          decoded['availableObservationRetrievalTargets'] is! List) {
        return null;
      }
      final result = <String, String>{};
      for (final target
          in decoded['availableObservationRetrievalTargets'] as List) {
        if (target is! Map ||
            target['key'] is! String ||
            target['kind'] is! String) {
          return null;
        }
        result[target['key'] as String] = target['kind'] as String;
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  static bool _isCardScopeTarget(String key) =>
      !key.contains('/') && CardRewriteScope.tryParse(key) != null;

  static String _modelFailureDetail(AuxCallOutcome outcome) {
    final attempts = outcome.attempts;
    if (attempts.isEmpty) return 'status: ${outcome.status.name}';
    final last = attempts.last;
    final error = last.error?.replaceAll(RegExp(r'\s+'), ' ').trim();
    final compactError = error == null || error.isEmpty
        ? ''
        : ': ${error.length > 180 ? '${error.substring(0, 180)}...' : error}';
    final code = last.statusCode == 0 ? '' : ' HTTP ${last.statusCode}';
    return '${attempts.length} attempt(s), ${last.status}$code$compactError';
  }
}

final class LazyWriterModel {
  LazyWriterModel(this._resolver);

  final CardRewriteModelResolver _resolver;
  Future<AuxApiConfig>? _value;

  Future<AuxApiConfig> resolve() => _value ??= _resolver();
}

final class DurableWriterCallResult {
  const DurableWriterCallResult.completed(this.call, [this.operations])
    : failure = null;
  const DurableWriterCallResult.failure(this.failure)
    : call = null,
      operations = null;

  final CardEvolutionWriterCallRow? call;
  final List<RewriteOperationSnapshot>? operations;
  final CardEvolutionFinalizeOutcome? failure;
}

final class ParsedWriterCallResult {
  const ParsedWriterCallResult.accepted(this.resultJson, [this.operations])
    : accepted = true,
      detail = null;
  const ParsedWriterCallResult.rejected(this.detail)
    : accepted = false,
      resultJson = null,
      operations = null;

  final bool accepted;
  final String? resultJson;
  final List<RewriteOperationSnapshot>? operations;
  final String? detail;
}
