import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/llm/embedding_request_gate.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';

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
        embeddingRequestsPerMinute: 40,
      );

      final config = resolveEmbeddingConfig(api);

      expect(config.endpoint, api.endpoint);
      expect(config.apiKey, api.apiKey);
      expect(config.model, api.embeddingModel);
      expect(config.maxChunkTokens, 256);
      expect(config.requestsPerMinute, 40);
    });
  });

  group('vectorSearchAvailableProvider', () {
    bool available(ApiConfig? config) {
      final container = ProviderContainer(
        overrides: [activeApiConfigProvider.overrideWithValue(config)],
      );
      addTearDown(container.dispose);
      return container.read(vectorSearchAvailableProvider);
    }

    test('is false without an active API preset', () {
      expect(available(null), isFalse);
    });

    test('is false while embeddings are disabled on the preset', () {
      expect(
        available(
          const ApiConfig(
            id: 'api',
            endpoint: 'https://api.example/v1',
            model: 'chat-model',
          ),
        ),
        isFalse,
      );
    });

    test('is false for an embedding-only preset', () {
      expect(
        available(
          const ApiConfig(
            id: 'api',
            endpoint: 'https://api.example/v1',
            model: 'chat-model',
            mode: 'embedding',
            embeddingEnabled: true,
          ),
        ),
        isFalse,
      );
    });

    test('is true once embeddings are enabled on the chat preset', () {
      expect(
        available(
          const ApiConfig(
            id: 'api',
            endpoint: 'https://api.example/v1',
            model: 'chat-model',
            embeddingEnabled: true,
          ),
        ),
        isTrue,
      );
    });

    test('gates every vector affordance in the UI', () {
      // Each of these screens/sheets used to show its vector, embedding or
      // index controls unconditionally.
      const gated = [
        'lib/features/lorebooks/lorebook_list_screen.dart',
        'lib/features/lorebooks/lorebook_global_settings_screen.dart',
        'lib/features/lorebooks/lorebook_per_book_settings_screen.dart',
        'lib/features/lorebooks/lorebook_editor_screen.dart',
        'lib/features/chat/widgets/memory_books_tab.dart',
        'lib/features/chat/widgets/memory_generation_settings_sheet.dart',
      ];
      for (final path in gated) {
        expect(
          File(path).readAsStringSync(),
          contains('vectorSearchAvailableProvider'),
          reason: '$path must gate its vector UI on the API toggle',
        );
      }
    });
  });

  group('EmbeddingRequestGate', () {
    tearDown(() {
      EmbeddingRequestGate.setEnabled(true);
      EmbeddingRequestRateLimiter.resetForTesting();
    });

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

    test('rate limiter spaces concurrent request starts', () async {
      final first = EmbeddingRequestGate.beginRequest(null);
      final second = EmbeddingRequestGate.beginRequest(null);
      final stopwatch = Stopwatch()..start();

      await Future.wait([
        EmbeddingRequestRateLimiter.acquire(600, first),
        EmbeddingRequestRateLimiter.acquire(600, second),
      ]);

      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(80));
      EmbeddingRequestGate.endRequest(first);
      EmbeddingRequestGate.endRequest(second);
    });

    test('rate limiter wait is cancellable', () async {
      final first = EmbeddingRequestGate.beginRequest(null);
      final second = EmbeddingRequestGate.beginRequest(null);
      await EmbeddingRequestRateLimiter.acquire(60, first);

      final waiting = EmbeddingRequestRateLimiter.acquire(60, second);
      second.cancel('cancelled');

      await expectLater(waiting, throwsA(isA<Object>()));
      EmbeddingRequestGate.endRequest(first);
      EmbeddingRequestGate.endRequest(second);
    });
  });
}
