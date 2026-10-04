import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/aux_retry_runner.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/llm/transport/llm_call_event.dart';

const _config = AuxApiConfig(
  endpoint: 'https://example.test',
  apiKey: 'key',
  model: 'model',
  protocol: 'fake',
);

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

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) => handler(
    request: request,
    cancelToken: cancelToken,
    onUpdate: onUpdate,
    onComplete: onComplete,
    onError: onError,
  );

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async => const [];
}

class _CallEventSink implements LlmCallEventSink {
  final events = <LlmCallEvent>[];

  @override
  void recordCallEvent(LlmCallEvent event) => events.add(event);
}

void main() {
  tearDown(() => LlmCallEventCapture.sink = null);

  group('AuxLlmClient attempt transport lifetime', () {
    test(
      'idle timeout cancels and drains before retry; late completion ignored',
      () async {
        var starts = 0;
        var active = 0;
        var maxActive = 0;
        var firstCancelled = false;
        var firstDrained = false;
        final transport = _FakeTransport(({
          required request,
          required cancelToken,
          required onUpdate,
          required onComplete,
          required onError,
        }) async {
          starts++;
          active++;
          if (active > maxActive) maxActive = active;
          if (starts == 1) {
            await cancelToken!.whenCancel;
            firstCancelled = true;
            // Model a transport that needs asynchronous cleanup after Dio cancel.
            await Future<void>.delayed(const Duration(milliseconds: 15));
            firstDrained = true;
            active--;
            // A misbehaving transport callback during termination must not win.
            onComplete?.call('stale', null);
            return;
          }
          expect(firstCancelled, isTrue);
          expect(firstDrained, isTrue);
          onComplete?.call('fresh', null);
          active--;
        });
        final client = AuxLlmClient(
          transportPicker: (_) => transport,
          retryPolicy: const AuxRetryPolicy(
            maxAttempts: 2,
            backoffDelays: [Duration.zero],
          ),
        );

        final outcome = await client.callOnceWithLog(
          config: _config,
          prompt: 'hello',
          maxTokens: 10,
          temperature: 0.2,
          timeoutMs: 5,
        );

        expect(outcome.text, 'fresh');
        expect(outcome.attempts.map((a) => a.status), ['timeout', 'ok']);
        expect(maxActive, 1);
      },
    );

    test('parent cancellation reaches per-attempt child token', () async {
      final parent = CancelToken();
      CancelToken? transportToken;
      final transport = _FakeTransport(({
        required request,
        required cancelToken,
        required onUpdate,
        required onComplete,
        required onError,
      }) async {
        transportToken = cancelToken;
        await cancelToken!.whenCancel;
      });
      final client = AuxLlmClient(transportPicker: (_) => transport);
      final future = client.callOnceWithLog(
        config: _config,
        prompt: 'hello',
        maxTokens: 10,
        temperature: 0.2,
        timeoutMs: 1000,
        cancelToken: parent,
      );

      await Future<void>.delayed(Duration.zero);
      parent.cancel('user cancelled');
      final outcome = await future;

      expect(transportToken, isNot(same(parent)));
      expect(transportToken!.isCancelled, isTrue);
      expect(outcome.status.name, 'aborted');
    });

    test(
      'configured timeout is propagated for one-shot and stream requests',
      () async {
        final requests = <ChatTransportRequest>[];
        final transport = _FakeTransport(({
          required request,
          required cancelToken,
          required onUpdate,
          required onComplete,
          required onError,
        }) async {
          requests.add(request);
          onComplete?.call('ok', null);
        });
        final client = AuxLlmClient(transportPicker: (_) => transport);

        await client.callOnceWithLog(
          config: _config,
          prompt: 'one',
          maxTokens: 10,
          temperature: 0.2,
          timeoutMs: 1234,
        );
        await client.callStreamWithLog(
          config: _config,
          prompt: 'stream',
          maxTokens: 10,
          temperature: 0.2,
          timeoutMs: 5678,
        );

        expect(requests.map((r) => r.receiveTimeoutMs), [1234, 5678]);
        expect(requests.map((r) => r.stream), [false, true]);
      },
    );

    test('stream timeout blocks late chunks before retry', () async {
      var starts = 0;
      final chunks = <String>[];
      final transport = _FakeTransport(({
        required request,
        required cancelToken,
        required onUpdate,
        required onComplete,
        required onError,
      }) async {
        starts++;
        if (starts == 1) {
          await cancelToken!.whenCancel;
          onUpdate?.call('stale', null);
          return;
        }
        onUpdate?.call('new', null);
        onComplete?.call('new', null);
      });
      final client = AuxLlmClient(
        transportPicker: (_) => transport,
        retryPolicy: const AuxRetryPolicy(
          maxAttempts: 2,
          backoffDelays: [Duration.zero],
        ),
      );

      final outcome = await client.callStreamWithLog(
        config: _config,
        prompt: 'stream',
        maxTokens: 10,
        temperature: 0.2,
        timeoutMs: 5,
        onChunk: chunks.add,
      );

      expect(outcome.text, 'new');
      expect(chunks, ['new']);
    });

    test('capture context tracks individual retry attempts', () async {
      final contexts = <LlmCaptureContext?>[];
      final sink = _CallEventSink();
      LlmCallEventCapture.sink = sink;
      var starts = 0;
      final transport = _FakeTransport(({
        required request,
        required cancelToken,
        required onUpdate,
        required onComplete,
        required onError,
      }) async {
        contexts.add(request.captureContext);
        starts++;
        if (starts == 1) {
          throw DioException(
            requestOptions: RequestOptions(path: ''),
            response: Response(
              requestOptions: RequestOptions(path: ''),
              statusCode: 503,
            ),
            type: DioExceptionType.badResponse,
          );
        }
        onComplete?.call('ok', null);
      });
      final client = AuxLlmClient(
        transportPicker: (_) => transport,
        retryPolicy: const AuxRetryPolicy(
          maxAttempts: 2,
          backoffDelays: [Duration.zero],
        ),
      );

      final outcome = await client.callOnceWithLog(
        config: _config,
        prompt: 'hello',
        maxTokens: 10,
        temperature: 0.2,
        timeoutMs: 1000,
        captureContext: const LlmCaptureContext(
          stage: 'card.writer',
          sessionId: 'session',
          logicalCallId: 'call',
        ),
      );

      expect(outcome.text, 'ok');
      expect(contexts.map((context) => context?.attempt), [1, 2]);
      expect(contexts.map((context) => context?.stage), [
        'card.writer',
        'card.writer',
      ]);
      expect(contexts.map((context) => context?.callId).toSet(), hasLength(1));
      expect(outcome.captureContext?.callId, contexts.first?.callId);
      expect(sink.events.map((event) => event.kind), [
        'transport_failed',
        'transport_succeeded',
      ]);
      expect(sink.events.map((event) => event.context.attempt), [1, 2]);
      expect(sink.events.last.responseText, 'ok');
    });
  });

  test('attempt startedAtMs is captured before attempt work', () async {
    final before = DateTime.now().millisecondsSinceEpoch;
    final outcome = await const AuxRetryRunner().run(
      attempt: (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return 'ok';
      },
    );
    final after = DateTime.now().millisecondsSinceEpoch;

    expect(
      outcome.attempts.single.startedAtMs,
      inInclusiveRange(before, after),
    );
    expect(outcome.attempts.single.startedAtMs, lessThanOrEqualTo(after - 10));
  });
}
