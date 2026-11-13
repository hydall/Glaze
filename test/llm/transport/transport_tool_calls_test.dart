import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/tools/llm_tool_call.dart';
import 'package:glaze_flutter/core/llm/transport/anthropic_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/openai_chat_transport.dart';

import '_sse_adapter.dart';

const _parameters = {
  'type': 'object',
  'properties': {
    'id': {'type': 'string'},
  },
};

const _tools = [
  {
    'type': 'function',
    'function': {
      'name': 'glaze_get_character',
      'description': 'Read a card.',
      'parameters': _parameters,
    },
  },
];

ChatTransportRequest _req({
  required String endpoint,
  List<Map<String, dynamic>>? tools,
  String? toolChoice,
}) => ChatTransportRequest(
  endpoint: endpoint,
  apiKey: 'key',
  model: 'model',
  messages: const [
    {'role': 'user', 'content': 'hi'},
  ],
  maxTokens: 500,
  temperature: 1,
  topP: 1,
  stream: true,
  tools: tools,
  toolChoice: toolChoice,
);

void main() {
  group('Anthropic', () {
    test('sends tools as name / description / input_schema', () {
      final built = AnthropicChatTransport.buildRequest(
        _req(
          endpoint: 'https://api.anthropic.com/v1/messages',
          tools: _tools,
          toolChoice: 'none',
        ),
      );
      expect(built.body['tools'], [
        {
          'name': 'glaze_get_character',
          'description': 'Read a card.',
          'input_schema': _parameters,
        },
      ]);
      expect(built.body['tool_choice'], {'type': 'none'});
    });

    test('sends no tools when none are given', () {
      final built = AnthropicChatTransport.buildRequest(
        _req(endpoint: 'https://api.anthropic.com/v1/messages'),
      );
      expect(built.body.containsKey('tools'), isFalse);
      expect(built.body.containsKey('tool_choice'), isFalse);
    });

    test('a streamed tool_use lands in the raw response, signature kept', () async {
      final body = [
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}',
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"plan"}}',
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}',
        'data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}',
        'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Checking."}}',
        'data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"glaze_get_character","input":{}}}',
        'data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"id\\":"}}',
        'data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\\"c1\\"}"}}',
        'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}',
        'data: {"type":"message_stop"}',
        '',
      ].join('\n');
      final transport = AnthropicChatTransport(
        dio: Dio()..httpClientAdapter = SseAdapter(body, chunkSizes: [40, 90]),
      );
      String? raw;
      String? text;
      await transport.stream(
        request: _req(
          endpoint: 'https://api.anthropic.com/v1/messages',
          tools: _tools,
        ),
        onComplete: (t, r, {rawResponseJson}) {
          text = t;
          raw = rawResponseJson;
        },
        onError: (e) => fail('unexpected error: $e'),
      );
      expect(text, 'Checking.');
      final turn = parseToolTurn(raw);
      expect(turn, isNotNull);
      expect(turn!.calls.single.id, 'toolu_1');
      expect(turn.calls.single.arguments, {'id': 'c1'});
      expect(turn.thinkingBlocks.single, {
        'type': 'thinking',
        'thinking': 'plan',
        'signature': 'sig',
      });
    });
  });

  group('OpenAI Chat Completions', () {
    test('assembles tool_calls fragments by index', () {
      final calls = StreamedToolCalls()
        ..consume([
          {
            'index': 0,
            'id': 'call_a',
            'type': 'function',
            'function': {'name': 'glaze_list_characters', 'arguments': ''},
          },
          {
            'index': 1,
            'id': 'call_b',
            'function': {'name': 'glaze_get_character', 'arguments': '{"id"'},
          },
        ])
        ..consume([
          {
            'index': 0,
            'function': {'arguments': '{"query":"a"}'},
          },
          {
            'index': 1,
            // A proxy that repeats the name must not double it.
            'function': {'name': 'glaze_get_character', 'arguments': ':"c1"}'},
          },
        ]);
      expect(calls.toJson(), [
        {
          'id': 'call_a',
          'type': 'function',
          'function': {
            'name': 'glaze_list_characters',
            'arguments': '{"query":"a"}',
          },
        },
        {
          'id': 'call_b',
          'type': 'function',
          'function': {
            'name': 'glaze_get_character',
            'arguments': '{"id":"c1"}',
          },
        },
      ]);
    });

    test('a tool-only stream completes with the calls in the raw response', () async {
      final body = [
        'data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"glaze_get_character","arguments":""}}]}}]}',
        'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"id\\":\\"c1\\"}"}}]}}]}',
        'data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}',
        'data: [DONE]',
        '',
      ].join('\n');
      final transport = OpenAiChatTransport(
        dio: Dio()..httpClientAdapter = SseAdapter(body),
      );
      String? raw;
      await transport.stream(
        request: _req(
          endpoint: 'https://api.openai.com/v1/chat/completions',
          tools: _tools,
        ),
        onComplete: (t, r, {rawResponseJson}) => raw = rawResponseJson,
        onError: (e) => fail('unexpected error: $e'),
      );
      final turn = parseToolTurn(raw);
      expect(turn!.calls.single.name, 'glaze_get_character');
      expect(turn.calls.single.arguments, {'id': 'c1'});
    });

    test('sends tools and tool_choice', () {
      final body = OpenAiChatTransport.buildBody(
        _req(
          endpoint: 'https://api.openai.com/v1/chat/completions',
          tools: _tools,
        ),
      );
      expect(body['tools'], _tools);
      expect(body['tool_choice'], 'auto');
    });
  });
}
