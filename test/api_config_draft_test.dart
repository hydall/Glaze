import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';
import 'package:glaze_flutter/features/settings/api_config_draft.dart';

void main() {
  test('maps editable fields through a draft without losing config fields', () {
    const config = ApiConfig(
      id: 'api',
      name: 'Name',
      providerId: 'provider',
      // OpenRouter supports every sampling field, so this round-trip exercises
      // them all. Official OpenAI would legitimately clear top_k — that is
      // covered by its own case below.
      protocol: LlmProtocol.openrouter,
      endpoint: 'https://example.test',
      apiKey: 'secret',
      model: 'model',
      mode: 'completion',
      maxTokens: 123,
      contextSize: 456,
      temperature: 0.4,
      topP: 0.8,
      topK: 12,
      frequencyPenalty: 0.2,
      presencePenalty: -0.3,
      stream: false,
      reasoningEffort: 'high',
      requestReasoning: true,
      showNativeReasoning: false,
      reasoningHistoryCount: -1,
      reasoningTagStart: '<think>',
      reasoningTagEnd: '</think>',
      omitTemperature: true,
      omitTopP: true,
      omitTopK: true,
      omitFrequencyPenalty: true,
      omitPresencePenalty: true,
      omitReasoningEffort: true,
      embeddingUseSame: false,
      embeddingEnabled: true,
      embeddingEndpoint: 'https://embeddings.test',
      embeddingApiKey: 'embedding-secret',
      embeddingModel: 'embedding-model',
      embeddingMaxChunkTokens: 789,
      embeddingRequestsPerMinute: 25,
      cacheControlTtl: 'off',
      cacheBreakpointMode: 'stable_prefix',
      sessionIdMode: 'always',
      firstChunkTimeoutMs: 45000,
      useSystemInstruction: false,
      extraRequestParameters: [ExtraRequestParameter(key: 'seed', value: '42')],
    );

    final mapped = ApiConfigDraft.fromConfig(config).toConfig(config);

    expect(mapped, config);
  });

  test('each half of the editor is written to its own preset', () {
    // The API screen can sit on two presets at once — the LLM tab on one, the
    // Embeddings tab on another — so neither half may leak onto the other's
    // preset when the editor saves.
    const llm = ApiConfig(
      id: 'llm',
      name: 'LLM',
      endpoint: 'https://llm.test',
      apiKey: 'llm-key',
      model: 'chat-model',
      embeddingEnabled: false,
      embeddingUseSame: true,
      embeddingEndpoint: 'https://old-embeddings.test',
      embeddingModel: 'old-embedding-model',
    );
    const embedding = ApiConfig(
      id: 'embedding',
      name: 'Embeddings',
      endpoint: 'https://embedding-preset.test',
      apiKey: 'embedding-preset-key',
      model: 'embedding-preset-chat-model',
    );
    final source = ApiConfigDraft.fromConfig(llm);
    final draft = ApiConfigDraft(
      values: source.values.copyWith(
        embeddingEnabled: true,
        embeddingUseSame: false,
      ),
      name: 'Edited LLM',
      endpoint: 'https://edited-llm.test',
      apiKey: 'edited-llm-key',
      model: 'edited-chat-model',
      maxTokens: source.maxTokens,
      contextSize: source.contextSize,
      firstChunkTimeoutSeconds: source.firstChunkTimeoutSeconds,
      reasoningHistoryCount: source.reasoningHistoryCount,
      embeddingEndpoint: 'https://edited-embeddings.test',
      embeddingApiKey: 'edited-embedding-key',
      embeddingModel: 'edited-embedding-model',
      embeddingMaxChunkTokens: '256',
      embeddingRequestsPerMinute: '40',
    );

    final savedLlm = draft.applyLlmTo(llm);
    final savedEmbedding = draft.applyEmbeddingTo(embedding);

    // The LLM preset takes the connection fields and keeps its own embedding
    // settings untouched.
    expect(savedLlm.name, 'Edited LLM');
    expect(savedLlm.endpoint, 'https://edited-llm.test');
    expect(savedLlm.embeddingEnabled, isFalse);
    expect(savedLlm.embeddingUseSame, isTrue);
    expect(savedLlm.embeddingEndpoint, 'https://old-embeddings.test');
    expect(savedLlm.embeddingModel, 'old-embedding-model');
    // The embedding preset takes the embedding fields and keeps its own name
    // and chat connection.
    expect(savedEmbedding.name, 'Embeddings');
    expect(savedEmbedding.endpoint, 'https://embedding-preset.test');
    expect(savedEmbedding.apiKey, 'embedding-preset-key');
    expect(savedEmbedding.model, 'embedding-preset-chat-model');
    expect(savedEmbedding.embeddingEnabled, isTrue);
    expect(savedEmbedding.embeddingUseSame, isFalse);
    expect(savedEmbedding.embeddingEndpoint, 'https://edited-embeddings.test');
    expect(savedEmbedding.embeddingApiKey, 'edited-embedding-key');
    expect(savedEmbedding.embeddingModel, 'edited-embedding-model');
    expect(savedEmbedding.embeddingMaxChunkTokens, 256);
    expect(savedEmbedding.embeddingRequestsPerMinute, 40);
  });

  test('trims text and preserves current numeric values on invalid input', () {
    const config = ApiConfig(
      id: 'api',
      maxTokens: 123,
      contextSize: 456,
      embeddingMaxChunkTokens: 789,
    );
    final source = ApiConfigDraft.fromConfig(config);
    final draft = ApiConfigDraft(
      values: source.values,
      name: '  Name  ',
      endpoint: '  endpoint  ',
      apiKey: '  key  ',
      model: '  model  ',
      maxTokens: 'invalid',
      contextSize: 'invalid',
      firstChunkTimeoutSeconds: 'invalid',
      reasoningHistoryCount: '-2',
      embeddingEndpoint: '  embedding endpoint  ',
      embeddingApiKey: '  embedding key  ',
      embeddingModel: '  embedding model  ',
      embeddingMaxChunkTokens: 'invalid',
      embeddingRequestsPerMinute: 'invalid',
    );

    final mapped = draft.toConfig(config);

    expect(mapped.name, 'Name');
    expect(mapped.endpoint, 'endpoint');
    expect(mapped.apiKey, 'key');
    expect(mapped.model, 'model');
    expect(mapped.maxTokens, 123);
    expect(mapped.contextSize, 456);
    expect(mapped.firstChunkTimeoutMs, 60000);
    expect(mapped.reasoningHistoryCount, 0);
    expect(mapped.embeddingEndpoint, 'embedding endpoint');
    expect(mapped.embeddingApiKey, 'embedding key');
    expect(mapped.embeddingModel, 'embedding model');
    expect(mapped.embeddingMaxChunkTokens, 789);
    expect(mapped.embeddingRequestsPerMinute, 50);
  });

  test('the official Responses protocol derives the opt-in flag', () {
    const config = ApiConfig(id: 'api', protocol: LlmProtocol.openaiResponses);

    final draft = ApiConfigDraft.fromConfig(config);

    expect(draft.values.useResponsesApi, isTrue);
    expect(draft.toConfig(config).useResponsesApi, isTrue);
  });

  test('official Chat Completions clears the Responses opt-in flag', () {
    const config = ApiConfig(
      id: 'api',
      protocol: LlmProtocol.openai,
      useResponsesApi: true,
    );

    final draft = ApiConfigDraft.fromConfig(config);

    expect(draft.values.useResponsesApi, isFalse);
    expect(draft.toConfig(config).useResponsesApi, isFalse);
  });

  test('Custom Chat Completion preserves the Responses endpoint toggle', () {
    const config = ApiConfig(
      id: 'api',
      protocol: LlmProtocol.customChatCompletion,
      useResponsesApi: true,
    );

    final draft = ApiConfigDraft.fromConfig(config);

    expect(draft.values.useResponsesApi, isTrue);
    expect(draft.toConfig(config).useResponsesApi, isTrue);
  });

  test('a legacy JSON preset with the opt-in maps onto the new protocol', () {
    final config = ApiConfig.fromJson(const {
      'id': 'api',
      'protocol': 'openai',
      'useResponsesApi': true,
    });

    expect(config.protocol, LlmProtocol.customChatCompletion);
    expect(config.useResponsesApi, isTrue);
  });

  test('legacy custom JSON maps onto Custom Chat Completion', () {
    final missing = ApiConfig.fromJson(const {'id': 'missing'});
    final explicit = ApiConfig.fromJson(const {
      'id': 'explicit',
      'providerId': 'openai_compatible',
      'protocol': 'openai',
    });
    final official = ApiConfig.fromJson(const {
      'id': 'official',
      'providerId': 'openai',
      'protocol': 'openai',
    });

    expect(missing.protocol, LlmProtocol.customChatCompletion);
    expect(explicit.protocol, LlmProtocol.customChatCompletion);
    expect(official.protocol, LlmProtocol.openai);
  });

  test('OpenRouter keeps a live cache TTL so OR markers can be placed', () {
    const config = ApiConfig(
      id: 'api',
      protocol: LlmProtocol.openrouter,
      cacheControlTtl: '1h',
      cacheBreakpointMode: 'stable_prefix',
    );

    final draft = ApiConfigDraft.fromConfig(config);

    expect(draft.values.cacheControlTtl, '1h');
    expect(draft.toConfig(config).cacheControlTtl, '1h');
    expect(draft.toConfig(config).cacheBreakpointMode, 'stable_prefix');
  });

  for (final testCase
      in <
        ({
          String name,
          String protocol,
          String endpoint,
          String stored,
          String resolved,
        })
      >[
        (
          name: 'OpenRouter protocol keeps the legacy default on',
          protocol: LlmProtocol.openrouter,
          endpoint: '',
          stored: 'openrouter',
          resolved: 'always',
        ),
        (
          name: 'a custom preset pointed at OpenRouter keeps it on',
          protocol: LlmProtocol.customChatCompletion,
          endpoint: 'https://openrouter.ai/api/v1',
          stored: 'openrouter',
          resolved: 'always',
        ),
        (
          name: 'a plain OpenAI preset resolves the legacy default to off',
          protocol: LlmProtocol.openai,
          endpoint: 'https://api.openai.com/v1',
          stored: 'openrouter',
          resolved: 'off',
        ),
        (
          name: 'an explicit off on OpenRouter is not overridden',
          protocol: LlmProtocol.openrouter,
          endpoint: '',
          stored: 'off',
          resolved: 'off',
        ),
      ]) {
    test('session_id: ${testCase.name}', () {
      final config = ApiConfig(
        id: 'api',
        protocol: testCase.protocol,
        endpoint: testCase.endpoint,
        sessionIdMode: testCase.stored,
      );

      final draft = ApiConfigDraft.fromConfig(config);

      expect(draft.values.sessionIdMode, testCase.resolved);
      expect(draft.toConfig(config).sessionIdMode, testCase.resolved);
    });
  }

  test(
    'invalid protocol falls back to Custom Chat Completion during load and save',
    () {
      const config = ApiConfig(id: 'api', protocol: 'invalid');

      final draft = ApiConfigDraft.fromConfig(config);

      expect(draft.values.protocol, LlmProtocol.customChatCompletion);
      expect(draft.toConfig(config).protocol, LlmProtocol.customChatCompletion);
    },
  );

  test('prompt post-processing survives only on custom endpoints', () {
    // The picker is offered for custom endpoints alone — every first-party
    // protocol normalizes message shape in its own converter. A mode left
    // behind by a protocol switch must not keep reshaping prompts unseen.
    for (final protocol in LlmProtocol.all) {
      final config = ApiConfig(
        id: 'api',
        protocol: protocol,
        promptPostProcessing: 'merge_tools',
      );
      final draft = ApiConfigDraft.fromConfig(config);
      final expected = protocol == LlmProtocol.customChatCompletion
          ? 'merge_tools'
          : 'none';

      for (final values in [draft.values, draft.toConfig(config)]) {
        expect(values.promptPostProcessing, expected, reason: protocol);
      }
    }
  });

  test('an unknown post-processing mode degrades to none', () {
    const config = ApiConfig(
      id: 'api',
      protocol: LlmProtocol.customChatCompletion,
      promptPostProcessing: 'nonsense',
    );
    expect(
      ApiConfigDraft.fromConfig(config).values.promptPostProcessing,
      'none',
    );
  });

  for (final testCase in <({String protocol, String input, String output})>[
    // Every protocol keeps all six steps now — the collapse to what the API
    // accepts happens at send time (converters/reasoning_effort.dart), not by
    // rewriting the stored preset.
    (protocol: LlmProtocol.anthropic, input: 'min', output: 'min'),
    (protocol: LlmProtocol.gemini, input: 'min', output: 'min'),
    (protocol: LlmProtocol.openai, input: 'min', output: 'min'),
    (protocol: LlmProtocol.customChatCompletion, input: 'max', output: 'max'),
    (protocol: LlmProtocol.openaiResponses, input: 'min', output: 'min'),
    (protocol: LlmProtocol.openrouter, input: 'min', output: 'min'),
    (protocol: LlmProtocol.openai, input: 'max', output: 'max'),
    (protocol: LlmProtocol.openai, input: 'invalid', output: 'medium'),
  ]) {
    test(
      '${testCase.protocol} normalizes ${testCase.input} reasoning effort',
      () {
        final draft = ApiConfigDraft.fromConfig(
          ApiConfig(
            id: 'api',
            protocol: testCase.protocol,
            reasoningEffort: testCase.input,
          ),
        );

        expect(draft.values.reasoningEffort, testCase.output);
        expect(draft.toConfig(draft.values).reasoningEffort, testCase.output);
      },
    );
  }

  for (final testCase
      in <({String protocol, bool keepsPenalties, bool keepsPromptCache})>[
        (
          protocol: LlmProtocol.openai,
          keepsPenalties: true,
          keepsPromptCache: false,
        ),
        (
          protocol: LlmProtocol.customChatCompletion,
          keepsPenalties: true,
          keepsPromptCache: true,
        ),
        (
          protocol: LlmProtocol.openaiResponses,
          keepsPenalties: false,
          keepsPromptCache: false,
        ),
        (
          protocol: LlmProtocol.openrouter,
          keepsPenalties: true,
          keepsPromptCache: true,
        ),
        (
          protocol: LlmProtocol.anthropic,
          keepsPenalties: false,
          keepsPromptCache: true,
        ),
        (
          protocol: LlmProtocol.gemini,
          keepsPenalties: false,
          keepsPromptCache: false,
        ),
      ]) {
    test('${testCase.protocol} normalizes unsupported editable fields', () {
      final config = ApiConfig(
        id: 'api',
        protocol: testCase.protocol,
        frequencyPenalty: 1.5,
        presencePenalty: -1.5,
        cacheControlTtl: '1h',
      );
      final draft = ApiConfigDraft.fromConfig(config);

      for (final values in [draft.values, draft.toConfig(config)]) {
        expect(values.frequencyPenalty, testCase.keepsPenalties ? 1.5 : 0.0);
        expect(values.presencePenalty, testCase.keepsPenalties ? -1.5 : 0.0);
        expect(
          values.cacheControlTtl,
          testCase.keepsPromptCache ? '1h' : 'off',
        );
      }
    });

    // Official OpenAI and the Responses API have no top_k and hide the
    // slider, so a value carried over from another protocol must be cleared
    // rather than kept and sent from a control the user cannot see.
    test('${testCase.protocol} clears top_k when the protocol has none', () {
      final draft = ApiConfigDraft.fromConfig(
        ApiConfig(id: 'api', protocol: testCase.protocol, topK: 40),
      );
      final supportsTopK =
          testCase.protocol == LlmProtocol.customChatCompletion ||
          testCase.protocol == LlmProtocol.openrouter ||
          testCase.protocol == LlmProtocol.anthropic ||
          testCase.protocol == LlmProtocol.gemini;

      for (final values in [draft.values, draft.toConfig(draft.values)]) {
        expect(values.topK, supportsTopK ? 40 : 0);
      }
    });

    // Sampling and reasoning switches used to be cleared for anything that
    // wasn't OpenAI-shaped, even though the Anthropic and Gemini transports
    // have always honored them. They must survive on every protocol.
    test('${testCase.protocol} keeps the omit switches', () {
      final config = ApiConfig(
        id: 'api',
        protocol: testCase.protocol,
        omitTemperature: true,
        omitTopP: true,
        omitTopK: true,
        omitReasoning: true,
        omitReasoningEffort: true,
      );
      final draft = ApiConfigDraft.fromConfig(config);

      for (final values in [draft.values, draft.toConfig(config)]) {
        expect(values.omitTemperature, isTrue);
        expect(values.omitTopP, isTrue);
        expect(values.omitTopK, isTrue);
        expect(values.omitReasoning, isTrue);
        expect(values.omitReasoningEffort, isTrue);
      }
    });
  }
}
