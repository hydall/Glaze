import 'dart:async';
import 'dart:convert';

import '../../models/pipeline_settings.dart';
import '../../models/studio_config.dart';
import '../aux_llm_client.dart';
import '../macro_engine.dart';
import 'ledger_run_result.dart';

class LedgerInFlightRegistry {
  const LedgerInFlightRegistry();

  static final Map<String, Future<LedgerRunResult>> _inFlight = {};

  String reconciliationKey({
    required String operationIdentity,
    required String sessionId,
    required String rangeHash,
    required String endMessageId,
    required int endSwipeId,
    required int endAgentSwipeId,
    required PipelineSettings settings,
    required AuxApiConfig config,
    required List<StudioPresetBlock> ledgerBlocks,
    required MacroContext? macroCtx,
  }) => jsonEncode([
    'reconciliation',
    operationIdentity,
    sessionId,
    rangeHash,
    endMessageId,
    endSwipeId,
    endAgentSwipeId,
    settings.toJson(),
    _configIdentity(config),
    ledgerBlocks.map((block) => block.toJson()).toList(),
    _macroIdentity(macroCtx),
  ]);

  String replacementKey({
    required String? operationIdentity,
    required String sessionId,
    required String expectedRunId,
    required PipelineSettings settings,
    required AuxApiConfig config,
    required List<StudioPresetBlock> ledgerBlocks,
    required MacroContext? macroCtx,
  }) => jsonEncode([
    'reconciliation-replacement',
    operationIdentity,
    sessionId,
    expectedRunId,
    settings.toJson(),
    _configIdentity(config),
    ledgerBlocks.map((block) => block.toJson()).toList(),
    _macroIdentity(macroCtx),
  ]);

  String runKey({
    required String operationIdentity,
    required String sessionId,
    required String messageId,
    required int swipeId,
    required int agentSwipeId,
    required String finalAssistantText,
    required String recentHistoryText,
    required bool forceEnabled,
    required bool commitSnapshot,
    required StudioLedgerEngine engine,
    required PipelineSettings settings,
    required AuxApiConfig config,
    required List<StudioPresetBlock> ledgerBlocks,
    required MacroContext? macroCtx,
  }) => jsonEncode([
    'normal',
    operationIdentity,
    sessionId,
    messageId,
    swipeId,
    agentSwipeId,
    finalAssistantText,
    recentHistoryText,
    forceEnabled,
    commitSnapshot,
    engine.name,
    settings.toJson(),
    _configIdentity(config),
    ledgerBlocks.map((block) => block.toJson()).toList(),
    _macroIdentity(macroCtx),
  ]);

  Future<LedgerRunResult> join(
    String key,
    Future<LedgerRunResult> Function() operation,
  ) {
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final completer = Completer<LedgerRunResult>();
    final future = completer.future;
    _inFlight[key] = future;
    unawaited(() async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        if (identical(_inFlight[key], future)) {
          final _ = _inFlight.remove(key);
        }
      }
    }());
    return future;
  }

  List<Object?> _configIdentity(AuxApiConfig config) => [
    config.endpoint,
    config.apiKey,
    config.model,
    config.protocol,
    config.useResponsesApi,
    config.extraRequestParameters.map((item) => item.toJson()).toList(),
  ];

  Object? _macroIdentity(MacroContext? context) => context == null
      ? null
      : [
          context.charName,
          context.charDescription,
          context.charScenario,
          context.charPersonality,
          context.charMesExample,
          context.userName,
          context.personaPrompt,
          context.reasoningStart,
          context.reasoningEnd,
          context.sessionVars,
          context.globalVars,
          context.charId,
          context.sessionId,
          context.summaryContent,
          context.memoryContent,
          context.lorebooksContent,
          context.guidanceText,
          context.macroName,
          context.arcContent,
          context.entitiesContent,
          context.studioSessionState,
        ];
}
