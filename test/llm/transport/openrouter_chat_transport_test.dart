import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/openai_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/openrouter_chat_transport.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';

ChatTransportRequest _req({
  String model = 'openai/gpt-4o',
  List<Map<String, dynamic>>? messages,
  String cacheControlTtl = 'off',
  String cacheBreakpointMode = 'depth',
  String sessionIdMode = 'openrouter',
  List<Map<String, dynamic>>? previousMessages,
  String endpoint = 'https://intentionally-ignored.example',
  int? receiveTimeoutMs,
  List<ExtraRequestParameter> extraRequestParameters = const [],
}) {
  return ChatTransportRequest(
    endpoint: endpoint,
    apiKey: 'sk-or-test',
    model: model,
    messages:
        messages ??
        [
          {'role': 'system', 'content': 'sys'},
          {'role': 'user', 'content': 'hi'},
        ],
    maxTokens: 4000,
    temperature: 0.7,
    topP: 0.9,
    stream: true,
    sessionId: 'sess-1',
    cacheControlTtl: cacheControlTtl,
    cacheBreakpointMode: cacheBreakpointMode,
    sessionIdMode: sessionIdMode,
    previousMessages: previousMessages,
    receiveTimeoutMs: receiveTimeoutMs,
    extraRequestParameters: extraRequestParameters,
  );
}

void main() {
  group('buildRouterRequest', () {
    test('endpoint is always overridden with OR base URL', () {
      final r = OpenRouterChatTransport.buildRouterRequest(_req());
      expect(r.endpoint, OpenRouterChatTransport.baseUrl);
    });

    test('preserves api key, model, messages, sampling params', () {
      final r = OpenRouterChatTransport.buildRouterRequest(
        _req(model: 'anthropic/claude-3-5-sonnet'),
      );
      expect(r.apiKey, 'sk-or-test');
      expect(r.model, 'anthropic/claude-3-5-sonnet');
      expect(r.temperature, 0.7);
      expect(r.topP, 0.9);
      expect(r.maxTokens, 4000);
    });

    test(
      'strips cacheControlTtl to off (markers applied to message parts)',
      () {
        final r = OpenRouterChatTransport.buildRouterRequest(
          _req(model: 'anthropic/claude-3-5-sonnet', cacheControlTtl: '5min'),
        );
        expect(r.cacheControlTtl, 'off');
      },
    );

    test('keeps session_id for OpenRouter sticky routing', () {
      final r = OpenRouterChatTransport.buildRouterRequest(
        _req(model: 'anthropic/claude-3-5-sonnet', cacheControlTtl: '5min'),
      );
      final body = OpenAiChatTransport.buildBody(r);

      expect(body['session_id'], 'sess-1');
    });

    test('preserves per-request receive timeout', () {
      final r = OpenRouterChatTransport.buildRouterRequest(
        _req(receiveTimeoutMs: 0),
      );

      expect(r.receiveTimeoutMs, 0);
    });

    test('preserves extra request parameters', () {
      final r = OpenRouterChatTransport.buildRouterRequest(
        _req(
          extraRequestParameters: const [
            ExtraRequestParameter(key: 'reasoning_effort', value: 'xhigh'),
          ],
        ),
      );

      expect(r.extraRequestParameters.single.key, 'reasoning_effort');
      expect(OpenAiChatTransport.buildBody(r)['reasoning_effort'], 'xhigh');
    });
  });

  group('cache_control on Claude-via-OR', () {
    test('5min on Claude adds ephemeral marker on system + deep message', () {
      final r = OpenRouterChatTransport.buildRouterRequest(
        _req(
          model: 'anthropic/claude-3-5-sonnet',
          cacheControlTtl: '5min',
          messages: [
            {'role': 'system', 'content': 'sys'},
            {'role': 'user', 'content': 'u1'},
            {'role': 'assistant', 'content': 'a1'},
            {'role': 'user', 'content': 'u2'},
            {'role': 'assistant', 'content': ''}, // prefill, skipped
          ],
        ),
      );
      // System message: content wrapped into a list with cache_control.
      final sys = r.messages.firstWhere((m) => m['role'] == 'system');
      expect(sys['content'], isA<List<dynamic>>());
      final parts = sys['content'] as List;
      expect(parts.last['cache_control']?['type'], 'ephemeral');

      // Deep user message also gets a cache_control marker.
      final users = r.messages.where((m) => m['role'] == 'user').toList();
      final marker = users
          .expand<dynamic>((u) {
            final c = u['content'];
            if (c is List) return c;
            return const [];
          })
          .any((p) => p is Map && p.containsKey('cache_control'));
      expect(marker, isTrue);
    });

    test('off on Claude leaves messages untouched', () {
      final r = OpenRouterChatTransport.buildRouterRequest(
        _req(model: 'anthropic/claude-3-5-sonnet', cacheControlTtl: 'off'),
      );
      final sys = r.messages.firstWhere((m) => m['role'] == 'system');
      // String content preserved — no wrapping.
      expect(sys['content'], isA<String>());
    });

    test('5min on non-Claude → no markers', () {
      final r = OpenRouterChatTransport.buildRouterRequest(
        _req(model: 'openai/gpt-4o', cacheControlTtl: '5min'),
      );
      final sys = r.messages.firstWhere((m) => m['role'] == 'system');
      // Non-Claude untouched.
      expect(sys['content'], isA<String>());
    });

    test('stable_prefix marks last matching content part', () {
      final r = OpenRouterChatTransport.buildRouterRequest(
        _req(
          model: 'anthropic/claude-3-5-sonnet',
          cacheControlTtl: '5min',
          cacheBreakpointMode: 'stable_prefix',
          previousMessages: [
            {'role': 'system', 'content': 'sys'},
            {'role': 'user', 'content': 'u1'},
            {'role': 'assistant', 'content': 'a1'},
            {'role': 'user', 'content': 'u2'},
            {'role': 'assistant', 'content': 'volatile-old'},
          ],
          messages: [
            {'role': 'system', 'content': 'sys'},
            {'role': 'user', 'content': 'u1'},
            {'role': 'assistant', 'content': 'a1'},
            {'role': 'user', 'content': 'u2'},
            {'role': 'assistant', 'content': 'volatile-new'},
            {'role': 'user', 'content': 'u3'},
          ],
        ),
      );

      final marked = r.messages
          .expand<dynamic>((m) {
            final c = m['content'];
            return c is List ? c : const [];
          })
          .where((p) => p is Map && p.containsKey('cache_control'));

      expect(marked, hasLength(2));
      expect(marked.last['text'], 'u2');
    });
  });

  group('extraHeaders metadata', () {
    test('exposes HTTP-Referer + X-Title', () {
      final h = OpenRouterChatTransport.extraHeaders;
      expect(h, containsPair('HTTP-Referer', OpenRouterChatTransport.referer));
      expect(h, containsPair('X-Title', OpenRouterChatTransport.title));
    });
  });
}
