import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/agent_runner.dart';
import 'package:glaze_flutter/core/llm/controller_batcher.dart';
import 'package:glaze_flutter/core/llm/generation_context_inputs.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context_preparer.dart';
import 'package:glaze_flutter/core/llm/studio/studio_stream_interceptor.dart';
import 'package:glaze_flutter/core/llm/studio_brief_deduper.dart';
import 'package:glaze_flutter/core/llm/studio_brief_parser.dart';
import 'package:glaze_flutter/core/llm/studio_message_builder.dart';
import 'package:glaze_flutter/core/llm/studio_prompt_text.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/features/chat/services/studio_prompt_preview_service.dart';

void main() {
  final messageBuilder = StudioMessageBuilder(
    const StudioPromptText(),
    StudioBriefDeduper(StudioBriefParser((_) {})),
  );
  const api = ApiConfig(
    id: 'api',
    endpoint: 'https://example.test/v1?key=secret',
    apiKey: 'top-secret',
    model: 'test-model',
  );
  const session = ChatSession(
    id: 'session',
    characterId: 'character',
    sessionIndex: 0,
    messages: [ChatMessage(id: 'user-1', role: 'user', content: 'Hello')],
  );
  final inputs = GenerationContextInputs(
    character: const Character(id: 'character', name: 'Ada'),
    history: session.messages,
    sessionId: 'session',
    apiConfig: api,
  );

  StudioTurnConfigSnapshot snapshot(StudioPreset preset) =>
      StudioTurnConfigSnapshot(
        config: const StudioConfig(sessionId: 'session'),
        preset: preset,
        pipelineSettings: const PipelineSettings(),
        apiConfigs: const [api],
        activeApiConfig: api,
      );

  StudioPromptPreviewService serviceFor(
    StudioPreset preset, {
    void Function()? onCollect,
    void Function()? onResolveAgent,
  }) {
    final turn = snapshot(preset);
    return StudioPromptPreviewService(
      readSession: () => session,
      resolveTurnConfig: (_) async => turn,
      collectContext: (_, _) async {
        onCollect?.call();
        return inputs;
      },
      resolveAgentConfig:
          ({
            required agent,
            required inputs,
            required turnConfig,
            required isFinal,
            required apiConfigId,
          }) async {
            onResolveAgent?.call();
            return ResolvedAgentConfig.fromApiConfig(api);
          },
      groupControllers:
          ({
            required agents,
            required inputs,
            required turnConfig,
            required apiConfigId,
          }) async {
            final individual = agents
                .where((agent) => agent.name.contains('Individual'))
                .toList();
            final batch = agents
                .where((agent) => !agent.name.contains('Individual'))
                .toList();
            return ControllerGrouping(
              batchGroups: batch.isEmpty
                  ? const []
                  : [
                      ControllerBatchGroup(
                        key: 'openai|test-model|pre_generation',
                        resolved: ResolvedAgentConfig.fromApiConfig(api),
                        agents: batch,
                        batchMaxTokens: 8000,
                        batchTemperature: 0.3,
                        batchContextSize: 5,
                      ),
                    ],
              individualAgents: individual,
            );
          },
      controllerBatcher: ControllerBatcher(),
      effectiveRequestConfig:
          ({
            required agent,
            required resolved,
            required isFinal,
            required turnConfig,
          }) => resolved,
      effectiveMaxTokens:
          ({required agent, required isFinal, required turnConfig}) => null,
      effectiveTemperature:
          ({required agent, required isFinal, required turnConfig}) => null,
      messageBuilder: messageBuilder,
      now: () => DateTime.utc(2026, 8, 25),
    );
  }

  test('controller batch preview equals production batch assembly', () async {
    const controller = StudioAgent(
      id: 'controller-agent',
      controllerId: 'agency',
      name: 'Agency Controller',
      order: 0,
    );
    const finalAgent = StudioAgent(
      id: 'final-agent',
      controllerId: 'final',
      name: 'Main Writer',
      order: 1,
    );
    const preset = StudioPreset(
      id: 'preset',
      agents: [controller, finalAgent],
      blocks: [
        StudioPresetBlock(
          id: 'agency-task',
          content: 'Protect user agency.',
          mode: 'direct',
          injectionPoint: 'specificAgent',
          targetAgentId: 'agency',
        ),
        StudioPresetBlock(
          id: 'history',
          type: StudioBlockType.history,
          injectionPoint: 'pregen',
        ),
      ],
    );
    var contextCollections = 0;

    final catalog = await serviceFor(
      preset,
      onCollect: () => contextCollections++,
    ).load();
    final preview = catalog.entries.singleWhere(
      (entry) => entry.stage == StudioPromptPreviewStage.controllerBatch,
    );
    final visibleIds = StudioStreamInterceptor.computeStudioVisibleMessageIds(
      inputs.history,
      snapshot(preset).pipelineSettings.studioAgent.studioControllerContextSize,
    );
    final context = const StudioContextPreparer().prepare(
      inputs: inputs,
      visibleMessageIds: visibleIds,
      ledgerPromptInjectionPolicy: snapshot(preset).ledgerPromptInjectionPolicy,
      consumerPath: 'studio-tracker',
      studioPreset: preset,
    );
    final group = ControllerBatchGroup(
      key: 'openai|test-model|pre_generation',
      resolved: ResolvedAgentConfig.fromApiConfig(api),
      agents: const [controller],
      batchMaxTokens: 8000,
      batchTemperature: 0.3,
      batchContextSize: 5,
    );
    final batcher = ControllerBatcher();
    final shared = messageBuilder.buildSharedBatchMessages(
      context: context,
      batchContextSize: group.batchContextSize,
    );
    final system = batcher.buildBatchSystemPrompt(
      group: group,
      sharedMessages: shared,
      perAgentTaskText: {
        controller.id: messageBuilder.buildPerAgentTaskText(
          agent: controller,
          config: const StudioConfig(sessionId: 'session'),
          studioPreset: preset,
          context: context,
        ),
      },
      roleText: messageBuilder.batchRoleText(
        const StudioConfig(sessionId: 'session'),
        preset,
        context,
      ),
    );
    final expected = [
      {'role': 'system', 'content': system},
      {
        'role': 'user',
        'content':
            'Produce the required <result> blocks now, one per agent_task '
            'listed above, in order.',
      },
    ];

    expect(contextCollections, 1);
    expect(preview.messages, expected);
    expect(preview.rawRequest?['protocolEndpoint'], 'https://example.test/v1');
    expect(preview.rawRequest?['maxTokens'], 8000);
    expect(preview.rawRequest?['temperature'], 0.3);
    expect(preview.formattedRawRequest, isNot(contains('top-secret')));
  });

  test(
    'final writer is unavailable when controller outputs are required',
    () async {
      const preset = StudioPreset(
        id: 'preset',
        agents: [
          StudioAgent(id: 'controller', controllerId: 'agency', order: 0),
          StudioAgent(id: 'final', controllerId: 'final', order: 1),
        ],
      );

      final catalog = await serviceFor(preset).load();
      final finalEntry = catalog.entries.singleWhere(
        (entry) => entry.stage == StudioPromptPreviewStage.finalWriter,
      );

      expect(finalEntry.isAvailable, isFalse);
      expect(
        finalEntry.unavailableReason,
        StudioPromptPreviewUnavailableReason.controllerOutputsRequired,
      );
    },
  );

  test(
    'final writer is available when no pre-generation output is required',
    () async {
      const preset = StudioPreset(
        id: 'preset',
        agents: [
          StudioAgent(id: 'final', controllerId: 'final', name: 'Writer'),
        ],
        blocks: [
          StudioPresetBlock(
            id: 'final-instruction',
            content: 'Write the reply.',
            mode: 'direct',
            injectionPoint: 'final',
          ),
        ],
      );

      final catalog = await serviceFor(preset).load();
      final finalEntry = catalog.entries.singleWhere(
        (entry) => entry.stage == StudioPromptPreviewStage.finalWriter,
      );

      expect(finalEntry.isAvailable, isTrue);
      expect(finalEntry.messages, isNotEmpty);
      expect(
        finalEntry.messages.first['content'],
        contains('Write the reply.'),
      );
    },
  );

  test(
    'future stages are typed and preview performs no capture dispatch',
    () async {
      const preset = StudioPreset(
        id: 'preset',
        agents: [StudioAgent(id: 'final', controllerId: 'final')],
      );
      final sink = _CaptureSink();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final oldSink = LlmRequestCapture.sink;
      LlmRequestCapture.sink = sink;
      addTearDown(() => LlmRequestCapture.sink = oldSink);
      addTearDown(db.close);
      var configResolutions = 0;

      final catalog = await serviceFor(
        preset,
        onResolveAgent: () => configResolutions++,
      ).load();

      expect(configResolutions, 1);
      expect(sink.events, isEmpty);
      expect(
        (await db
                .customSelect(
                  'SELECT COUNT(*) AS total FROM llm_request_capture_rows',
                )
                .getSingle())
            .read<int>('total'),
        0,
      );
      expect(
        (await db
                .customSelect(
                  'SELECT COUNT(*) AS total FROM card_evolution_claims',
                )
                .getSingle())
            .read<int>('total'),
        0,
      );
      expect(
        catalog.entries
            .singleWhere((entry) => entry.id == 'ledger.turn')
            .unavailableReason,
        StudioPromptPreviewUnavailableReason.finalResponseRequired,
      );
      expect(
        catalog.entries
            .singleWhere((entry) => entry.id == 'card.collector')
            .unavailableReason,
        StudioPromptPreviewUnavailableReason.claimSafeSelectionRequired,
      );
      expect(
        catalog.entries
            .singleWhere((entry) => entry.id == 'card.writer_repair')
            .unavailableReason,
        StudioPromptPreviewUnavailableReason.malformedOutputRequired,
      );
    },
  );

  test(
    'preview composition cannot reach persistence, claims, or transport',
    () {
      final source = File(
        'lib/features/chat/services/studio_prompt_preview_service.dart',
      ).readAsStringSync();

      expect(source, isNot(contains('promptCaptureViewsProvider')));
      expect(source, isNot(contains('LlmRequestCapture.dispatch')));
      expect(source, isNot(contains('pendingValidPairs')));
      expect(source, isNot(contains('.claim(')));
      expect(source, isNot(contains('.stream(')));
    },
  );

  test('stale session snapshot is rejected after context collection', () async {
    const preset = StudioPreset(
      id: 'preset',
      agents: [StudioAgent(id: 'final', controllerId: 'final')],
    );
    final turn = snapshot(preset);
    var currentSession = session;
    final service = StudioPromptPreviewService(
      readSession: () => currentSession,
      resolveTurnConfig: (_) async => turn,
      collectContext: (_, _) async {
        currentSession = session.copyWith(
          messages: const [
            ChatMessage(id: 'user-2', role: 'user', content: 'Changed'),
          ],
        );
        return inputs;
      },
      resolveAgentConfig:
          ({
            required agent,
            required inputs,
            required turnConfig,
            required isFinal,
            required apiConfigId,
          }) async => ResolvedAgentConfig.fromApiConfig(api),
      groupControllers:
          ({
            required agents,
            required inputs,
            required turnConfig,
            required apiConfigId,
          }) async =>
              const ControllerGrouping(batchGroups: [], individualAgents: []),
      controllerBatcher: ControllerBatcher(),
      effectiveRequestConfig:
          ({
            required agent,
            required resolved,
            required isFinal,
            required turnConfig,
          }) => resolved,
      effectiveMaxTokens:
          ({required agent, required isFinal, required turnConfig}) => null,
      effectiveTemperature:
          ({required agent, required isFinal, required turnConfig}) => null,
      messageBuilder: messageBuilder,
    );

    await expectLater(service.load(), throwsStateError);
  });
}

final class _CaptureSink implements LlmRequestCaptureSink {
  final List<LlmRequestCaptureEvent> events = [];

  @override
  void record(LlmRequestCaptureEvent event) => events.add(event);
}
