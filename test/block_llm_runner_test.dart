import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/block_llm_runner.dart';

typedef _StreamHandler =
    Future<void> Function({
      required ChatTransportRequest request,
      required CancelToken? cancelToken,
      required ChatTransportOnUpdate? onUpdate,
      required ChatTransportOnComplete? onComplete,
      required ChatTransportOnError? onError,
    });

class _FakeTransport implements ChatTransport {
  _FakeTransport(this.handler);

  final _StreamHandler handler;
  ChatTransportRequest? lastRequest;

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) {
    lastRequest = request;
    return handler(
      request: request,
      cancelToken: cancelToken,
      onUpdate: onUpdate,
      onComplete: onComplete,
      onError: onError,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async => const [];
}

/// A connection whose reader set a short first-chunk timeout. The point of the
/// tests is that this number is the deadline — before, an ext block ignored it
/// and inherited whatever ceiling its transport's Dio instance carried.
const _config = ApiConfig(
  id: 'api',
  name: 'test',
  endpoint: 'https://example.test',
  apiKey: 'key',
  model: 'model',
  protocol: 'openai',
  firstChunkTimeoutMs: 60,
);

const _messages = [
  {'role': 'user', 'content': 'fill the block'},
];

void main() {
  group('BlockLlmRunner first-chunk deadline', () {
    test('a provider that accepts and then goes silent fails the block', () async {
      // The provider opened the connection and never sent anything. Without a
      // deadline of its own the block sat on a future nobody completed.
      final transport = _FakeTransport(({
        required request,
        required cancelToken,
        required onUpdate,
        required onComplete,
        required onError,
      }) async {
        final silence = Completer<void>();
        unawaited(
          cancelToken!.whenCancel.then((_) {
            if (!silence.isCompleted) silence.complete();
          }),
        );
        await silence.future;
      });

      await expectLater(
        BlockLlmRunner(transportPicker: (_) => transport).run(
          apiConfig: _config,
          messages: _messages,
          stream: false,
        ),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            contains('60ms'),
          ),
        ),
      );
    });

    test('the deadline replaces the transport ceiling, not adds to it', () async {
      final transport = _FakeTransport(({
        required request,
        required cancelToken,
        required onUpdate,
        required onComplete,
        required onError,
      }) async {
        onComplete!('done', null, rawResponseJson: null);
      });

      await BlockLlmRunner(transportPicker: (_) => transport).run(
        apiConfig: _config,
        messages: _messages,
        stream: false,
      );

      // 0 disables Dio's own receive timeout, so the guard above is the only
      // deadline. Left at the transport default a non-streaming block died at
      // 120s (180s on Anthropic/Gemini) whatever the reader configured.
      expect(transport.lastRequest!.receiveTimeoutMs, 0);
    });

    test('a first chunk keeps a slow reply alive past the deadline', () async {
      final transport = _FakeTransport(({
        required request,
        required cancelToken,
        required onUpdate,
        required onComplete,
        required onError,
      }) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        onUpdate!('the ', null);
        // Well past the 60ms first-chunk deadline: a reply that is progressing
        // must never be cut off mid-stream.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        onUpdate('ledger', null);
        onComplete!('the ledger', null, rawResponseJson: null);
      });

      final streamed = <String>[];
      final text = await BlockLlmRunner(transportPicker: (_) => transport).run(
        apiConfig: _config,
        messages: _messages,
        stream: true,
        onStreamUpdate: streamed.add,
      );

      expect(text, 'the ledger');
      expect(streamed, ['the ', 'the ledger']);
    });

    test('reasoning-only output counts as a sign of life', () async {
      final transport = _FakeTransport(({
        required request,
        required cancelToken,
        required onUpdate,
        required onComplete,
        required onError,
      }) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        // A thinking model emits reasoning long before any visible text.
        onUpdate!('', 'considering the scene');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        onComplete!('finally', null, rawResponseJson: null);
      });

      final text = await BlockLlmRunner(transportPicker: (_) => transport).run(
        apiConfig: _config,
        messages: _messages,
        stream: false,
      );

      expect(text, 'finally');
    });

    test('the reader pressing stop is not a failure', () async {
      final token = CancelToken();
      final transport = _FakeTransport(({
        required request,
        required cancelToken,
        required onUpdate,
        required onComplete,
        required onError,
      }) async {
        token.cancel('stopped');
        // The caller's cancellation is forwarded to the request token, which
        // is what a real transport reports back as a cancel.
        await cancelToken!.whenCancel;
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(path: '/chat/completions'),
          reason: 'stopped',
        );
      });

      final text = await BlockLlmRunner(transportPicker: (_) => transport).run(
        apiConfig: _config,
        messages: _messages,
        stream: false,
        cancelToken: token,
      );

      expect(text, isNull);
    });

    test('a transport that ends without a callback does not hang', () async {
      final transport = _FakeTransport(({
        required request,
        required cancelToken,
        required onUpdate,
        required onComplete,
        required onError,
      }) async {});

      await expectLater(
        BlockLlmRunner(transportPicker: (_) => transport).run(
          apiConfig: _config,
          messages: _messages,
          stream: false,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
