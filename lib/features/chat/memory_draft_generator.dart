import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../../core/llm/transport/chat_transport_request.dart';
import '../../core/llm/memory_book_api_config_resolver.dart';
import '../../core/llm/transport/llm_protocol.dart';
import '../../core/llm/transport/transport_factory.dart';
import '../../core/models/memory_book.dart';
import '../../core/models/pipeline_settings.dart';
import '../../core/services/memory_prompt_presets.dart';
import '../../core/state/memory_settings_provider.dart';
import '../settings/api_list_provider.dart';

class MemoryDraftGenerator {
  final T Function<T>(ProviderListenable<T> provider) _read;

  MemoryDraftGenerator(Ref ref) : _read = ref.read;

  MemoryDraftGenerator.widget(WidgetRef ref) : _read = ref.read;

  Future<MemoryDraft> generate({
    required MemoryDraft draft,
    required MemoryBookSettings settings,
    required PipelineSettings pipeline,
    required String historyText,
    CancelToken? cancelToken,
  }) async {
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

    if (isCustom) {
      endpoint = pipeline.memoryBookApi.generationEndpoint;
      apiKey = pipeline.memoryBookApi.generationApiKey;
      model = pipeline.memoryBookApi.generationModel;
      protocol = LlmProtocol.customChatCompletion;
    } else {
      await _read(apiListProvider.future);
      final chatConfig = MemoryBookApiConfigResolver(
        apiConfigs: _read(apiListProvider).value ?? const [],
        activeConfig: _read(activeApiConfigProvider),
      ).resolve(pipeline.memoryBookApi);
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
    return _parseDraftResult(draft, result);
  }

  MemoryDraft _parseDraftResult(MemoryDraft draft, String raw) {
    String content = raw;
    List<String> keys = [];

    final memoryMatch = RegExp(
      r'Memory:\s*(.*?)(?=\nKeys:|$)',
      dotAll: true,
    ).firstMatch(raw);
    final keysMatch = RegExp(r'Keys:\s*(.*?)$', dotAll: true).firstMatch(raw);

    if (memoryMatch != null) {
      content = memoryMatch.group(1)!.trim();
    }
    if (keysMatch != null) {
      keys = keysMatch
          .group(1)!
          .split(',')
          .map((k) => k.trim().toLowerCase())
          .where((k) => k.isNotEmpty)
          .toList();
    }

    return draft.copyWith(
      content: content,
      keys: keys,
      status: 'pending_approval',
      generatedAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      error: null,
    );
  }
}
