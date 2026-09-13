import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';

/// Records the request an aux call actually sends. Every auxiliary call — the
/// summary, the Studio cleaner, the Ledger, the JAR lorebook rebuild — pins its
/// own temperature, which is fine until the connection is one that rejects the
/// parameter outright (OpenAI's reasoning models, several proxies). The chat
/// sends those configs no `temperature` at all; an aux call that dropped the
/// flag sent one and got HTTP 400 on a connection that otherwise works.
class _RecordingTransport implements ChatTransport {
  ChatTransportRequest? request;

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    this.request = request;
    onComplete?.call('ok', null, rawResponseJson: null);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async => const [];
}

AuxApiConfig _config({required bool omitTemperature}) => AuxApiConfig(
  endpoint: 'https://example.test',
  apiKey: 'key',
  model: 'model',
  protocol: 'openai',
  omitTemperature: omitTemperature,
);

void main() {
  group('aux calls honour the connection temperature flag', () {
    test('omitTemperature travels into the request', () async {
      final transport = _RecordingTransport();
      final client = AuxLlmClient(transportPicker: (_) => transport);

      final text = await client.callOnce(
        config: _config(omitTemperature: true),
        prompt: 'summarize this',
        maxTokens: 512,
        temperature: 0.3,
        timeoutMs: 5000,
      );

      expect(text, 'ok');
      expect(transport.request!.omitTemperature, isTrue);
      // The pinned value still travels — the flag decides whether it is sent,
      // so a connection that accepts temperature keeps getting the aux value.
      expect(transport.request!.temperature, 0.3);
    });

    test('a connection without the flag still sends its temperature', () async {
      final transport = _RecordingTransport();
      final client = AuxLlmClient(transportPicker: (_) => transport);

      await client.callOnce(
        config: _config(omitTemperature: false),
        prompt: 'summarize this',
        maxTokens: 512,
        temperature: 0.3,
        timeoutMs: 5000,
      );

      expect(transport.request!.omitTemperature, isFalse);
      expect(transport.request!.temperature, 0.3);
    });
  });
}
