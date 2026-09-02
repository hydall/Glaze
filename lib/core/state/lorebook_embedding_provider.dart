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
/// on the API screen's *Embeddings* tab — so switching the chat connection
/// leaves the vector index alone. The one place the two still meet is the
/// preset's "Use LLM API" toggle: while it is on the endpoint and key are
/// borrowed from the active LLM preset, so that (and only that) selection is
/// watched here.
final embeddingConfigProvider = Provider<EmbeddingConfig>((ref) {
  final embConfig = ref.watch(activeEmbeddingConfigProvider);
  EmbeddingRequestGate.setEnabled(embConfig?.embeddingEnabled == true);
  final borrowsLlmEndpoint =
      embConfig != null &&
      (embConfig.embeddingUseSame || embConfig.embeddingEndpoint.isEmpty);
  final llmConfig = borrowsLlmEndpoint
      ? ref.watch(activeApiConfigProvider)
      : null;
  return resolveEmbeddingConfig(embConfig, llmConfig);
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
  return config != null &&
      config.mode != 'embedding' &&
      config.embeddingEnabled;
});

/// Builds the embedding connection out of the embedding preset, borrowing the
/// endpoint and key from [llmConfig] while "Use LLM API" is on (or while the
/// dedicated endpoint is still blank). [llmConfig] defaults to the embedding
/// preset itself, which is what the borrow meant before the two selections
/// were split.
EmbeddingConfig resolveEmbeddingConfig(
  ApiConfig? embeddingConfig, [
  ApiConfig? llmConfig,
]) {
  if (embeddingConfig == null ||
      embeddingConfig.mode == 'embedding' ||
      !embeddingConfig.embeddingEnabled) {
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
