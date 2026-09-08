import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/llm/embedding_request_gate.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';

void main() {
  group('resolveEmbeddingConfig', () {
    test('returns no endpoint when embeddings are disabled', () {
      const api = ApiConfig(
        id: 'api',
        endpoint: 'https://api.example/v1',
        model: 'chat-model',
        embeddingEnabled: false,
        embeddingUseSame: true,
      );

      final config = resolveEmbeddingConfig(api);

      expect(config.endpoint, isEmpty);
      expect(config.model, isEmpty);
    });

    test('uses the chat endpoint when enabled and configured to share it', () {
      const api = ApiConfig(
        id: 'api',
        endpoint: 'https://api.example/v1',
        apiKey: 'key',
        model: 'chat-model',
        embeddingEnabled: true,
        embeddingUseSame: true,
        embeddingModel: 'embedding-model',
        embeddingMaxChunkTokens: 256,
      );

      final config = resolveEmbeddingConfig(api);

      expect(config.endpoint, api.endpoint);
      expect(config.apiKey, api.apiKey);
      expect(config.model, api.embeddingModel);
      expect(config.maxChunkTokens, 256);
    });
  });

  group('EmbeddingRequestGate', () {
    tearDown(() => EmbeddingRequestGate.setEnabled(true));

    test('rejects requests immediately after embeddings are disabled', () {
      EmbeddingRequestGate.setEnabled(false);

      final token = EmbeddingRequestGate.beginRequest(null);

      expect(token.isCancelled, isTrue);
    });

    test('cancels requests that were already active', () {
      final token = EmbeddingRequestGate.beginRequest(null);

      EmbeddingRequestGate.setEnabled(false);

      expect(token.isCancelled, isTrue);
    });
  });
}
