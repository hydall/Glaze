import 'package:drift/native.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart' show AuxApiConfig;
import 'package:glaze_flutter/core/llm/prompt/main_model_context_snapshot.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_reconciliation.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/abort_handler.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/services/stages/cleaner_stage.dart';
import 'package:glaze_flutter/features/chat/services/stages/ext_blocks_stage.dart';
import 'package:glaze_flutter/features/chat/services/stages/ledger_stage.dart';
import 'package:glaze_flutter/features/chat/services/stages/stage_context.dart';
import 'package:glaze_flutter/features/chat/state/post_cleaner_state_provider.dart';

class _RecordingExtBlocksStage extends ExtBlocksStage {
  _RecordingExtBlocksStage(super.ctx);

  int calls = 0;
  int? agentSwipeId;

  @override
  Future<void> launchForSwipe({
    required ChatSession session,
    required Character character,
    required int agentSwipeId,
    MainModelContextSnapshot? mainModelContextSnapshot,
  }) async {
    calls++;
    this.agentSwipeId = agentSwipeId;
  }
}

class _RecordingLedgerStage extends LedgerStage {
  _RecordingLedgerStage(super.ctx);

  int calls = 0;
  String? finalAssistantText;
  List<ChatMessage>? messages;
  ChatMessage? targetMessage;
  CancelToken? cancelToken;

  @override
  Future<void> run({
    required String sessionId,
    required List<ChatMessage> messages,
    required int genId,
    required String finalAssistantText,
    required ChatMessage targetMessage,
    bool isManualRerun = false,
    AuxApiConfig? resolvedConfig,
    CancelToken? cancelToken,
    StudioTurnConfigSnapshot? studioTurnConfig,
  }) async {
    calls++;
    this.finalAssistantText = finalAssistantText;
    this.messages = messages;
    this.targetMessage = targetMessage;
    this.cancelToken = cancelToken;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'disabled cleaner still runs ExtBlocks and Ledger without a MemoryBook',
    () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      addTearDown(db.close);

      await container
          .read(pipelineSettingsProvider.notifier)
          .save(
            container
                .read(pipelineSettingsProvider)
                .copyWith(
                  cleaner: container
                      .read(pipelineSettingsProvider)
                      .cleaner
                      .copyWith(postCleanerEnabled: false),
                ),
          );

      const assistant = ChatMessage(
        id: 'a7',
        role: 'assistant',
        content: 'Raw direct response',
        timestamp: 1,
      );
      final messages = <ChatMessage>[
        for (var turn = 1; turn <= 6; turn++) ...[
          ChatMessage(id: 'u$turn', role: 'user', content: 'User turn $turn'),
          ChatMessage(
            id: 'a$turn',
            role: 'assistant',
            content: 'Assistant turn $turn',
          ),
        ],
        const ChatMessage(id: 'u7', role: 'user', content: 'User turn 7'),
        assistant,
      ];
      const session = ChatSession(
        id: 's1',
        characterId: 'c1',
        sessionIndex: 0,
        sessionVars: {},
        messages: [],
      );
      final populatedSession = session.copyWith(messages: messages);
      await container.read(chatRepoProvider).put(populatedSession);

      late AsyncValue<ChatState> state = AsyncData(
        ChatState(session: populatedSession),
      );
      late _RecordingExtBlocksStage extBlocks;
      late _RecordingLedgerStage ledger;
      late AbortHandler abortHandler;
      final stageProvider = Provider<CleanerStage>((ref) {
        abortHandler = AbortHandler(
          ref: ref,
          charId: 'c1',
          setState: (next) => state = next,
          getState: () => state,
          mutateSession: (_, _) async => null,
          loadSession: (_) async => null,
        );
        final ctx = StageContext(
          ref: ref,
          charId: 'c1',
          abortHandler: abortHandler,
          setState: (next) => state = next,
          getState: () => state,
        );
        extBlocks = _RecordingExtBlocksStage(ctx);
        ledger = _RecordingLedgerStage(ctx);
        return CleanerStage(ctx, extBlocks: extBlocks, ledger: ledger);
      });
      final stage = container.read(stageProvider);
      final genId = abortHandler.nextGenId();

      await stage.run(
        sessionId: session.id,
        messages: populatedSession.messages,
        genId: genId,
        character: Character(id: 'c1', name: 'Alice'),
      );

      expect(extBlocks.calls, 1);
      expect(extBlocks.agentSwipeId, -1);
      expect(ledger.calls, 1);
      expect(ledger.finalAssistantText, assistant.content);
      expect(ledger.messages, populatedSession.messages);
      expect(ledger.cancelToken, isNotNull);
      expect(
        container.read(cleanerCancelTokenProvider),
        isNull,
        reason: 'the no-cleaner Ledger token must be cleared after completion',
      );
      final plan = const LedgerReconciliationPlanner().plan(
        messages: ledger.messages!,
        currentAssistantMessageId: ledger.targetMessage!.id,
      );
      expect(plan, isNotNull);
      expect(plan!.endMessage.id, 'a6');
    },
  );
}
