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

final embeddingConfigProvider = Provider<EmbeddingConfig>((ref) {
  final chatConfig = ref.watch(activeApiConfigProvider);
  EmbeddingRequestGate.setEnabled(chatConfig?.embeddingEnabled == true);
  return resolveEmbeddingConfig(chatConfig);
});

/// True when the active API preset has vector (semantic) search switched on.
///
/// Every vector / embedding / index affordance in the UI hangs off this: with
/// embeddings off there is no endpoint to index against, so the buttons and
/// hints stay hidden instead of failing at tap time. Mirrors the condition
/// [resolveEmbeddingConfig] uses to decide whether a usable config exists.
final vectorSearchAvailableProvider = Provider<bool>((ref) {
  final config = ref.watch(activeApiConfigProvider);
  return config != null && config.mode != 'embedding' && config.embeddingEnabled;
});

EmbeddingConfig resolveEmbeddingConfig(ApiConfig? chatConfig) {
  if (chatConfig == null ||
      chatConfig.mode == 'embedding' ||
      !chatConfig.embeddingEnabled) {
    return const EmbeddingConfig(endpoint: '', model: '');
  }
  if (chatConfig.embeddingUseSame || chatConfig.embeddingEndpoint.isEmpty) {
    return EmbeddingConfig(
      endpoint: chatConfig.endpoint,
      apiKey: chatConfig.apiKey,
      model: chatConfig.embeddingModel.isNotEmpty
          ? chatConfig.embeddingModel
          : chatConfig.model,
      maxChunkTokens: chatConfig.embeddingMaxChunkTokens,
      requestsPerMinute: chatConfig.embeddingRequestsPerMinute,
    );
  } else {
    return EmbeddingConfig(
      endpoint: chatConfig.embeddingEndpoint,
      apiKey: chatConfig.embeddingApiKey,
      model: chatConfig.embeddingModel,
      maxChunkTokens: chatConfig.embeddingMaxChunkTokens,
      requestsPerMinute: chatConfig.embeddingRequestsPerMinute,
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
