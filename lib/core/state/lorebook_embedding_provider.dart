/// Riverpod providers for lorebook embedding and vector search.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/api_list_provider.dart';
import '../llm/embedding_request_gate.dart';
import '../llm/embedding_service.dart';
import '../llm/lorebook_embedding_service.dart';
import '../llm/lorebook_vector_search.dart';
import '../llm/session_lorebook_embedding_worker.dart';
import '../models/api_config.dart';
import 'db_provider.dart';

/// The embedding connection every vector request runs on.
///
/// Reads its settings from [activeEmbeddingConfigProvider] — the preset picked
/// on the API screen's *Embeddings* tab, which has a list of its own — so
/// switching the chat connection leaves the vector index alone. The one place
/// the two still meet is that preset's "Use LLM API" toggle: while it is on,
/// the endpoint and key come from the LLM preset it names
/// ([ApiConfig.embeddingLlmPresetId]), or from the active one when it names
/// none. Only in that case is any chat state watched here.
final embeddingConfigProvider = Provider<EmbeddingConfig>((ref) {
  final embConfig = ref.watch(activeEmbeddingConfigProvider);
  EmbeddingRequestGate.setEnabled(embConfig?.embeddingEnabled == true);
  final borrowsLlmEndpoint =
      embConfig != null &&
      (embConfig.embeddingUseSame || embConfig.embeddingEndpoint.isEmpty);
  final llmConfig = borrowsLlmEndpoint
      ? ref.watch(embeddingLlmSourceProvider)
      : null;
  return resolveEmbeddingConfig(embConfig, llmConfig);
});

/// The LLM preset an embedding request borrows its endpoint and key from while
/// "Use LLM API" is on: the one the embedding preset names, falling back to
/// whichever connection the LLM tab is on (the behaviour when it names none,
/// and when the named preset is gone).
final embeddingLlmSourceProvider = Provider<ApiConfig?>((ref) {
  final embConfig = ref.watch(activeEmbeddingConfigProvider);
  final pinnedId = embConfig?.embeddingLlmPresetId ?? '';
  if (pinnedId.isNotEmpty) {
    final list = ref.watch(apiListProvider).value ?? const <ApiConfig>[];
    for (final config in list) {
      if (config.id == pinnedId) return config;
    }
  }
  return ref.watch(activeApiConfigProvider);
});

/// True when the preset the embedding side runs on has vector (semantic)
/// search switched on.
///
/// Every vector / embedding / index affordance in the UI hangs off this: with
/// embeddings off there is no endpoint to index against, so the buttons and
/// hints stay hidden instead of failing at tap time. Mirrors the condition
/// [resolveEmbeddingConfig] uses to decide whether a usable config exists.
final vectorSearchAvailableProvider = Provider<bool>((ref) {
  final config = ref.watch(activeEmbeddingConfigProvider);
  return config != null && config.embeddingEnabled;
});

/// Builds the embedding connection out of the embedding preset, borrowing the
/// endpoint and key from [llmConfig] while "Use LLM API" is on (or while the
/// dedicated endpoint is still blank). [llmConfig] defaults to the embedding
/// preset itself, which is what the borrow meant while embeddings still shared
/// the chat preset.
EmbeddingConfig resolveEmbeddingConfig(
  ApiConfig? embeddingConfig, [
  ApiConfig? llmConfig,
]) {
  if (embeddingConfig == null || !embeddingConfig.embeddingEnabled) {
    return const EmbeddingConfig(endpoint: '', model: '');
  }
  if (embeddingConfig.embeddingUseSame ||
      embeddingConfig.embeddingEndpoint.isEmpty) {
    final source = llmConfig ?? embeddingConfig;
    return EmbeddingConfig(
      endpoint: source.endpoint,
      apiKey: source.apiKey,
      model: embeddingConfig.embeddingModel.isNotEmpty
          ? embeddingConfig.embeddingModel
          : source.model,
      maxChunkTokens: embeddingConfig.embeddingMaxChunkTokens,
      requestsPerMinute: embeddingConfig.embeddingRequestsPerMinute,
    );
  } else {
    return EmbeddingConfig(
      endpoint: embeddingConfig.embeddingEndpoint,
      apiKey: embeddingConfig.embeddingApiKey,
      model: embeddingConfig.embeddingModel,
      maxChunkTokens: embeddingConfig.embeddingMaxChunkTokens,
      requestsPerMinute: embeddingConfig.embeddingRequestsPerMinute,
    );
  }
}

final lorebookVectorSearchProvider = Provider<LorebookVectorSearch>((ref) {
  return LorebookVectorSearch(
    ref.watch(embeddingRepoProvider),
    EmbeddingService(),
  );
});

final lorebookEmbeddingServiceProvider = Provider<LorebookEmbeddingService>((
  ref,
) {
  return LorebookEmbeddingService(
    ref.watch(embeddingRepoProvider),
    EmbeddingService(),
  );
});

final sessionLorebookEmbeddingWorkerProvider =
    Provider<SessionLorebookEmbeddingWorker>((ref) {
      return SessionLorebookEmbeddingWorker(
        db: ref.watch(appDbProvider),
        jobRepo: ref.watch(sessionLorebookEmbeddingJobRepoProvider),
        evolutionRepo: ref.watch(sessionLorebookEvolutionRepoProvider),
        lorebookRepo: ref.watch(lorebookRepoProvider),
        embeddingRepo: ref.watch(embeddingRepoProvider),
        embeddingService: EmbeddingService(),
        readConfig: () => ref.read(embeddingConfigProvider),
      );
    });
