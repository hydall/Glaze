import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/llm/embedding_request_gate.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

    test('borrows the active LLM preset while "use LLM API" is on', () {
      const llm = ApiConfig(
        id: 'llm',
        endpoint: 'https://llm.example/v1',
        apiKey: 'llm-key',
        model: 'chat-model',
      );
      const embedding = ApiConfig(
        id: 'embedding',
        endpoint: 'https://other.example/v1',
        apiKey: 'other-key',
        model: 'other-chat-model',
        embeddingEnabled: true,
        embeddingUseSame: true,
        embeddingModel: 'embedding-model',
      );

      final config = resolveEmbeddingConfig(embedding, llm);

      // The toggle is the one link left between the two selections: the
      // endpoint and key come from the LLM preset, everything else from the
      // embedding one.
      expect(config.endpoint, llm.endpoint);
      expect(config.apiKey, llm.apiKey);
      expect(config.model, 'embedding-model');
    });

    test(
      'ignores the LLM preset once the endpoint is the embedding preset\'s own',
      () {
        const llm = ApiConfig(
          id: 'llm',
          endpoint: 'https://llm.example/v1',
          apiKey: 'llm-key',
          model: 'chat-model',
        );
        const embedding = ApiConfig(
          id: 'embedding',
          embeddingEnabled: true,
          embeddingUseSame: false,
          embeddingEndpoint: 'https://vectors.example/v1',
          embeddingApiKey: 'vector-key',
          embeddingModel: 'embedding-model',
        );

        final config = resolveEmbeddingConfig(embedding, llm);

        expect(config.endpoint, 'https://vectors.example/v1');
        expect(config.apiKey, 'vector-key');
        expect(config.model, 'embedding-model');
      },
    );
  });

  group('vectorSearchAvailableProvider', () {
    bool available(ApiConfig? config) {
      final container = ProviderContainer(
        overrides: [activeEmbeddingConfigProvider.overrideWithValue(config)],
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

    test('is true once embeddings are enabled on the embedding preset', () {
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

    test('follows the embedding preset, not the chat one', () {
      // The chat preset having embeddings off must not hide the vector UI when
      // the embedding side runs on a preset that has them on.
      final container = ProviderContainer(
        overrides: [
          activeApiConfigProvider.overrideWithValue(
            const ApiConfig(id: 'chat', endpoint: 'https://chat.example/v1'),
          ),
          activeEmbeddingConfigProvider.overrideWithValue(
            const ApiConfig(
              id: 'embedding',
              endpoint: 'https://vectors.example/v1',
              embeddingEnabled: true,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(vectorSearchAvailableProvider), isTrue);
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

  group('the embedding preset selection', () {
    Future<ProviderContainer> containerWith(
      List<ApiConfig> configs, {
      Map<String, Object> prefs = const {},
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [appDbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      for (final config in configs) {
        await container.read(apiConfigRepoProvider).put(config);
      }
      container.invalidate(apiListProvider);
      await container.read(apiListProvider.future);
      return container;
    }

    const chat = ApiConfig(
      id: 'chat',
      name: 'Chat',
      endpoint: 'https://chat.example/v1',
      apiKey: 'chat-key',
      model: 'chat-model',
    );
    const otherChat = ApiConfig(
      id: 'other-chat',
      name: 'Other chat',
      endpoint: 'https://other-chat.example/v1',
      apiKey: 'other-chat-key',
      model: 'other-chat-model',
    );
    const vectors = ApiConfig(
      id: 'vectors',
      name: 'Vectors',
      embeddingEnabled: true,
      embeddingUseSame: false,
      embeddingEndpoint: 'https://vectors.example/v1',
      embeddingApiKey: 'vector-key',
      embeddingModel: 'embedding-model',
    );

    test(
      'switching the chat preset leaves the embedding one where it is',
      () async {
        final container = await containerWith([chat, otherChat, vectors]);
        container.read(activeEmbeddingPresetIdProvider.notifier).state =
            vectors.id;
        // The repo normalizes an endpoint on the way in, so the expectation is
        // taken from the stored preset rather than from the literal above.
        final stored = container.read(activeEmbeddingConfigProvider)!;
        final before = container.read(embeddingConfigProvider);
        expect(before.endpoint, stored.embeddingEndpoint);

        container.read(activeApiPresetIdProvider.notifier).state = otherChat.id;

        expect(container.read(activeApiConfigProvider)?.id, otherChat.id);
        expect(container.read(activeEmbeddingConfigProvider)?.id, vectors.id);
        final config = container.read(embeddingConfigProvider);
        expect(config.endpoint, stored.embeddingEndpoint);
        expect(config.apiKey, 'vector-key');
        expect(config.model, 'embedding-model');
      },
    );

    test(
      '"use LLM API" follows the chat preset the user switches to',
      () async {
        const shared = ApiConfig(
          id: 'shared',
          name: 'Shared',
          embeddingEnabled: true,
          embeddingUseSame: true,
          embeddingModel: 'embedding-model',
        );
        final container = await containerWith([chat, otherChat, shared]);
        container.read(activeEmbeddingPresetIdProvider.notifier).state =
            shared.id;
        final storedChat = container.read(activeApiConfigProvider)!;
        expect(
          container.read(embeddingConfigProvider).endpoint,
          storedChat.endpoint,
        );

        container.read(activeApiPresetIdProvider.notifier).state = otherChat.id;

        final storedOther = container.read(activeApiConfigProvider)!;
        final config = container.read(embeddingConfigProvider);
        expect(config.endpoint, storedOther.endpoint);
        expect(config.apiKey, otherChat.apiKey);
        expect(config.model, 'embedding-model');
      },
    );

    test(
      'pins the embedding preset to the saved chat one on first run',
      () async {
        final container = await containerWith(
          [chat, vectors],
          prefs: {'activeApiConfigId': vectors.id},
        );

        expect(container.read(activeEmbeddingPresetIdProvider), vectors.id);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(kActiveEmbeddingConfigIdKey), vectors.id);
      },
    );

    test(
      'restores a stored embedding preset that differs from the chat one',
      () async {
        final container = await containerWith(
          [chat, otherChat, vectors],
          prefs: {
            'activeApiConfigId': otherChat.id,
            kActiveEmbeddingConfigIdKey: vectors.id,
          },
        );

        expect(container.read(activeApiConfigProvider)?.id, otherChat.id);
        expect(container.read(activeEmbeddingConfigProvider)?.id, vectors.id);
      },
    );
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
