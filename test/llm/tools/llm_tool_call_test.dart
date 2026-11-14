import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/converters/claude_messages.dart';
import 'package:glaze_flutter/core/llm/tools/llm_tool_call.dart';

void main() {
  group('parseToolTurn', () {
    test('reads Chat Completions tool_calls', () {
      final turn = parseToolTurn(
        jsonEncode({
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': 'Creating.',
                'tool_calls': [
                  {
                    'id': 'call_1',
                    'type': 'function',
                    'function': {
                      'name': 'glaze_create_character',
                      'arguments': '{"character":{"name":"Ann"}}',
                    },
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        }),
      );
      expect(turn, isNotNull);
      expect(turn!.calls.single.id, 'call_1');
      expect(turn.calls.single.name, 'glaze_create_character');
      expect(turn.calls.single.arguments, {
        'character': {'name': 'Ann'},
      });
      expect(turn.thinkingBlocks, isEmpty);
    });

    test('reads Anthropic tool_use blocks and keeps signed thinking', () {
      final turn = parseToolTurn(
        jsonEncode({
          'type': 'message',
          'content': [
            {'type': 'thinking', 'thinking': 'hmm', 'signature': 'sig'},
            {'type': 'text', 'text': ''},
            {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'glaze_get_character',
              'input': {'id': 'c1'},
            },
          ],
        }),
      );
      expect(turn!.calls.single.id, 'toolu_1');
      expect(turn.calls.single.arguments, {'id': 'c1'});
      expect(turn.thinkingBlocks.single['signature'], 'sig');
    });

    test('is null for a plain text reply or a non-JSON body', () {
      expect(
        parseToolTurn(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'hi'},
              },
            ],
          }),
        ),
        isNull,
      );
      expect(parseToolTurn('not json'), isNull);
      expect(parseToolTurn(null), isNull);
    });

    test('malformed arguments decode to null instead of throwing', () {
      const call = LlmToolCall(id: 'a', name: 'x', rawArguments: '{"broken"');
      expect(call.arguments, isNull);
      const empty = LlmToolCall(id: 'a', name: 'x', rawArguments: '');
      expect(empty.arguments, isEmpty);
    });
  });

  group('tool follow-up through the Claude converter', () {
    const turn = LlmToolTurn(
      calls: [
        LlmToolCall(
          id: 'toolu_1',
          name: 'glaze_list_characters',
          rawArguments: '{"query":"ann"}',
        ),
        LlmToolCall(
          id: 'toolu_2',
          name: 'glaze_get_character',
          rawArguments: '{}',
        ),
      ],
      thinkingBlocks: [
        {'type': 'thinking', 'thinking': 'plan', 'signature': 'sig'},
      ],
    );

    List<Map<String, dynamic>> conversation() => [
      {'role': 'system', 'content': 'sys'},
      {'role': 'user', 'content': 'make a character'},
      ...toolFollowUpMessages(
        assistantText: 'Let me check.',
        turn: turn,
        results: {'toolu_1': '{"ok":true}', 'toolu_2': '{"ok":false}'},
      ),
    ];

    test('the follow-up is Chat Completions shaped', () {
      final tail = conversation().sublist(2);
      expect(tail[0]['role'], 'assistant');
      expect((tail[0]['tool_calls'] as List).length, 2);
      expect(tail[1], {
        'role': 'tool',
        'tool_call_id': 'toolu_1',
        'content': '{"ok":true}',
      });
      expect(tail[2]['tool_call_id'], 'toolu_2');
    });

    test('becomes thinking + text + tool_use, then one user turn of results', () {
      final converted = convertClaudeMessages(conversation()).messages;
      expect(converted.length, 3);

      final assistant = converted[1];
      expect(assistant['role'], 'assistant');
      final blocks = (assistant['content'] as List).cast<Map<dynamic, dynamic>>();
      expect(blocks.map((b) => b['type']), [
        'thinking',
        'text',
        'tool_use',
        'tool_use',
      ]);
      expect(blocks[0]['signature'], 'sig');
      expect(blocks[2]['input'], {'query': 'ann'});
      expect(assistant.containsKey('tool_calls'), isFalse);
      expect(assistant.containsKey('thinking_blocks'), isFalse);

      final results = converted[2];
      expect(results['role'], 'user');
      expect((results['content'] as List).cast<Map<dynamic, dynamic>>().map((b) => b['type']), [
        'tool_result',
        'tool_result',
      ]);
      expect((results['content'] as List).first['tool_use_id'], 'toolu_1');
    });

    test('a tool-call turn is not mistaken for a prefill', () {
      final result = convertClaudeMessages(conversation());
      expect(result.prefill, isNull);
    });
  });
}
