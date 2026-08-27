import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/endpoint_normalizer.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';

void main() {
  group('persisted endpoints', () {
    test('stores the concrete generation route for every protocol', () {
      String endpoint(
        String protocol, {
        bool useResponsesApi = false,
        bool stream = true,
      }) => EndpointNormalizer.persistedLlmEndpoint(
        raw: 'https://example.com/v1/',
        protocol: protocol,
        model: 'model-name',
        stream: stream,
        useResponsesApi: useResponsesApi,
      );

      expect(
        endpoint(LlmProtocol.openai),
        'https://example.com/v1/chat/completions',
      );
      expect(
        endpoint(LlmProtocol.customChatCompletion, useResponsesApi: true),
        'https://example.com/v1/responses',
      );
      expect(
        endpoint(LlmProtocol.openaiResponses),
        'https://example.com/v1/responses',
      );
      expect(
        endpoint(LlmProtocol.anthropic),
        'https://example.com/v1/messages',
      );
      expect(
        endpoint(LlmProtocol.gemini),
        'https://example.com/v1beta/models/model-name:streamGenerateContent',
      );
      expect(
        endpoint(LlmProtocol.gemini, stream: false),
        'https://example.com/v1beta/models/model-name:generateContent',
      );
      expect(
        endpoint(LlmProtocol.openrouter),
        'https://openrouter.ai/api/v1/chat/completions',
      );
    });

    test('preserves invalid text and completes embedding routes', () {
      expect(
        EndpointNormalizer.persistedLlmEndpoint(
          raw: '  not a url  ',
          protocol: LlmProtocol.openai,
          model: '',
          stream: true,
        ),
        'not a url',
      );
      expect(
        EndpointNormalizer.persistedEmbeddingEndpoint('example.com/v1'),
        'https://example.com/v1/embeddings',
      );
    });
  });

  group('bare host → full chat URL', () {
    test('adds scheme and the version the provider serves', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('api.openai.com'),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('unknown host gets the default /v1', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('https://proxy.tld'),
        'https://proxy.tld/v1/chat/completions',
      );
    });

    test('trailing slashes are stripped', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('https://api.openai.com///'),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('localhost defaults to http, not https', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('localhost:1234'),
        'http://localhost:1234/v1/chat/completions',
      );
      expect(
        EndpointNormalizer.chatCompletionsUrl('127.0.0.1:5000'),
        'http://127.0.0.1:5000/v1/chat/completions',
      );
      expect(
        EndpointNormalizer.chatCompletionsUrl('192.168.1.5:8080'),
        'http://192.168.1.5:8080/v1/chat/completions',
      );
    });

    test('IPv6 host keeps its brackets', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('http://[::1]:8080/v1'),
        'http://[::1]:8080/v1/chat/completions',
      );
    });
  });

  group('the user forgot /v1', () {
    test('known host: the missing version is restored', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl(
          'https://api.openai.com/chat/completions',
        ),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('openrouter resolves to its /api/v1 base', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('openrouter.ai'),
        'https://openrouter.ai/api/v1/chat/completions',
      );
    });

    test('groq resolves to its /openai/v1 base', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('api.groq.com'),
        'https://api.groq.com/openai/v1/chat/completions',
      );
    });

    test('unknown host keeps the pasted URL, fallback covers the rest', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl(
          'https://proxy.tld/chat/completions',
        ),
        'https://proxy.tld/chat/completions',
      );
      expect(
        EndpointNormalizer.chatCompletionsCandidates(
          'https://proxy.tld/chat/completions',
        ),
        [
          'https://proxy.tld/chat/completions',
          'https://proxy.tld/v1/chat/completions',
        ],
      );
    });
  });

  group('providers whose base is not /v1', () {
    test('perplexity serves at the root — no version is invented', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('api.perplexity.ai'),
        'https://api.perplexity.ai/chat/completions',
      );
    });

    test('a /v1 typed onto perplexity is corrected away', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('https://api.perplexity.ai/v1'),
        'https://api.perplexity.ai/chat/completions',
      );
    });

    test('deepinfra keeps its /v1/openai base', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('api.deepinfra.com'),
        'https://api.deepinfra.com/v1/openai/chat/completions',
      );
    });

    test('gemini via the OpenAI-compatible surface', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl(
          'generativelanguage.googleapis.com',
        ),
        'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
      );
    });
  });

  group('typos', () {
    test('misspelled operation path is corrected', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl(
          'api.openai.com/v1/chat/compeltions',
        ),
        'https://api.openai.com/v1/chat/completions',
      );
      expect(
        EndpointNormalizer.chatCompletionsUrl(
          'https://proxy.tld/v1/chat/completion',
        ),
        'https://proxy.tld/v1/chat/completions',
      );
    });

    test('misspelled scheme is repaired', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('htp:/api.openai.com/v1'),
        'https://api.openai.com/v1/chat/completions',
      );
      expect(
        EndpointNormalizer.chatCompletionsUrl('https//api.mistral.ai'),
        'https://api.mistral.ai/v1/chat/completions',
      );
      expect(
        EndpointNormalizer.chatCompletionsUrl(r'https:\\proxy.tld\v1'),
        'https://proxy.tld/v1/chat/completions',
      );
    });

    test('an explicit http:// scheme is never silently upgraded', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('http://proxy.tld/v1'),
        'http://proxy.tld/v1/chat/completions',
      );
    });

    test('mistyped version segment is repaired', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('https://proxy.tld/vl'),
        'https://proxy.tld/v1/chat/completions',
      );
    });

    test('quotes, spaces and trailing punctuation are peeled off', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('  https://api.host/v1  '),
        'https://api.host/v1/chat/completions',
      );
      expect(
        EndpointNormalizer.chatCompletionsUrl('"https://api.host/v1",'),
        'https://api.host/v1/chat/completions',
      );
      expect(
        EndpointNormalizer.chatCompletionsUrl('<https://api.host/v1>'),
        'https://api.host/v1/chat/completions',
      );
    });

    test('uppercase input is normalized', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('HTTPS://API.X.AI/V1'),
        'https://api.x.ai/v1/chat/completions',
      );
    });
  });

  group('a complete URL for another route', () {
    test('an /embeddings or /models URL still yields the chat URL', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('https://api.host/v1/embeddings'),
        'https://api.host/v1/chat/completions',
      );
      expect(
        EndpointNormalizer.chatCompletionsUrl('https://api.host/v1/models'),
        'https://api.host/v1/chat/completions',
      );
    });

    test('a gemini generate URL collapses back to the base', () {
      expect(
        EndpointNormalizer.geminiBase(
          'https://generativelanguage.googleapis.com/v1beta/models/'
          'gemini-3-pro:streamGenerateContent',
        ),
        'https://generativelanguage.googleapis.com',
      );
    });
  });

  group('invalid input', () {
    test('empty and blank resolve to nothing', () {
      expect(EndpointNormalizer.chatCompletionsUrl(''), '');
      expect(EndpointNormalizer.chatCompletionsUrl('   '), '');
      expect(EndpointNormalizer.chatCompletionsCandidates(''), isEmpty);
    });

    test('free text is not accepted as a host', () {
      expect(EndpointNormalizer.chatCompletionsUrl('not a url'), '');
      expect(EndpointNormalizer.chatCompletionsUrl('chat/completions'), '');
    });

    test('non-http schemes are rejected instead of repaired', () {
      expect(EndpointNormalizer.chatCompletionsUrl('ftp://host.tld/v1'), '');
      expect(EndpointNormalizer.chatCompletionsUrl('ws://host.tld/v1'), '');
    });

    test('an explicit scheme makes a single-label host deliberate', () {
      expect(
        EndpointNormalizer.chatCompletionsUrl('http://llm-box:8080'),
        'http://llm-box:8080/v1/chat/completions',
      );
    });
  });

  group('azure deployments', () {
    const azure =
        'https://contoso.openai.azure.com/openai/deployments/gpt4o'
        '/chat/completions?api-version=2024-02-01';

    test('path and mandatory api-version query survive intact', () {
      expect(EndpointNormalizer.chatCompletionsUrl(azure), azure);
    });

    test('no version segment is invented for a deployment path', () {
      expect(
        EndpointNormalizer.baseUrl(azure),
        'https://contoso.openai.azure.com/openai/deployments/gpt4o',
      );
    });
  });

  group('other routes', () {
    test('anthropic messages', () {
      expect(
        EndpointNormalizer.messagesUrl('api.anthropic.com'),
        'https://api.anthropic.com/v1/messages',
      );
      expect(
        EndpointNormalizer.messagesUrl('https://api.anthropic.com/v1/messages'),
        'https://api.anthropic.com/v1/messages',
      );
    });

    test('responses API', () {
      expect(
        EndpointNormalizer.responsesUrl(
          'https://api.openai.com/v1/chat/completions',
        ),
        'https://api.openai.com/v1/responses',
      );
      expect(
        EndpointNormalizer.responsesUrl('https://api.openai.com/v1/responses'),
        'https://api.openai.com/v1/responses',
      );
    });

    test('embeddings', () {
      expect(
        EndpointNormalizer.embeddingsUrl('api.host/v1'),
        'https://api.host/v1/embeddings',
      );
      expect(
        EndpointNormalizer.embeddingsUrl('api.host/v1/embeddings/'),
        'https://api.host/v1/embeddings',
      );
    });

    test('image generations and edits', () {
      expect(
        EndpointNormalizer.imagesUrl('api.openai.com', 'generations'),
        'https://api.openai.com/v1/images/generations',
      );
      expect(
        EndpointNormalizer.imagesUrl(
          'https://api.openai.com/v1/images/generations',
          'edits',
        ),
        'https://api.openai.com/v1/images/edits',
      );
      expect(
        EndpointNormalizer.imagesUrl('http://127.0.0.1:8080', 'generations'),
        'http://127.0.0.1:8080/v1/images/generations',
      );
    });

    test('gemini base never carries a version segment', () {
      expect(
        EndpointNormalizer.geminiBase(
          'https://generativelanguage.googleapis.com/v1beta',
        ),
        'https://generativelanguage.googleapis.com',
      );
      expect(
        EndpointNormalizer.geminiBase('proxy.tld/gemini/v1beta'),
        'https://proxy.tld/gemini',
      );
    });
  });

  group('candidates', () {
    test('a version-less base offers the /v1 variant as a fallback', () {
      expect(EndpointNormalizer.chatCompletionsCandidates('api.openai.com'), [
        'https://api.openai.com/v1/chat/completions',
        'https://api.openai.com/chat/completions',
      ]);
    });

    test('a /v1 base offers the root variant as a fallback', () {
      expect(EndpointNormalizer.chatCompletionsCandidates('proxy.tld/v1'), [
        'https://proxy.tld/v1/chat/completions',
        'https://proxy.tld/chat/completions',
      ]);
    });

    test('an unusual base path is tried both with and without /v1', () {
      expect(
        EndpointNormalizer.chatCompletionsCandidates('proxy.tld/openai-compat'),
        [
          'https://proxy.tld/openai-compat/v1/chat/completions',
          'https://proxy.tld/openai-compat/chat/completions',
        ],
      );
    });

    test('the normalized URL always comes first', () {
      final candidates = EndpointNormalizer.modelsCandidates('api.openai.com');
      expect(candidates.first, 'https://api.openai.com/v1/models');
    });
  });
}
