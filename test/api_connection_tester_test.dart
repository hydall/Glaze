import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/services/api_connection_tester.dart';

class _FakeTransport implements ChatTransport {
  _FakeTransport({
    this.models = const [],
    this.responseText,
  });

  final List<Map<String, dynamic>> models;
  final String? responseText;
  ChatTransportRequest? lastRequest;

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async {
    return models;
  }

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    lastRequest = request;
    if (responseText != null) {
      onComplete?.call(responseText!, null);
    }
  }
}

void main() {
  group('ApiConnectionTester.testLlm', () {
    test('uses protocol-specific transport to verify listed model', () async {
      final transports = <String, _FakeTransport>{
        LlmProtocol.openai: _FakeTransport(),
        LlmProtocol.anthropic: _FakeTransport(
          models: const [
            {'id': 'claude-3-5-sonnet'},
          ],
        ),
      };

      final tester = ApiConnectionTester(
        pickTransport: (protocol) => transports[protocol]!,
      );

      final result = await tester.testLlm(
        endpoint: 'https://api.anthropic.com',
        apiKey: 'sk-ant-test',
        model: 'claude-3-5-sonnet',
        protocol: LlmProtocol.anthropic,
      );

      expect(result, isA<ApiTestSuccess>());
      expect(
        (result as ApiTestSuccess).message,
        'Connection successful! Model "claude-3-5-sonnet" found.',
      );
    });

    test('falls back to one-shot completion when model list is empty', () async {
      final transport = _FakeTransport(responseText: 'Hello');
      final tester = ApiConnectionTester(
        pickTransport: (_) => transport,
      );

      final result = await tester.testLlm(
        endpoint: '',
        apiKey: 'sk-or-test',
        model: 'anthropic/claude-3-5-sonnet',
        protocol: LlmProtocol.openrouter,
      );

      expect(result, isA<ApiTestSuccess>());
      expect((result as ApiTestSuccess).message, 'Connection successful!');
      expect(transport.lastRequest, isNotNull);
      expect(transport.lastRequest!.stream, isFalse);
      expect(transport.lastRequest!.messages, const [
        {'role': 'user', 'content': 'Hi'},
      ]);
    });

    test('invalid protocol falls back to openai transport', () async {
      final transports = <String, _FakeTransport>{
        LlmProtocol.openai: _FakeTransport(
          models: const [
            {'id': 'gpt-4o-mini'},
          ],
        ),
      };

      final picked = <String>[];
      final tester = ApiConnectionTester(
        pickTransport: (protocol) {
          picked.add(protocol);
          return transports[protocol]!;
        },
      );

      final result = await tester.testLlm(
        endpoint: 'https://api.openai.com',
        apiKey: 'sk-openai-test',
        model: 'gpt-4o-mini',
        protocol: 'unknown-provider',
      );

      expect(result, isA<ApiTestSuccess>());
      expect(picked, [LlmProtocol.openai]);
    });
  });
}
