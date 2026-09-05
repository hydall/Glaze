import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../models/api_config.dart';
import '../../application/sync_repo_interfaces.dart';
import '../../models/extra_request_parameter.dart';
import '../../llm/history_trim.dart';
import '../../llm/transport/endpoint_normalizer.dart';

class ApiConfigRepo implements SyncApiConfigStore {
  final AppDatabase _db;
  ApiConfigRepo(this._db);

  @override
  Future<List<ApiConfig>> getAll() async {
    final rows = await _db.select(_db.apiConfigs).get();
    return rows.map(_toModel).toList();
  }

  @override
  Future<ApiConfig?> getById(String id) async {
    final row = await (_db.select(
      _db.apiConfigs,
    )..where((t) => t.configId.equals(id))).getSingleOrNull();
    return row != null ? _toModel(row) : null;
  }

  @override
  Future<void> put(ApiConfig config) async {
    final persisted = config.copyWith(
      endpoint: EndpointNormalizer.persistedLlmEndpoint(
        raw: config.endpoint,
        protocol: config.protocol,
        model: config.model,
        stream: config.stream,
        useResponsesApi: config.useResponsesApi,
      ),
      embeddingEndpoint: EndpointNormalizer.persistedEmbeddingEndpoint(
        config.embeddingEndpoint,
      ),
    );
    await _db
        .into(_db.apiConfigs)
        .insertOnConflictUpdate(_toCompanion(persisted));
  }

  @override
  Future<void> delete(String id) async {
    await (_db.delete(
      _db.apiConfigs,
    )..where((t) => t.configId.equals(id))).go();
  }

  Future<void> putFromMap(Map<String, dynamic> m) async {
    final config = ApiConfig.fromJson(m);
    await put(config);
  }

  ApiConfig _toModel(ApiConfigRow c) => ApiConfig(
    id: c.configId,
    name: c.name,
    providerId: c.providerId,
    protocol: c.protocol,
    endpoint: c.endpoint ?? '',
    apiKey: c.apiKey ?? '',
    model: c.model ?? '',
    mode: c.mode,
    maxTokens: c.maxTokens,
    contextSize: c.contextSize,
    historyTrimMode: HistoryTrimMode.normalize(c.historyTrimMode),
    historyTrimTriggerPercent: c.historyTrimTriggerPercent,
    historyTrimStepPercent: c.historyTrimStepPercent,
    temperature: c.temperature,
    topP: c.topP,
    topK: c.topK,
    frequencyPenalty: c.frequencyPenalty,
    presencePenalty: c.presencePenalty,
    stream: c.stream,
    reasoningEffort: c.reasoningEffort ?? 'medium',
    requestReasoning: c.requestReasoning,
    useResponsesApi: c.useResponsesApi,
    showNativeReasoning: c.showNativeReasoning,
    reasoningHistoryCount: c.reasoningHistoryCount,
    excludeReasoningFromContextBudget: c.excludeReasoningFromContextBudget,
    reasoningTagStart: c.reasoningTagStart,
    reasoningTagEnd: c.reasoningTagEnd,
    embeddingUseSame: c.embeddingUseSame,
    embeddingEnabled: c.embeddingEnabled,
    embeddingEndpoint: c.embeddingEndpoint ?? '',
    embeddingApiKey: c.embeddingApiKey ?? '',
    embeddingModel: c.embeddingModel ?? '',
    embeddingMaxChunkTokens: c.embeddingMaxChunkTokens,
    embeddingRequestsPerMinute: c.embeddingRequestsPerMinute,
    embeddingLlmPresetId: c.embeddingLlmPresetId,
    omitTemperature: c.omitTemperature,
    omitTopP: c.omitTopP,
    omitTopK: c.omitTopK,
    omitFrequencyPenalty: c.omitFrequencyPenalty,
    omitPresencePenalty: c.omitPresencePenalty,
    omitReasoning: c.omitReasoning,
    omitReasoningEffort: c.omitReasoningEffort,
    cacheControlTtl: c.cacheControlTtl,
    cacheBreakpointMode: c.cacheBreakpointMode,
    sessionIdMode: c.sessionIdMode,
    promptPostProcessing: c.promptPostProcessing,
    firstChunkTimeoutMs: c.firstChunkTimeoutMs,
    useSystemInstruction: c.useSystemInstruction,
    extraRequestParameters:
        (jsonDecode(c.extraRequestParametersJson) as List<dynamic>)
            .map(
              (value) => ExtraRequestParameter.fromJson(
                Map<String, dynamic>.from(value as Map),
              ),
            )
            .toList(growable: false),
  );

  ApiConfigsCompanion _toCompanion(ApiConfig m) => ApiConfigsCompanion(
    configId: Value(m.id),
    name: Value(m.name),
    providerId: Value(m.providerId),
    protocol: Value(m.protocol),
    endpoint: Value(m.endpoint),
    apiKey: Value(m.apiKey),
    model: Value(m.model),
    mode: Value(m.mode),
    maxTokens: Value(m.maxTokens),
    contextSize: Value(m.contextSize),
    historyTrimMode: Value(HistoryTrimMode.normalize(m.historyTrimMode)),
    historyTrimTriggerPercent: Value(m.historyTrimTriggerPercent),
    historyTrimStepPercent: Value(m.historyTrimStepPercent),
    temperature: Value(m.temperature),
    topP: Value(m.topP),
    topK: Value(m.topK),
    frequencyPenalty: Value(m.frequencyPenalty),
    presencePenalty: Value(m.presencePenalty),
    stream: Value(m.stream),
    reasoningEffort: Value(m.reasoningEffort),
    requestReasoning: Value(m.requestReasoning),
    useResponsesApi: Value(m.useResponsesApi),
    showNativeReasoning: Value(m.showNativeReasoning),
    includeLastReasoning: Value(m.reasoningHistoryCount != 0),
    reasoningHistoryCount: Value(m.reasoningHistoryCount),
    excludeReasoningFromContextBudget: Value(
      m.excludeReasoningFromContextBudget,
    ),
    reasoningTagStart: Value(m.reasoningTagStart),
    reasoningTagEnd: Value(m.reasoningTagEnd),
    embeddingUseSame: Value(m.embeddingUseSame),
    embeddingEnabled: Value(m.embeddingEnabled),
    embeddingEndpoint: Value(m.embeddingEndpoint),
    embeddingApiKey: Value(m.embeddingApiKey),
    embeddingModel: Value(m.embeddingModel),
    embeddingMaxChunkTokens: Value(m.embeddingMaxChunkTokens),
    embeddingRequestsPerMinute: Value(m.embeddingRequestsPerMinute),
    embeddingLlmPresetId: Value(m.embeddingLlmPresetId),
    omitTemperature: Value(m.omitTemperature),
    omitTopP: Value(m.omitTopP),
    omitTopK: Value(m.omitTopK),
    omitFrequencyPenalty: Value(m.omitFrequencyPenalty),
    omitPresencePenalty: Value(m.omitPresencePenalty),
    omitReasoning: Value(m.omitReasoning),
    omitReasoningEffort: Value(m.omitReasoningEffort),
    cacheControlTtl: Value(m.cacheControlTtl),
    cacheBreakpointMode: Value(m.cacheBreakpointMode),
    sessionIdMode: Value(m.sessionIdMode),
    promptPostProcessing: Value(m.promptPostProcessing),
    firstChunkTimeoutMs: Value(m.firstChunkTimeoutMs),
    useSystemInstruction: Value(m.useSystemInstruction),
    extraRequestParametersJson: Value(
      jsonEncode(
        m.extraRequestParameters.map((value) => value.toJson()).toList(),
      ),
    ),
  );
}
