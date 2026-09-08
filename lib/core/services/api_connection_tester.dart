import '../llm/embedding_service.dart';
import '../llm/transport/chat_transport.dart';
import '../llm/transport/chat_transport_request.dart';
import '../llm/transport/llm_protocol.dart';
import '../llm/transport/transport_factory.dart';

sealed class ApiTestResult {
  const ApiTestResult();
}

class ApiTestSuccess extends ApiTestResult {
  final String message;
  const ApiTestSuccess(this.message);
}

class ApiTestFailure extends ApiTestResult {
  final Object error;
  const ApiTestFailure(this.error);
}

class ApiConnectionTester {
  final ChatTransport Function(String protocol) _pickTransport;

  ApiConnectionTester({
    ChatTransport Function(String protocol)? pickTransport,
  }) : _pickTransport = pickTransport ?? pickChatTransport;

  Future<ApiTestResult> testLlm({
    required String endpoint,
    required String apiKey,
    required String model,
    String protocol = LlmProtocol.openai,
    bool useResponsesApi = false,
  }) async {
    try {
      final effectiveProtocol = _normalizedProtocol(protocol);
      final transport = _pickTransport(effectiveProtocol);
      final models = await transport.fetchModels(
        endpoint: endpoint,
        apiKey: apiKey,
      );
      if (models.isEmpty) {
        String? responseText;
        await transport.stream(
          request: ChatTransportRequest(
            endpoint: endpoint,
            apiKey: apiKey,
            model: model,
            messages: const [
              {'role': 'user', 'content': 'Hi'},
            ],
            maxTokens: 8,
            temperature: 0.0,
            topP: 1.0,
            topK: 0,
            frequencyPenalty: 0.0,
            presencePenalty: 0.0,
            stream: false,
            useResponsesApi: useResponsesApi,
          ),
          onComplete: (text, _, {rawResponseJson}) => responseText = text,
          onError: (e) => throw e,
        );
        if (responseText != null) {
          return const ApiTestSuccess('Connection successful!');
        }
        return const ApiTestFailure('No response from model');
      }
      if (model.isEmpty) {
        return const ApiTestSuccess('Connection successful!');
      }
      final exists = models.any((m) => m['id'] == model);
      return exists
          ? ApiTestSuccess('Connection successful! Model "$model" found.')
          : ApiTestSuccess('Connected, but "$model" not found.');
    } catch (e) {
      return ApiTestFailure(e);
    }
  }

  String _normalizedProtocol(String protocol) {
    return LlmProtocol.isValid(protocol) ? protocol : LlmProtocol.openai;
  }

  Future<ApiTestResult> testEmbedding({
    required String endpoint,
    required String apiKey,
    required String model,
    int maxChunkTokens = 64,
  }) async {
    try {
      final config = EmbeddingConfig(
        endpoint: endpoint,
        apiKey: apiKey,
        model: model,
        maxChunkTokens: maxChunkTokens,
      );
      final result = await EmbeddingService().getEmbeddings(['test'], config);
      if (result.isNotEmpty && result.first.isNotEmpty) {
        return ApiTestSuccess('Connected (dim: ${result.first.length})');
      }
      return const ApiTestFailure('Empty response from embedding API');
    } catch (e) {
      return ApiTestFailure(e);
    }
  }
}
