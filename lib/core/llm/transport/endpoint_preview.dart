import 'endpoint_normalizer.dart';
import 'llm_protocol.dart';

/// What the endpoint field resolves to, ready to show under the input.
class EndpointPreview {
  /// The URL a request would be sent to, or an empty string when the input
  /// cannot be parsed as a URL.
  final String url;

  /// True when the input is not a usable URL at all.
  final bool isInvalid;

  const EndpointPreview({required this.url, required this.isInvalid});

  static const EndpointPreview none = EndpointPreview(
    url: '',
    isInvalid: false,
  );

  bool get isEmpty => url.isEmpty && !isInvalid;

  /// Resolves what [rawEndpoint] will actually call for [protocol], so the
  /// settings UI can show it before the user hits send. Mirrors exactly what
  /// the transports build — both go through [EndpointNormalizer].
  static EndpointPreview resolve({
    required String rawEndpoint,
    required String protocol,
    bool useResponsesApi = false,
    String model = '',
  }) {
    if (protocol == LlmProtocol.openrouter) {
      return const EndpointPreview(
        url: 'https://openrouter.ai/api/v1/chat/completions',
        isInvalid: false,
      );
    }
    if (rawEndpoint.trim().isEmpty) return none;

    if (protocol == LlmProtocol.gemini) {
      final base = EndpointNormalizer.geminiBase(rawEndpoint);
      if (base.isEmpty) return const EndpointPreview(url: '', isInvalid: true);
      final name = model.trim().isEmpty ? '{model}' : model.trim();
      return EndpointPreview(
        url: '$base/v1beta/models/$name:streamGenerateContent',
        isInvalid: false,
      );
    }

    final url = switch (protocol) {
      LlmProtocol.anthropic => EndpointNormalizer.messagesUrl(rawEndpoint),
      LlmProtocol.openaiResponses => EndpointNormalizer.responsesUrl(
        rawEndpoint,
      ),
      _ => useResponsesApi
          ? EndpointNormalizer.responsesUrl(rawEndpoint)
          : EndpointNormalizer.chatCompletionsUrl(rawEndpoint),
    };
    return EndpointPreview(url: url, isInvalid: url.isEmpty);
  }

  /// The embeddings URL for the vector endpoint field.
  static EndpointPreview resolveEmbedding(String rawEndpoint) {
    if (rawEndpoint.trim().isEmpty) return none;
    final url = EndpointNormalizer.embeddingsUrl(rawEndpoint);
    return EndpointPreview(url: url, isInvalid: url.isEmpty);
  }
}
