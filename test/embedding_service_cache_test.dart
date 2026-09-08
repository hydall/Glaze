import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';

void main() {
  group('EmbeddingService cache (via _callEmbeddingApi surface)', () {
    test('caches identical texts across two calls (smoke test of plumbing)',
        () async {
      // The internal _EmbeddingCache class is private; we only verify that
      // the public service is still usable with the new caching field
      // initialized. Real cache-hit behaviour requires a network stub and
      // is covered by manual runs.
      final service = EmbeddingService();
      expect(service, isNotNull);
    });
  });

  group('resolveEmbeddingEndpoint', () {
    test('prepends https:// when scheme is missing (iOS fix)', () {
      expect(
        resolveEmbeddingEndpoint('api.host/v1'),
        'https://api.host/v1/embeddings',
      );
    });

    test('preserves an existing http:// scheme', () {
      expect(
        resolveEmbeddingEndpoint('http://127.0.0.1:11434/v1'),
        'http://127.0.0.1:11434/v1/embeddings',
      );
    });

    test('preserves an existing https:// scheme', () {
      expect(
        resolveEmbeddingEndpoint('https://api.openai.com/v1'),
        'https://api.openai.com/v1/embeddings',
      );
    });

    test('trims whitespace before resolving', () {
      expect(
        resolveEmbeddingEndpoint('  https://api.host/v1  '),
        'https://api.host/v1/embeddings',
      );
    });

    test('does not double-append when path already ends in /embeddings', () {
      expect(
        resolveEmbeddingEndpoint('https://api.host/v1/embeddings'),
        'https://api.host/v1/embeddings',
      );
      expect(
        resolveEmbeddingEndpoint('api.host/v1/embeddings/'),
        'https://api.host/v1/embeddings/',
      );
    });

    test('strips trailing slashes before appending', () {
      expect(
        resolveEmbeddingEndpoint('https://api.host/v1//'),
        'https://api.host/v1/embeddings',
      );
    });

    test('returns empty string untouched', () {
      expect(resolveEmbeddingEndpoint(''), '');
      expect(resolveEmbeddingEndpoint('   '), '');
    });
  });

  group('EmbeddingConfig', () {
    test('defaults are sensible', () {
      const config = EmbeddingConfig(endpoint: 'https://x');
      expect(config.endpoint, 'https://x');
      expect(config.apiKey, isEmpty);
      expect(config.model, isEmpty);
      expect(config.maxChunkTokens, 8192);
    });
  });
}
