import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/converters/prompt_post_processing.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/post_processing_chat_transport.dart';

/// Records the request it was handed instead of performing any I/O.
class _RecordingTransport implements ChatTransport {
  ChatTransportRequest? received;

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    received = request;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async => const [];
}

ChatTransportRequest _request({
  required String mode,
  List<Map<String, dynamic>>? messages,
  List<Map<String, dynamic>>? previousMessages,
  String? charName,
  String? userName,
}) => ChatTransportRequest(
  endpoint: 'https://example.test',
  apiKey: 'key',
  model: 'model',
  messages:
      messages ??
      [
        {'role': 'system', 'content': 'a'},
        {'role': 'system', 'content': 'b'},
        {'role': 'user', 'content': 'hi'},
      ],
  maxTokens: 100,
  temperature: 0.7,
  topP: 0.9,
  promptPostProcessing: mode,
  previousMessages: previousMessages,
  charName: charName,
  userName: userName,
);

void main() {
  test('none passes the request through untouched', () async {
    final inner = _RecordingTransport();
    final request = _request(mode: PromptPostProcessing.none);

    await PostProcessingChatTransport(inner).stream(request: request);

    expect(inner.received, same(request));
  });

  test('the wrapped transport sees the reshaped conversation', () async {
    final inner = _RecordingTransport();

    await PostProcessingChatTransport(
      inner,
    ).stream(request: _request(mode: PromptPostProcessing.merge));

    expect(inner.received!.messages, [
      {'role': 'system', 'content': 'a\n\nb'},
      {'role': 'user', 'content': 'hi'},
    ]);
  });

  test('previousMessages get the same pass, so cache hashes still line up', () {
    final processed = PostProcessingChatTransport.applyTo(
      _request(
        mode: PromptPostProcessing.merge,
        previousMessages: [
          {'role': 'system', 'content': 'a'},
          {'role': 'system', 'content': 'b'},
        ],
      ),
    );

    expect(processed.previousMessages, [
      {'role': 'system', 'content': 'a\n\nb'},
    ]);
  });

  test('single labels speakers in current and previous conversations', () {
    final processed = PostProcessingChatTransport.applyTo(
      _request(
        mode: PromptPostProcessing.single,
        charName: 'Helga',
        userName: 'Danvi',
        messages: [
          {'role': 'user', 'content': 'Current question'},
          {'role': 'assistant', 'content': 'Current answer'},
        ],
        previousMessages: [
          {'role': 'user', 'content': 'Earlier question'},
          {'role': 'assistant', 'content': 'Earlier answer'},
        ],
      ),
    );

    expect(processed.messages, [
      {
        'role': 'user',
        'content': 'Danvi: Current question\n\nHelga: Current answer',
      },
    ]);
    expect(processed.previousMessages, [
      {
        'role': 'user',
        'content': 'Danvi: Earlier question\n\nHelga: Earlier answer',
      },
    ]);
  });

  test('the processed request cannot be post-processed a second time', () {
    final processed = PostProcessingChatTransport.applyTo(
      _request(mode: PromptPostProcessing.merge),
    );

    expect(processed.promptPostProcessing, PromptPostProcessing.none);
    expect(PostProcessingChatTransport.applyTo(processed), same(processed));
  });

  test('every other request option survives the rewrite', () {
    final original = _request(mode: PromptPostProcessing.strict);
    final processed = PostProcessingChatTransport.applyTo(original);

    expect(processed.endpoint, original.endpoint);
    expect(processed.apiKey, original.apiKey);
    expect(processed.model, original.model);
    expect(processed.maxTokens, original.maxTokens);
    expect(processed.temperature, original.temperature);
    expect(processed.topP, original.topP);
    expect(processed.charName, original.charName);
    expect(processed.userName, original.userName);
  });
}
