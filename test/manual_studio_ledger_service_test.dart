import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
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
import 'package:glaze_flutter/core/services/generation_notification_service.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/features/chat/services/manual_studio_ledger_service.dart';

void main() {
  late AppDatabase db;
  late ChatRepo chatRepo;
  late StudioPresetRepo presetRepo;
  late TrackerRepo trackerRepo;
  late TrackerSnapshotRepo snapshotRepo;
  late CharacterRepo characterRepo;
  late LedgerReconciliationRunRepo reconciliationRunRepo;
  late LedgerReconciliationCheckpointRepo reconciliationCheckpointRepo;
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
    reconciliationRunRepo = LedgerReconciliationRunRepo(db);
    reconciliationCheckpointRepo = LedgerReconciliationCheckpointRepo(db);
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
      reconciliationRunRepo: reconciliationRunRepo,
      reconciliationCheckpointRepo: reconciliationCheckpointRepo,
      ledger: ledger,
      loadApiConfigs: loadApiConfigs,
      readActiveApiConfig: () => activeApi,
      readPipelineSettings: () => pipeline,
      loadActivePresetId: () async => 'preset',
      acquireForegroundLease: () =>
          GenerationNotificationService.instance.acquirePostGenerationLease(),
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

  List<ChatMessage> reconciliationMessages() => [
    assistant1,
    for (var i = 2; i <= 7; i++) ...[
      ChatMessage(id: 'u$i', role: 'user', content: 'User $i'),
      ChatMessage(id: 'a$i', role: 'assistant', content: 'Assistant $i'),
    ],
  ];

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
    expect(ledger.lastRecentHistory, contains('User: Second'));
    expect(ledger.lastRecentHistory, isNot(contains('Assistant: Two')));
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

  test('disabled Ledger preset blocks manual rerun', () async {
    await putSession('session');
    await presetRepo.put(
      const StudioPreset(id: 'preset', agentEnabled: {'ledger': false}),
    );

    await expectLater(
      createService().rerun(sessionId: 'session', target: assistant2),
      throwsA(
        isA<ManualStudioLedgerConfigException>().having(
          (error) => error.toString(),
          'message',
          contains('disabled in the active preset'),
        ),
      ),
    );
    expect(ledger.runCalls, 0);
  });

  test(
    'reconciliation selects the latest committed visible endpoint',
    () async {
      final messages = reconciliationMessages();
      await putSession('session', messages: messages);
      await commit('session', messages[10], 1);

      final outcome = await createService().reconcile('session');

      expect(outcome.target.id, 'a6');
      expect(ledger.lastPlan?.endMessage.id, 'a6');
      expect(ledger.lastPlan?.messageIds, [
        'a1',
        'u2',
        'a2',
        'u3',
        'a3',
        'u4',
        'a4',
        'u5',
        'a5',
        'u6',
        'a6',
      ]);
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
          'No batch of five committed Ledger ranges is due',
        ),
      ),
    );
    expect(ledger.reconcileCalls, 0);
  });

  test('missing Ledger recovery reruns the exact due endpoint', () async {
    final messages = reconciliationMessages();
    await putSession('session', messages: messages);

    final outcome = await createService().rerunMissingForReconciliation(
      'session',
    );

    expect(outcome.target.id, 'a6');
    expect(ledger.runCalls, 1);
    expect(ledger.lastTarget?.id, 'a6');
  });

  test('disabled Ledger preset blocks manual reconciliation', () async {
    final messages = reconciliationMessages();
    await putSession('session', messages: messages);
    await commit('session', messages[10], 2);
    await presetRepo.put(
      const StudioPreset(id: 'preset', agentEnabled: {'ledger': false}),
    );

    await expectLater(
      createService().reconcile('session'),
      throwsA(isA<ManualStudioLedgerConfigException>()),
    );
    expect(ledger.reconcileCalls, 0);
  });

  test('regeneration targets the exact expected reconciliation head', () async {
    await putSession('session');
    await commit('session', assistant2, 2);
    final run = LedgerReconciliationRun(
      id: 'run',
      sessionId: 'session',
      ordinal: 1,
      anchors: [
        for (final message in const [assistant1, user2, assistant2])
          ReconciliationAnchor(
            messageId: message.id,
            swipeId: message.swipeId,
            agentSwipeId: message.agentSwipeId,
            role: message.role,
            contentHash: computeHash(message.content),
          ),
      ],
      acceptedManifestRefs: const [],
      effectiveCanonStamp: 'stamp',
      effectiveCanonRevision: 1,
      effectiveCanonHash: 'hash',
      canonicalResult: const {'export': <String, dynamic>{}},
      predecessorChainHash: '',
      contractVersion: 1,
      opsApplied: const [],
      createdAt: 1,
    );
    expect(
      await reconciliationRunRepo.appendCandidate(run),
      isA<ReconciliationRunAppended>(),
    );
    final head = (await reconciliationRunRepo.getHead('session'))!;

    final outcome = await createService().regenerateLatest(
      sessionId: 'session',
      expectedRunId: head.id,
    );

    expect(outcome.target.id, 'a2');
    expect(ledger.replaceCalls, 1);
    expect(ledger.lastExpectedRunId, head.id);
  });

  test('diagnostic writes remain isolated to the requested session', () async {
    final messages = reconciliationMessages();
    await putSession('session', messages: messages);
    await putSession('other');
    await commit('session', messages[10], 1);
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
    expect(targetDiagnostic?.value, contains('trigger=a6'));
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
      final messages = reconciliationMessages();
      await putSession('session', messages: messages);
      await commit('session', messages[10], 1);
      final gate = Completer<void>();
      ledger.beforeReconcileComplete = () => gate.future;
      final result = createService().reconcile('session');
      await ledger.reconcileStarted.future;
      final changed = [...messages];
      changed[10] = changed[10].copyWith(content: 'Changed');
      await putSession('session', messages: changed);
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
  int replaceCalls = 0;
  StudioTurnConfigSnapshot? lastTurnConfig;
  AuxApiConfig? lastConfig;
  String? lastRecentHistory;
  MacroContext? lastMacroContext;
  LedgerReconciliationPlan? lastPlan;
  StudioLedgerEngine? lastEngine;
  ChatMessage? lastTarget;
  String? lastExpectedRunId;
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
    lastTarget = target;
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

  @override
  Future<LedgerRunResult> replaceLatestReconciliation({
    required String sessionId,
    required String expectedRunId,
    required StudioTurnConfigSnapshot turnConfig,
    required AuxApiConfig config,
    required MacroContext macroCtx,
    required FutureOr<bool> Function() isStillCurrent,
  }) async {
    replaceCalls++;
    lastExpectedRunId = expectedRunId;
    lastTurnConfig = turnConfig;
    lastConfig = config;
    lastMacroContext = macroCtx;
    if (!await isStillCurrent()) return LedgerRunResult.aborted;
    return const LedgerRunResult(status: 'ok', opsApplied: 4);
  }
}
