import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../../core/llm/aux_llm_client.dart';
import '../../core/llm/transport/llm_capture_context.dart';
import '../../core/llm/macro_engine.dart';
import '../../core/llm/memory_book_api_config_resolver.dart';
import '../../core/llm/memory_draft_response_parser.dart';
import '../../core/llm/memory_draft_transcript_builder.dart';
import '../../core/llm/regex_service.dart';
import '../../core/llm/transport/llm_protocol.dart';
import '../../core/models/api_config.dart';
import '../../core/models/memory_book.dart';
import '../../core/models/memory_source_manifest.dart';
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
  final AuxLlmClient _llm;

  MemoryDraftGenerator(Ref ref, {AuxLlmClient? llm})
    : _read = ref.read,
      _llm = llm ?? const AuxLlmClient();

  MemoryDraftGenerator.widget(WidgetRef ref, {AuxLlmClient? llm})
    : _read = ref.read,
      _llm = llm ?? const AuxLlmClient();

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
    final manifest = MemorySourceManifest.capture(
      sessionId,
      messages,
      draft.messageIds,
    );
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
      ledgerRange != null,
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
    // The connection the slot resolved to, or null on the custom-endpoint
    // branch, which has no saved connection to inherit limits from.
    ApiConfig? slotConfig;

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
      slotConfig = chatConfig;
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

    // Left on "auto", the output cap is the one configured on the connection
    // this draft runs through — not a fixed number written in here. The old
    // flat 25000 was above what several providers accept for output plus
    // reasoning tokens, and no field in the app could bring it back down.
    final maxTokens = MemoryBookApiConfigResolver.maxTokensFor(
      pipeline.memoryBookApi,
      slotConfig,
    );
    final temperature = MemoryBookApiConfigResolver.temperatureFor(
      pipeline.memoryBookApi,
    );

    // Through the shared auxiliary client, not a bare transport call: it picks
    // the same chat transport per protocol, and it brings the retry policy
    // every other auxiliary call in the app already has. A draft used to die
    // on the first 5xx — a provider gateway answering one request with 504
    // left the draft marked `needs_regeneration` and the reader pressing the
    // button again by hand, while the identical hiccup in the cleaner or the
    // summary was retried and never seen.
    final result = await _llm.callOnce(
      config: AuxApiConfig(
        endpoint: endpoint,
        apiKey: apiKey,
        model: model,
        protocol: protocol,
        useResponsesApi: useResponsesApi,
        // The connection's own "no temperature" flag travels with it: drafting
        // pins its own temperature, but a provider that rejects the parameter
        // rejects it here too.
        omitTemperature: slotConfig?.omitTemperature ?? false,
        extraRequestParameters: slotConfig?.extraRequestParameters ?? const [],
      ),
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: temperature,
      // 0 keeps the old behaviour for a connection that names no timeout: the
      // request is not cut off on a deadline of ours.
      timeoutMs: receiveTimeoutMs ?? 0,
      cancelToken: cancelToken,
      // Memory-book drafting goes through a chat transport, so it was always
      // captured — but with no identity, which parked it in the session-less
      // bucket where no per-chat view could reach it.
      captureContext: LlmCaptureContext(
        stage: 'memory.draft',
        sessionId: sessionId,
      ),
    );
    return MemoryDraftResponseParser.parse(
      draft.copyWith(sourceManifest: manifest),
      result,
      ledgerRange: ledgerRange,
    );
  }
}
