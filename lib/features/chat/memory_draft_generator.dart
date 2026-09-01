import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../../core/llm/transport/chat_transport_request.dart';
import '../../core/llm/macro_engine.dart';
import '../../core/llm/memory_book_api_config_resolver.dart';
import '../../core/llm/memory_draft_response_parser.dart';
import '../../core/llm/memory_draft_transcript_builder.dart';
import '../../core/llm/regex_service.dart';
import '../../core/llm/transport/llm_protocol.dart';
import '../../core/llm/transport/transport_factory.dart';
import '../../core/models/memory_book.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/pipeline_settings.dart';
import '../../core/services/memory_prompt_presets.dart';
import '../../core/state/memory_settings_provider.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/db_provider.dart';
import '../../core/state/global_regex_provider.dart';
import '../../core/state/studio_regex_provider.dart';
import '../settings/api_list_provider.dart';

class MemoryDraftGenerator {
  final T Function<T>(ProviderListenable<T> provider) _read;

  MemoryDraftGenerator(Ref ref) : _read = ref.read;

  MemoryDraftGenerator.widget(WidgetRef ref) : _read = ref.read;

  Future<MemoryDraft> generate({
    required MemoryDraft draft,
    required MemoryBookSettings settings,
    required PipelineSettings pipeline,
    required List<ChatMessage> messages,
    required String charId,
    required String sessionId,
    required Map<String, String> sessionVars,
    CancelToken? cancelToken,
  }) async {
    final character = await _read(characterRepoProvider).getById(charId);
    if (character == null) throw StateError('Character not found: $charId');
    final presets = await _read(presetRepoProvider).getAll();
    final preset = getEffectivePreset(
      presets,
      charId,
      sessionId,
      _read(activePresetIdProvider),
      _read(presetConnectionsProvider),
    );
    final personas = await _read(personaRepoProvider).getAll();
    final persona = getEffectivePersona(
      personas,
      charId,
      sessionId,
      _read(activePersonaIdProvider),
      _read(personaConnectionsProvider),
    );
    final globalRegexes = await _read(globalRegexProvider.future);
    final studioRegexes = await _read(studioRegexProvider.future);
    final globalVars = _read(globalVarsProvider);
    final ledgerRange = MemoryDraftTranscriptBuilder.ledgerRange(messages);
    final historyText = MemoryDraftTranscriptBuilder.build(
      messages: messages,
      scripts: [
        ...?preset?.regexes,
        ...globalRegexes,
        ...studioRegexes.map((entry) => entry.script),
      ],
      context: RegexApplyContext(
        char: character,
        persona: persona,
        sessionVars: sessionVars,
        globalVars: globalVars,
        macroContext: MacroContext(
          charName: character.name,
          charDescription: character.description,
          charScenario: character.scenario,
          charPersonality: character.personality,
          charMesExample: character.mesExample,
          userName: persona?.name ?? 'User',
          personaPrompt: persona?.prompt,
          sessionVars: sessionVars,
          globalVars: globalVars,
          charId: charId,
          sessionId: sessionId,
          macroName: character.macroName,
        ),
      ),
    );
    final customPrompts = MemoryPromptPreset.fromJsonList(
      _read(memoryGlobalSettingsProvider).customPrompts,
    );
    final template = MemoryPromptPresets.resolve(
      settings.promptPreset,
      customPrompts,
    );
    var prompt = template.replaceAll('{{history}}', historyText);
    if (!template.contains('{{history}}')) {
      prompt = '$prompt\n\n$historyText';
    }

    final isCustom = pipeline.memoryBookApi.generationSource == 'custom';
    String endpoint;
    String apiKey;
    String model;
    String protocol;
    var useResponsesApi = false;
    int? receiveTimeoutMs;

    if (isCustom) {
      endpoint = pipeline.memoryBookApi.generationEndpoint;
      apiKey = pipeline.memoryBookApi.generationApiKey;
      model = pipeline.memoryBookApi.generationModel;
      protocol = LlmProtocol.customChatCompletion;
    } else {
      await _read(apiListProvider.future);
      final apiResolver = MemoryBookApiConfigResolver(
        apiConfigs: _read(apiListProvider).value ?? const [],
        activeConfig: _read(activeApiConfigProvider),
      );
      final chatConfig = apiResolver.resolve(pipeline.memoryBookApi);
      if (chatConfig == null) {
        throw Exception('No chat API config available');
      }
      endpoint = chatConfig.endpoint;
      apiKey = chatConfig.apiKey;
      model = pipeline.memoryBookApi.generationModel.isNotEmpty
          ? pipeline.memoryBookApi.generationModel
          : chatConfig.model;
      protocol = chatConfig.protocol;
      useResponsesApi = chatConfig.useResponsesApi;
      receiveTimeoutMs = apiResolver.resolveTimeoutMs(pipeline.memoryBookApi);
    }

    final endpointRequired = protocol != LlmProtocol.openrouter;
    if ((endpointRequired && endpoint.isEmpty) || model.isEmpty) {
      throw Exception('API not configured for memory generation');
    }

    final maxTokens =
        (pipeline.memoryBookApi.generationMaxTokens != null &&
            pipeline.memoryBookApi.generationMaxTokens! > 0)
        ? pipeline.memoryBookApi.generationMaxTokens!
        : 25000;
    final temperature = pipeline.memoryBookApi.generationTemperature ?? 0.4;

    final completer = Completer<String>();
    final transport = pickChatTransport(protocol);

    await transport.stream(
      request: ChatTransportRequest(
        endpoint: endpoint,
        apiKey: apiKey,
        model: model,
        messages: [
          {'role': 'user', 'content': prompt},
        ],
        maxTokens: maxTokens,
        temperature: temperature,
        topP: 1.0,
        // Drafting pins its own temperature and doesn't steer top_p.
        omitTopP: true,
        stream: false,
        useResponsesApi: useResponsesApi,
        receiveTimeoutMs: receiveTimeoutMs,
      ),
      cancelToken: cancelToken,
      onComplete: (text, _, {rawResponseJson}) {
        if (!completer.isCompleted) completer.complete(text);
      },
      onError: (error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );

    final result = await completer.future;
    return MemoryDraftResponseParser.parse(
      draft,
      result,
      ledgerRange: ledgerRange,
    );
  }
}
