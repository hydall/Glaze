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
      protocol: LlmProtocol.openai,
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
      useResponsesApi: true,
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
      cacheControlTtl: '1h',
      cacheBreakpointMode: 'stable_prefix',
      sessionIdMode: 'always',
      firstChunkTimeoutMs: 45000,
      extraRequestParameters: [ExtraRequestParameter(key: 'seed', value: '42')],
    );

    final mapped = ApiConfigDraft.fromConfig(config).toConfig(config);

    expect(mapped, config);
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
  });

  test('invalid protocol falls back to OpenAI during load and save', () {
    const config = ApiConfig(id: 'api', protocol: 'invalid');

    final draft = ApiConfigDraft.fromConfig(config);

    expect(draft.values.protocol, LlmProtocol.openai);
    expect(draft.toConfig(config).protocol, LlmProtocol.openai);
  });

  for (final testCase in <({String protocol, String input, String output})>[
    (protocol: LlmProtocol.anthropic, input: 'min', output: 'min'),
    (protocol: LlmProtocol.gemini, input: 'min', output: 'min'),
    (protocol: LlmProtocol.openai, input: 'min', output: 'low'),
    (protocol: LlmProtocol.openrouter, input: 'min', output: 'low'),
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
      in <({String protocol, bool keepsOpenAiOptions, bool keepsPromptCache})>[
        (
          protocol: LlmProtocol.openai,
          keepsOpenAiOptions: true,
          keepsPromptCache: true,
        ),
        (
          protocol: LlmProtocol.openrouter,
          keepsOpenAiOptions: true,
          keepsPromptCache: false,
        ),
        (
          protocol: LlmProtocol.anthropic,
          keepsOpenAiOptions: false,
          keepsPromptCache: true,
        ),
        (
          protocol: LlmProtocol.gemini,
          keepsOpenAiOptions: false,
          keepsPromptCache: false,
        ),
      ]) {
    test('${testCase.protocol} normalizes unsupported editable fields', () {
      final config = ApiConfig(
        id: 'api',
        protocol: testCase.protocol,
        omitTemperature: true,
        omitTopP: true,
        omitReasoning: true,
        omitReasoningEffort: true,
        frequencyPenalty: 1.5,
        presencePenalty: -1.5,
        cacheControlTtl: '1h',
      );
      final draft = ApiConfigDraft.fromConfig(config);

      for (final values in [draft.values, draft.toConfig(config)]) {
        expect(values.omitTemperature, testCase.keepsOpenAiOptions);
        expect(values.omitTopP, testCase.keepsOpenAiOptions);
        expect(values.omitReasoning, testCase.keepsOpenAiOptions);
        expect(values.omitReasoningEffort, testCase.keepsOpenAiOptions);
        expect(
          values.frequencyPenalty,
          testCase.keepsOpenAiOptions ? 1.5 : 0.0,
        );
        expect(
          values.presencePenalty,
          testCase.keepsOpenAiOptions ? -1.5 : 0.0,
        );
        expect(
          values.cacheControlTtl,
          testCase.keepsPromptCache ? '1h' : 'off',
        );
      }
    });
  }
}
