import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/character_repo.dart';
import '../../../core/db/repositories/chat_repo.dart';
import '../../../core/db/repositories/studio_config_repo.dart';
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
import '../../../core/services/generation_notification_service.dart';
import '../../../core/services/post_gen_foreground_guard.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/memory_agent_providers.dart';
import '../../settings/api_list_provider.dart';

final manualStudioLedgerServiceProvider = Provider<ManualStudioLedgerService>((
  ref,
) {
  return ManualStudioLedgerService(
    chatRepo: ref.watch(chatRepoProvider),
    studioConfigRepo: ref.watch(studioConfigRepoProvider),
    snapshotRepo: ref.watch(trackerSnapshotRepoProvider),
    trackerRepo: ref.watch(trackerRepoProvider),
    presetRepo: ref.watch(studioPresetRepoProvider),
    characterRepo: ref.watch(characterRepoProvider),
    ledger: DefaultStudioLedgerExecutor(ref.watch(studioLedgerServiceProvider)),
    loadApiConfigs: () async {
      await ref.read(apiListProvider.future);
      return ref.read(apiListProvider).value ?? const <ApiConfig>[];
    },
    readActiveApiConfig: () => ref.read(activeApiConfigProvider),
    readPipelineSettings: () => ref.read(pipelineSettingsProvider),
    loadActivePresetId: () => ref.read(activeStudioPresetProvider.future),
    onForegroundStarted:
        GenerationNotificationService.instance.onPostGenStarted,
    onForegroundFinished:
        GenerationNotificationService.instance.onPostGenFinished,
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
  });

  Future<LedgerRunResult> reconcile({
    required String sessionId,
    required StudioTurnConfigSnapshot turnConfig,
    required AuxApiConfig config,
    required LedgerReconciliationPlan plan,
    required MacroContext macroCtx,
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
      commitSnapshot: true,
    );
  }

  @override
  Future<LedgerRunResult> reconcile({
    required String sessionId,
    required StudioTurnConfigSnapshot turnConfig,
    required AuxApiConfig config,
    required LedgerReconciliationPlan plan,
    required MacroContext macroCtx,
  }) {
    return _service.reconcile(
      sessionId: sessionId,
      settings: turnConfig.pipelineSettings,
      config: config,
      plan: plan,
      ledgerBlocks: turnConfig.preset?.blocks ?? const [],
      macroCtx: macroCtx,
    );
  }
}

class ManualStudioLedgerService {
  const ManualStudioLedgerService({
    required this.chatRepo,
    required this.studioConfigRepo,
    required this.snapshotRepo,
    required this.trackerRepo,
    required this.presetRepo,
    required this.characterRepo,
    required this.ledger,
    required this.loadApiConfigs,
    required this.readActiveApiConfig,
    required this.readPipelineSettings,
    required this.loadActivePresetId,
    required this.onForegroundStarted,
    required this.onForegroundFinished,
  });

  final ChatRepo chatRepo;
  final StudioConfigRepo studioConfigRepo;
  final TrackerSnapshotRepo snapshotRepo;
  final TrackerRepo trackerRepo;
  final StudioPresetRepo presetRepo;
  final CharacterRepo characterRepo;
  final StudioLedgerExecutor ledger;
  final Future<List<ApiConfig>> Function() loadApiConfigs;
  final ApiConfig? Function() readActiveApiConfig;
  final PipelineSettings Function() readPipelineSettings;
  final Future<String> Function() loadActivePresetId;
  final Future<void> Function() onForegroundStarted;
  final Future<void> Function() onForegroundFinished;

  Future<ManualStudioLedgerResult> rerun({
    required String sessionId,
    required ChatMessage target,
  }) async {
    final turnConfigFuture = _resolveTurnConfig(sessionId);
    final session = await chatRepo.getById(sessionId);
    if (session == null) throw StateError('Session not found');
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final turnConfig = await turnConfigFuture;
    final AuxApiConfig ledgerConfig;
    try {
      ledgerConfig = turnConfig.resolveCleanerConfig(
        errorLabel: 'ledger-rerun',
      );
    } catch (e) {
      throw ManualStudioLedgerConfigException(e);
    }
    final macroCtx = await _macroContext(sessionId, session.characterId);
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
      ),
    );
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
    final session = await chatRepo.getById(sessionId);
    if (session == null) throw StateError('Session not found');
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

    final turnConfig = await _resolveTurnConfig(sessionId);
    final ledgerConfig = turnConfig.resolveCleanerConfig(
      errorLabel: 'ledger-reconciliation-manual',
    );
    final macroCtx = await _macroContext(sessionId, session.characterId);
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    await _writeReconciliationDiagnostic(
      sessionId: sessionId,
      trigger: endpoint,
      plan: plan,
      result: LedgerRunResult(status: 'running', model: ledgerConfig.model),
    );
    final result = await _runForeground(
      () => ledger.reconcile(
        sessionId: sessionId,
        turnConfig: turnConfig,
        config: ledgerConfig,
        plan: plan,
        macroCtx: macroCtx,
      ),
    );
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

  Future<StudioTurnConfigSnapshot> _resolveTurnConfig(String sessionId) async {
    final pipeline = readPipelineSettings();
    final activeApiConfig = readActiveApiConfig();
    final apiConfigs = List<ApiConfig>.unmodifiable(await loadApiConfigs());
    final config = await studioConfigRepo.getBySessionId(sessionId);
    final preset = await presetRepo.getById(await loadActivePresetId());
    return StudioTurnConfigSnapshot(
      config: config,
      preset: preset,
      pipelineSettings: pipeline,
      apiConfigs: apiConfigs,
      activeApiConfig: activeApiConfig,
    );
  }

  Future<MacroContext> _macroContext(
    String sessionId,
    String characterId,
  ) async {
    final character = await characterRepo.getById(characterId);
    return MacroContext(
      charName: character?.name ?? '',
      charDescription: character?.description,
      charScenario: character?.scenario,
      charPersonality: character?.personality,
      charMesExample: character?.mesExample,
      userName: 'User',
      macroName: character?.macroName,
      charId: characterId,
      sessionId: sessionId,
    );
  }

  Future<LedgerRunResult> _runForeground(
    Future<LedgerRunResult> Function() action,
  ) {
    return runWithPostGenForeground(
      onStarted: onForegroundStarted,
      action: action,
      onFinished: onForegroundFinished,
    );
  }

  Future<void> _writeReconciliationDiagnostic({
    required String sessionId,
    required ChatMessage trigger,
    required LedgerReconciliationPlan plan,
    required LedgerRunResult result,
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
          '\u2022 attempts=$attempts \u2022 manual=1'
          '${result.error == null ? '' : ' \u2022 error=${result.error}'}',
      scope: 'ledger_diagnostic',
      provenance:
          'message=${trigger.id}|swipe=${trigger.swipeId}|'
          'agentSwipe=${trigger.agentSwipeId}|range=${plan.startMessageId}..'
          '${plan.endMessage.id}|manual=1',
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
