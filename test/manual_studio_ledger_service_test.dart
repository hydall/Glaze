import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_reconciliation.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_service.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/cleaner_settings.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/features/chat/services/manual_studio_ledger_service.dart';

void main() {
  late AppDatabase db;
  late ChatRepo chatRepo;
  late StudioPresetRepo presetRepo;
  late TrackerRepo trackerRepo;
  late TrackerSnapshotRepo snapshotRepo;
  late CharacterRepo characterRepo;
  late _FakeLedgerExecutor ledger;
  late PipelineSettings pipeline;
  late ApiConfig activeApi;
  late Future<List<ApiConfig>> Function() loadApiConfigs;

  const assistant1 = ChatMessage(id: 'a1', role: 'assistant', content: 'One');
  const user2 = ChatMessage(id: 'u2', role: 'user', content: 'Second');
  const assistant2 = ChatMessage(id: 'a2', role: 'assistant', content: 'Two');

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chatRepo = ChatRepo(db);
    presetRepo = StudioPresetRepo(db);
    trackerRepo = TrackerRepo(db);
    snapshotRepo = TrackerSnapshotRepo(db);
    characterRepo = CharacterRepo(db);
    ledger = _FakeLedgerExecutor();
    pipeline = const PipelineSettings(
      cleaner: CleanerSettings(postCleanerModel: 'snapshot-model'),
    );
    activeApi = const ApiConfig(
      id: 'active',
      endpoint: 'https://active.example',
      model: 'active-model',
    );
    loadApiConfigs = () async => const [
      ApiConfig(
        id: 'cleaner',
        endpoint: 'https://cleaner.example',
        model: 'cleaner-model',
      ),
    ];
    await characterRepo.put(const Character(id: 'char', name: 'Character'));
    await presetRepo.put(
      const StudioPreset(
        id: 'preset',
        cleanerApiConfigId: 'cleaner',
        blocks: [StudioPresetBlock(id: 'ledger', section: 'ledger')],
      ),
    );
  });

  tearDown(() => db.close());

  ManualStudioLedgerService createService() {
    return ManualStudioLedgerService(
      chatRepo: chatRepo,
      snapshotRepo: snapshotRepo,
      trackerRepo: trackerRepo,
      presetRepo: presetRepo,
      characterRepo: characterRepo,
      ledger: ledger,
      loadApiConfigs: loadApiConfigs,
      readActiveApiConfig: () => activeApi,
      readPipelineSettings: () => pipeline,
      loadActivePresetId: () async => 'preset',
      onForegroundStarted: () async {},
      onForegroundFinished: () async {},
    );
  }

  Future<void> putSession(
    String id, {
    List<ChatMessage> messages = const [assistant1, user2, assistant2],
  }) {
    return chatRepo.put(
      ChatSession(
        id: id,
        characterId: 'char',
        sessionIndex: 0,
        messages: messages,
      ),
    );
  }

  Future<void> commit(String sessionId, ChatMessage message, int createdAt) {
    return snapshotRepo.upsert(
      TrackerSnapshot(
        sessionId: sessionId,
        messageId: message.id,
        swipeId: message.swipeId,
        agentSwipeId: message.agentSwipeId,
        trackers: const [],
        committed: true,
        createdAt: createdAt,
      ),
    );
  }

  test('rerun succeeds with one consistent fresh config snapshot', () async {
    await putSession('session');
    final apiLoad = Completer<List<ApiConfig>>();
    loadApiConfigs = () => apiLoad.future;
    final future = createService().rerun(
      sessionId: 'session',
      target: assistant2,
    );

    pipeline = const PipelineSettings(
      cleaner: CleanerSettings(postCleanerModel: 'changed-model'),
    );
    activeApi = const ApiConfig(id: 'changed', model: 'changed-active');
    apiLoad.complete(const [
      ApiConfig(
        id: 'cleaner',
        endpoint: 'https://snapshot.example',
        model: 'api-model',
      ),
    ]);
    final outcome = await future;

    expect(outcome.result.status, 'ok');
    expect(ledger.runCalls, 1);
    expect(ledger.lastTurnConfig?.pipelineSettings, isNot(same(pipeline)));
    expect(ledger.lastConfig?.endpoint, 'https://snapshot.example');
    expect(ledger.lastConfig?.model, 'snapshot-model');
    expect(ledger.lastRecentHistory, contains('Assistant: Two'));
    expect(ledger.lastMacroContext?.charName, 'Character');
    final diagnostic = await trackerRepo.get(
      'session',
      '_ledger_diag:studio_ledger',
    );
    expect(diagnostic?.value, 'turn=a2 \u2022 manual rerun, ok (ops=2)');
  });

  test('rerun always uses the current Ledger extractor', () async {
    await putSession('session');
    await presetRepo.put(
      const StudioPreset(
        id: 'preset',
        cleanerApiConfigId: 'cleaner',
        runtime: StudioRuntimeSettings(
          ledgerEngine: StudioLedgerEngine.legacyTurnOnly,
        ),
      ),
    );

    await createService().rerun(sessionId: 'session', target: assistant2);

    expect(ledger.lastEngine, StudioLedgerEngine.currentReconciled);
  });

  test(
    'reconciliation selects the latest committed visible endpoint',
    () async {
      await putSession('session');
      await commit('session', assistant1, 1);
      await commit('session', assistant2, 2);

      final outcome = await createService().reconcile('session');

      expect(outcome.target.id, 'a2');
      expect(ledger.lastPlan?.endMessage.id, 'a2');
      expect(ledger.reconcileCalls, 1);
    },
  );

  test('reconciliation reports when no committed endpoint exists', () async {
    await putSession('session');

    await expectLater(
      createService().reconcile('session'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'No committed Ledger snapshot to reconcile',
        ),
      ),
    );
    expect(ledger.reconcileCalls, 0);
  });

  test('diagnostic writes remain isolated to the requested session', () async {
    await putSession('session');
    await putSession('other');
    await commit('session', assistant2, 1);
    await trackerRepo.upsertValue(
      'other',
      '_ledger_diag:studio_ledger_reconciliation',
      'other diagnostic',
    );

    await createService().reconcile('session');

    final targetDiagnostic = await trackerRepo.get(
      'session',
      '_ledger_diag:studio_ledger_reconciliation',
    );
    final otherDiagnostic = await trackerRepo.get(
      'other',
      '_ledger_diag:studio_ledger_reconciliation',
    );
    expect(targetDiagnostic?.value, contains('trigger=a2'));
    expect(targetDiagnostic?.value, contains('status=ok'));
    expect(targetDiagnostic?.value, contains('manual=1'));
    expect(otherDiagnostic?.value, 'other diagnostic');
  });

  test(
    'rerun writes nothing when its target changes while execution awaits',
    () async {
      await putSession('session');
      final gate = Completer<void>();
      ledger.beforeRunComplete = () => gate.future;
      final result = createService().rerun(
        sessionId: 'session',
        target: assistant2,
      );
      await ledger.runStarted.future;
      await putSession(
        'session',
        messages: const [
          assistant1,
          user2,
          ChatMessage(id: 'a2', role: 'assistant', content: 'Changed'),
        ],
      );
      gate.complete();

      expect((await result).result.status, 'aborted');
      expect(
        await trackerRepo.get('session', '_ledger_diag:studio_ledger'),
        isNull,
      );
    },
  );

  test(
    'reconciliation writes nothing when its endpoint changes while awaiting',
    () async {
      await putSession('session');
      await commit('session', assistant1, 1);
      await commit('session', assistant2, 2);
      final gate = Completer<void>();
      ledger.beforeReconcileComplete = () => gate.future;
      final result = createService().reconcile('session');
      await ledger.reconcileStarted.future;
      await putSession(
        'session',
        messages: const [
          assistant1,
          user2,
          ChatMessage(id: 'a2', role: 'assistant', content: 'Changed'),
        ],
      );
      gate.complete();

      expect((await result).result.status, 'aborted');
      expect(
        await trackerRepo.get(
          'session',
          '_ledger_diag:studio_ledger_reconciliation',
        ),
        isNull,
      );
    },
  );
}

class _FakeLedgerExecutor implements StudioLedgerExecutor {
  int runCalls = 0;
  int reconcileCalls = 0;
  StudioTurnConfigSnapshot? lastTurnConfig;
  AuxApiConfig? lastConfig;
  String? lastRecentHistory;
  MacroContext? lastMacroContext;
  LedgerReconciliationPlan? lastPlan;
  StudioLedgerEngine? lastEngine;
  Future<void> Function()? beforeRunComplete;
  Future<void> Function()? beforeReconcileComplete;
  final runStarted = Completer<void>();
  final reconcileStarted = Completer<void>();

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
  }) async {
    runCalls++;
    lastTurnConfig = turnConfig;
    lastConfig = config;
    lastRecentHistory = recentHistoryText;
    lastMacroContext = macroCtx;
    lastEngine = engine;
    if (!runStarted.isCompleted) runStarted.complete();
    await beforeRunComplete?.call();
    if (!await isStillCurrent()) return LedgerRunResult.aborted;
    return const LedgerRunResult(status: 'ok', opsApplied: 2);
  }

  @override
  Future<LedgerRunResult> reconcile({
    required String sessionId,
    required StudioTurnConfigSnapshot turnConfig,
    required AuxApiConfig config,
    required LedgerReconciliationPlan plan,
    required MacroContext macroCtx,
    required FutureOr<bool> Function() isStillCurrent,
  }) async {
    reconcileCalls++;
    lastTurnConfig = turnConfig;
    lastConfig = config;
    lastMacroContext = macroCtx;
    lastPlan = plan;
    if (!reconcileStarted.isCompleted) reconcileStarted.complete();
    await beforeReconcileComplete?.call();
    if (!await isStillCurrent()) return LedgerRunResult.aborted;
    return const LedgerRunResult(
      status: 'ok',
      opsApplied: 3,
      model: 'snapshot-model',
    );
  }
}
