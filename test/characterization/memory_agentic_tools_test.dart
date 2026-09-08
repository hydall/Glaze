import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/memory_agentic_policy.dart';
import 'package:glaze_flutter/core/llm/memory_agentic_tools.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';

void main() {
  group('MemoryAgenticToolDefinition', () {
    test('searchMemory returns a valid OpenAI tool definition', () {
      final tool = MemoryAgenticToolDefinition.searchMemory();
      expect(tool['type'], 'function');
      expect(tool['function']['name'], 'searchMemory');
      expect(
        tool['function']['parameters']['properties']['query']['type'],
        'string',
      );
    });

    test('forPolicy exposes only searchMemory when enabled', () {
      const policy = MemoryAgenticPolicy(MemoryAgenticSettings(enabled: true));
      final tools = MemoryAgenticToolDefinition.forPolicy(policy);
      expect(tools, hasLength(1));
      expect(tools.first['function']['name'], 'searchMemory');
    });

    test('forPolicy is empty when disabled', () {
      const policy = MemoryAgenticPolicy(MemoryAgenticSettings(enabled: false));
      expect(MemoryAgenticToolDefinition.forPolicy(policy), isEmpty);
    });
  });

  group('MemoryAgenticToolHandler', () {
    test('denies search when the policy is disabled', () {
      const handler = MemoryAgenticToolHandler(
        MemoryAgenticPolicy(MemoryAgenticSettings(enabled: false)),
      );
      final result = handler.searchMemory(
        entries: const [],
        query: 'test',
        visibleMessageIds: const {},
      );
      expect(result.error, 'agentic_disabled');
      expect(result.hits, isEmpty);
    });

    test('returns matching entries without full content', () {
      const handler = MemoryAgenticToolHandler(
        MemoryAgenticPolicy(MemoryAgenticSettings(enabled: true)),
      );
      final result = handler.searchMemory(
        entries: const [
          MemoryEntry(
            id: 'm1',
            title: 'Bridge collapse',
            content: 'The bridge collapsed into the river',
            keys: ['bridge', 'river'],
          ),
        ],
        query: 'bridge',
        visibleMessageIds: const {},
        keywordMatchedTerms: const {
          'm1': ['bridge'],
        },
      );
      expect(result.hits, hasLength(1));
      expect(result.hits.first.entryId, 'm1');
      expect(result.hits.first.toJson().containsKey('content'), isFalse);
    });
  });
}
