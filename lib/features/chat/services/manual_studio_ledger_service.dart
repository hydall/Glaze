import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/character_repo.dart';
import '../../../core/db/repositories/chat_repo.dart';
import '../../../core/db/repositories/ledger_reconciliation_run_repo.dart';
import '../../../core/db/repositories/studio_preset_repo.dart';
import '../../../core/db/repositories/tracker_repo.dart';
import '../../../core/db/repositories/tracker_snapshot_repo.dart';
import '../../../core/llm/aux_llm_client.dart';
import '../../../core/llm/macro_engine.dart';
import '../../../core/llm/studio_ledger_reconciliation.dart';
import '../../../core/llm/studio_ledger_service.dart';
import '../../../core/llm/studio_turn_config_snapshot.dart';
import '../../../core/models/api_config.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/pipeline_settings.dart';
import '../../../core/models/studio_config.dart';
import '../../../core/services/generation_notification_service.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/memory_agent_providers.dart';
import '../../settings/api_list_provider.dart';

final manualStudioLedgerServiceProvider = Provider<ManualStudioLedgerService>((
  ref,
) {
  return ManualStudioLedgerService(
    chatRepo: ref.watch(chatRepoProvider),
    snapshotRepo: ref.watch(trackerSnapshotRepoProvider),
    trackerRepo: ref.watch(trackerRepoProvider),
    presetRepo: ref.watch(studioPresetRepoProvider),
    characterRepo: ref.watch(characterRepoProvider),
    reconciliationRunRepo: ref.watch(ledgerReconciliationRunRepoProvider),
    ledger: DefaultStudioLedgerExecutor(ref.watch(studioLedgerServiceProvider)),
    loadApiConfigs: () async {
      await ref.read(apiListProvider.future);
      return ref.read(apiListProvider).value ?? const <ApiConfig>[];
    },
    readActiveApiConfig: () => ref.read(activeApiConfigProvider),
    readPipelineSettings: () => ref.read(pipelineSettingsProvider),
    loadActivePresetId: () => ref.read(activeStudioPresetProvider.future),
    acquireForegroundLease:
        GenerationNotificationService.instance.acquirePostGenerationLease,
  );
});

class ManualStudioLedgerResult {
  const ManualStudioLedgerResult({
    required this.target,
    required this.result,
    required this.startedAtMs,
  });

  final ChatMessage target;
  final LedgerRunResult result;
  final int startedAtMs;
}

class ManualStudioLedgerConfigException implements Exception {
  const ManualStudioLedgerConfigException(this.cause);

  final Object cause;

  @override
  String toString() => '$cause';
}

abstract interface class StudioLedgerExecutor {
  Future<LedgerRunResult> run({
    required String sessionId,
    required StudioTurnConfigSnapshot turnConfig,
    required AuxApiConfig config,
    required String finalAssistantText,
    required String recentHistoryText,
    required ChatMessage target,
    required MacroContext macroCtx,
    required FutureOr<bool> Function() isStillCurrent,
    required StudioLedgerEngine engine,
  });

  Future<LedgerRunResult> reconcile({
    required String sessionId,
    required StudioTurnConfigSnapshot turnConfig,
    required AuxApiConfig config,
    required LedgerReconciliationPlan plan,
    required MacroContext macroCtx,
    required FutureOr<bool> Function() isStillCurrent,
  });

  Future<LedgerRunResult> replaceLatestReconciliation({
    required String sessionId,
    required String expectedRunId,
    required StudioTurnConfigSnapshot turnConfig,
    required AuxApiConfig config,
    required MacroContext macroCtx,
    required FutureOr<bool> Function() isStillCurrent,
  });
}

class DefaultStudioLedgerExecutor implements StudioLedgerExecutor {
  const DefaultStudioLedgerExecutor(this._service);

  final StudioLedgerService _service;

  @override
  Future<LedgerRunResult> run({
    required String sessionId,
    required StudioTurnConfigSnapshot turnConfig,
    required AuxApiConfig config,
    required String finalAssistantText,
    required String recentHistoryText,
    required ChatMessage target,
    required MacroContext macroCtx,
    required FutureOr<bool> Function() isStillCurrent,
    required StudioLedgerEngine engine,
  }) {
    return _service.run(
      sessionId: sessionId,
      settings: turnConfig.pipelineSettings,
      config: config,
      finalAssistantText: finalAssistantText,
      recentHistoryText: recentHistoryText,
      messageId: target.id,
      swipeId: target.swipeId,
      agentSwipeId: target.agentSwipeId,
      forceEnabled: true,
      ledgerBlocks: turnConfig.preset?.blocks ?? const [],
      macroCtx: macroCtx,
      isStillCurrent: isStillCurrent,
      commitSnapshot: true,
      engine: engine,
      operationIdentity:
          'manual:${target.id}:${target.swipeId}:${target.agentSwipeId}',
    );
  }

  @override
  Future<LedgerRunResult> reconcile({
    required String sessionId,
    required StudioTurnConfigSnapshot turnConfig,
    required AuxApiConfig config,
    required LedgerReconciliationPlan plan,
    required MacroContext macroCtx,
    required FutureOr<bool> Function() isStillCurrent,
  }) {
    return _service.reconcile(
      sessionId: sessionId,
      settings: turnConfig.pipelineSettings,
      config: config,
      plan: plan,
      ledgerBlocks: turnConfig.preset?.blocks ?? const [],
      macroCtx: macroCtx,
      isStillCurrent: isStillCurrent,
      operationIdentity:
          'manual:${plan.rangeHash}:${plan.endMessage.id}:'
          '${plan.endMessage.swipeId}:${plan.endMessage.agentSwipeId}',
    );
  }

  @override
  Future<LedgerRunResult> replaceLatestReconciliation({
    required String sessionId,
    required String expectedRunId,
    required StudioTurnConfigSnapshot turnConfig,
    required AuxApiConfig config,
    required MacroContext macroCtx,
    required FutureOr<bool> Function() isStillCurrent,
  }) {
    return _service.replaceLatestReconciliation(
      sessionId: sessionId,
      expectedRunId: expectedRunId,
      settings: turnConfig.pipelineSettings,
      config: config,
      ledgerBlocks: turnConfig.preset?.blocks ?? const [],
      macroCtx: macroCtx,
      isStillCurrent: isStillCurrent,
      operationIdentity: 'manual-replacement:$expectedRunId',
    );
  }
}

class ManualStudioLedgerService {
  const ManualStudioLedgerService({
    required this.chatRepo,
    required this.snapshotRepo,
    required this.trackerRepo,
    required this.presetRepo,
    required this.characterRepo,
    required this.reconciliationRunRepo,
    required this.ledger,
    required this.loadApiConfigs,
    required this.readActiveApiConfig,
    required this.readPipelineSettings,
    required this.loadActivePresetId,
    required this.acquireForegroundLease,
  });

  final ChatRepo chatRepo;
  final TrackerSnapshotRepo snapshotRepo;
  final TrackerRepo trackerRepo;
  final StudioPresetRepo presetRepo;
  final CharacterRepo characterRepo;
  final LedgerReconciliationRunRepo reconciliationRunRepo;
  final StudioLedgerExecutor ledger;
  final Future<List<ApiConfig>> Function() loadApiConfigs;
  final ApiConfig? Function() readActiveApiConfig;
  final PipelineSettings Function() readPipelineSettings;
  final Future<String> Function() loadActivePresetId;
  final Future<PostGenerationForegroundLease> Function() acquireForegroundLease;

  Future<ManualStudioLedgerResult> rerun({
    required String sessionId,
    required ChatMessage target,
  }) async {
    final turnConfigFuture = _resolveTurnConfig(sessionId);
    final session = await chatRepo.getById(sessionId);
    if (session == null) throw StateError('Session not found');
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final isTargetCurrent = _targetOwnershipGuard(sessionId, target);
    final turnConfig = await turnConfigFuture;
    _requireLedgerEnabled(turnConfig);
    final AuxApiConfig ledgerConfig;
    try {
      ledgerConfig = turnConfig.resolveLedgerConfig(errorLabel: 'ledger-rerun');
    } catch (e) {
      throw ManualStudioLedgerConfigException(e);
    }
    final macroCtx = await _macroContext(
      sessionId,
      session.characterId,
      _personaName(session.messages),
    );
    if (!await isTargetCurrent()) {
      return _abortedManualResult(target, startedAt);
    }
    final result = await _runForeground(
      () => ledger.run(
        sessionId: sessionId,
        turnConfig: turnConfig,
        config: ledgerConfig,
        finalAssistantText: target.content,
        recentHistoryText: _recentHistoryText(
          session.messages,
          maxMessages: 10,
          upToMessageId: target.id,
        ),
        target: target,
        macroCtx: macroCtx,
        isStillCurrent: isTargetCurrent,
        engine: StudioLedgerEngine.currentReconciled,
      ),
    );
    if (!await isTargetCurrent()) {
      return _abortedManualResult(target, startedAt);
    }
    await trackerRepo.upsertValue(
      sessionId,
      '_ledger_diag:studio_ledger',
      'turn=${target.id} \u2022 manual rerun, ${result.status} '
          '(ops=${result.opsApplied})'
          '${result.error == null ? '' : ': ${result.error}'}',
      scope: 'ledger_diagnostic',
      provenance:
          'message=${target.id}|swipe=${target.swipeId}|'
          'agentSwipe=${target.agentSwipeId}|manual=1',
    );
    return ManualStudioLedgerResult(
      target: target,
      result: result,
      startedAtMs: startedAt,
    );
  }

  Future<ManualStudioLedgerResult> reconcile(String sessionId) async {
    final turnConfigFuture = _resolveTurnConfig(sessionId);
    final session = await chatRepo.getById(sessionId);
    if (session == null) throw StateError('Session not found');
    final turnConfig = await turnConfigFuture;
    _requireLedgerEnabled(turnConfig);
    final snapshots = await snapshotRepo.getBySessionId(sessionId);
    final committedAnchors = snapshots
        .where((snapshot) => snapshot.committed)
        .map(
          (snapshot) =>
              '${snapshot.messageId}\u001f${snapshot.swipeId}\u001f'
              '${snapshot.agentSwipeId}',
        )
        .toSet();
    final endpoint = session.messages.reversed.where((message) {
      final anchor =
          '${message.id}\u001f${message.swipeId}\u001f${message.agentSwipeId}';
      return message.role == 'assistant' &&
          !message.isError &&
          !message.isTyping &&
          !message.isHidden &&
          message.content.trim().isNotEmpty &&
          committedAnchors.contains(anchor);
    }).firstOrNull;
    if (endpoint == null) {
      throw StateError('No committed Ledger snapshot to reconcile');
    }
    final plan = const LedgerReconciliationPlanner().planForEndpoint(
      messages: session.messages,
      endAssistantMessageId: endpoint.id,
    );
    if (plan == null) {
      throw StateError('No reviewable messages end at the committed snapshot');
    }

    final ledgerConfig = turnConfig.resolveLedgerConfig(
      errorLabel: 'ledger-reconciliation-manual',
    );
    final macroCtx = await _macroContext(
      sessionId,
      session.characterId,
      _personaName(session.messages),
    );
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final isTargetCurrent = _targetOwnershipGuard(sessionId, endpoint);
    if (!await isTargetCurrent()) {
      return _abortedManualResult(endpoint, startedAt);
    }
    final result = await _runForeground(
      () => ledger.reconcile(
        sessionId: sessionId,
        turnConfig: turnConfig,
        config: ledgerConfig,
        plan: plan,
        macroCtx: macroCtx,
        isStillCurrent: isTargetCurrent,
      ),
    );
    if (!await isTargetCurrent()) {
      return _abortedManualResult(endpoint, startedAt);
    }
    await _writeReconciliationDiagnostic(
      sessionId: sessionId,
      trigger: endpoint,
      plan: plan,
      result: result,
    );
    return ManualStudioLedgerResult(
      target: endpoint,
      result: result,
      startedAtMs: startedAt,
    );
  }

  Future<ManualStudioLedgerResult> regenerateLatest({
    required String sessionId,
    required String expectedRunId,
  }) async {
    final turnConfigFuture = _resolveTurnConfig(sessionId);
    final session = await chatRepo.getById(sessionId);
    if (session == null) throw StateError('Session not found');
    final head = await reconciliationRunRepo.getHead(sessionId);
    if (head == null || head.id != expectedRunId) {
      throw StateError('The selected reconciliation is no longer latest');
    }
    final messages = await reconciliationRunRepo.reconstructSelectedMessages(
      head,
    );
    if (messages == null || messages.isEmpty) {
      throw StateError('The committed message range no longer matches');
    }
    final plan = LedgerReconciliationPlan(
      messages: messages,
      endMessage: messages.last,
      rangeHash: computeLedgerReconciliationRangeHash(messages),
    );
    final turnConfig = await turnConfigFuture;
    _requireLedgerEnabled(turnConfig);
    final ledgerConfig = turnConfig.resolveLedgerConfig(
      errorLabel: 'ledger-reconciliation-regeneration',
    );
    final macroCtx = await _macroContext(
      sessionId,
      session.characterId,
      _personaName(session.messages),
    );
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final isTargetCurrent = _targetOwnershipGuard(sessionId, plan.endMessage);
    if (!await isTargetCurrent()) {
      return _abortedManualResult(plan.endMessage, startedAt);
    }
    final result = await _runForeground(
      () => ledger.replaceLatestReconciliation(
        sessionId: sessionId,
        expectedRunId: expectedRunId,
        turnConfig: turnConfig,
        config: ledgerConfig,
        macroCtx: macroCtx,
        isStillCurrent: isTargetCurrent,
      ),
    );
    if (!await isTargetCurrent()) {
      return _abortedManualResult(plan.endMessage, startedAt);
    }
    await _writeReconciliationDiagnostic(
      sessionId: sessionId,
      trigger: plan.endMessage,
      plan: plan,
      result: result,
      action: 'regenerate',
    );
    return ManualStudioLedgerResult(
      target: plan.endMessage,
      result: result,
      startedAtMs: startedAt,
    );
  }

  Future<StudioTurnConfigSnapshot> _resolveTurnConfig(String sessionId) async {
    final pipeline = readPipelineSettings();
    final activeApiConfig = readActiveApiConfig();
    final apiConfigs = List<ApiConfig>.unmodifiable(await loadApiConfigs());
    final preset = await presetRepo.getById(await loadActivePresetId());
    return StudioTurnConfigSnapshot(
      config: preset == null
          ? null
          : StudioConfig(sessionId: sessionId, enabled: true),
      preset: preset,
      pipelineSettings: pipeline,
      apiConfigs: apiConfigs,
      activeApiConfig: activeApiConfig,
    );
  }

  void _requireLedgerEnabled(StudioTurnConfigSnapshot turnConfig) {
    if (!turnConfig.ledgerEnabled) {
      throw const ManualStudioLedgerConfigException(
        'Studio Ledger is disabled in the active preset',
      );
    }
  }

  Future<MacroContext> _macroContext(
    String sessionId,
    String characterId,
    String userName,
  ) async {
    final character = await characterRepo.getById(characterId);
    return MacroContext(
      charName: character?.name ?? '',
      charDescription: character?.description,
      charScenario: character?.scenario,
      charPersonality: character?.personality,
      charMesExample: character?.mesExample,
      userName: userName,
      macroName: character?.macroName,
      charId: characterId,
      sessionId: sessionId,
    );
  }

  String _personaName(Iterable<ChatMessage> messages) {
    for (final message in messages.toList().reversed) {
      final name = message.personaName?.trim();
      if (name != null && name.isNotEmpty) return name;
    }
    return 'User';
  }

  Future<LedgerRunResult> _runForeground(
    Future<LedgerRunResult> Function() action,
  ) async {
    final lease = await acquireForegroundLease();
    try {
      return await action();
    } finally {
      await lease.release();
    }
  }

  FutureOr<bool> Function() _targetOwnershipGuard(
    String sessionId,
    ChatMessage target,
  ) => () async {
    final current = await chatRepo.getById(sessionId);
    final message = current?.messages
        .where((item) => item.id == target.id)
        .firstOrNull;
    return message != null &&
        message.swipeId == target.swipeId &&
        message.agentSwipeId == target.agentSwipeId &&
        message.content == target.content;
  };

  ManualStudioLedgerResult _abortedManualResult(
    ChatMessage target,
    int startedAt,
  ) => ManualStudioLedgerResult(
    target: target,
    result: LedgerRunResult.aborted,
    startedAtMs: startedAt,
  );

  Future<void> _writeReconciliationDiagnostic({
    required String sessionId,
    required ChatMessage trigger,
    required LedgerReconciliationPlan plan,
    required LedgerRunResult result,
    String action = 'run',
  }) {
    final attempts = result.attempts.isEmpty
        ? 'none'
        : result.attempts
              .map(
                (attempt) =>
                    '${attempt.attempt}:${attempt.status}'
                    '/http=${attempt.statusCode}/ms=${attempt.elapsedMs}'
                    '${attempt.error == null ? '' : '/error=${attempt.error}'}',
              )
              .join(',');
    return trackerRepo.upsertValue(
      sessionId,
      '_ledger_diag:studio_ledger_reconciliation',
      'trigger=${trigger.id} \u2022 range=${plan.startMessageId}..${plan.endMessage.id} '
          '\u2022 status=${result.status} \u2022 ops=${result.opsApplied} '
          '\u2022 elapsedMs=${result.elapsedMs} \u2022 model=${result.model ?? 'unknown'} '
          '\u2022 attempts=$attempts \u2022 action=$action \u2022 manual=1'
          '${result.error == null ? '' : ' \u2022 error=${result.error}'}',
      scope: 'ledger_diagnostic',
      provenance:
          'message=${trigger.id}|swipe=${trigger.swipeId}|'
          'agentSwipe=${trigger.agentSwipeId}|range=${plan.startMessageId}..'
          '${plan.endMessage.id}|action=$action|manual=1',
    );
  }
}

String _recentHistoryText(
  List<ChatMessage> messages, {
  int maxMessages = 10,
  String? upToMessageId,
}) {
  var source = messages;
  if (upToMessageId != null) {
    final idx = messages.indexWhere((m) => m.id == upToMessageId);
    if (idx >= 0) source = messages.sublist(0, idx + 1);
  }
  final start = source.length > maxMessages ? source.length - maxMessages : 0;
  final lines = <String>[];
  for (final msg in source.sublist(start)) {
    if (msg.isError || msg.isTyping) continue;
    final content = msg.content.trim();
    if (content.isEmpty) continue;
    final role = msg.role == 'assistant' ? 'Assistant' : 'User';
    lines.add('$role: $content');
  }
  return lines.join('\n\n');
}
