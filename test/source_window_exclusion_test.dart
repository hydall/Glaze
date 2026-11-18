import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/prompt_builder.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';

PromptPayload _payloadWith({
  List<RecalledMessageChunk>? chunks,
  Set<String>? sourceWindowVisibleMessageIds,
  String? recalledMessagesContent,
  bool disableSourceWindowExclusion = false,
}) => PromptPayload(
  character: const Character(id: 'c1', name: 'Test'),
  history: const [],
  apiConfig: const ApiConfig(id: 'a1'),
  recalledMessageChunks: chunks ?? const [],
  sourceWindowVisibleMessageIds: sourceWindowVisibleMessageIds ?? const {},
  recalledMessagesContent: recalledMessagesContent,
  disableSourceWindowExclusion: disableSourceWindowExclusion,
);

void main() {
  group('effectiveRecalledMessagesContent', () {
    test('frames legacy recalledMessagesContent when no chunks exist', () {
      final payload = _payloadWith(
        recalledMessagesContent: '<recalled>old style</recalled>',
      );
      expect(
        effectiveRecalledMessagesContent(payload),
        contains('<recalled>old style</recalled>'),
      );
      expect(
        effectiveRecalledMessagesContent(payload),
        contains('Historical evidence, not current state'),
      );
    });

    test('returns null when both chunks and raw content are empty', () {
      final payload = _payloadWith();
      expect(effectiveRecalledMessagesContent(payload), isNull);
    });

    test('includes all chunks when sourceWindowVisibleMessageIds is empty', () {
      final payload = _payloadWith(
        chunks: [
          const RecalledMessageChunk(text: 'chunk a', messageIds: ['m1']),
          const RecalledMessageChunk(text: 'chunk b', messageIds: ['m2']),
        ],
      );
      final result = effectiveRecalledMessagesContent(payload)!;
      expect(result, contains('chunk a'));
      expect(result, contains('chunk b'));
    });

    test('excludes chunk whose messageId is in the visible window', () {
      final payload = _payloadWith(
        chunks: [
          const RecalledMessageChunk(text: 'visible chunk', messageIds: ['m1']),
          const RecalledMessageChunk(text: 'hidden chunk', messageIds: ['m2']),
        ],
        sourceWindowVisibleMessageIds: {'m1', 'm3'},
      );
      final result = effectiveRecalledMessagesContent(payload)!;
      expect(result, isNot(contains('visible chunk')));
      expect(result, contains('hidden chunk'));
    });

    test('uses explicit visibleMessageIds override when provided', () {
      final payload = _payloadWith(
        chunks: [
          const RecalledMessageChunk(text: 'visible chunk', messageIds: ['m1']),
          const RecalledMessageChunk(text: 'hidden chunk', messageIds: ['m2']),
        ],
      );
      final result = effectiveRecalledMessagesContent(
        payload,
        visibleMessageIds: {'m1'},
      )!;
      expect(result, isNot(contains('visible chunk')));
      expect(result, contains('hidden chunk'));
    });

    test('keeps chunks with empty messageIds when window is set', () {
      final payload = _payloadWith(
        chunks: [
          const RecalledMessageChunk(text: 'no-provenance chunk'),
          const RecalledMessageChunk(text: 'visible chunk', messageIds: ['m1']),
        ],
        sourceWindowVisibleMessageIds: {'m1'},
      );
      final result = effectiveRecalledMessagesContent(payload)!;
      expect(result, contains('no-provenance chunk'));
      expect(result, isNot(contains('visible chunk')));
    });

    test('returns null when all chunks are filtered out by visible window', () {
      final payload = _payloadWith(
        chunks: [
          const RecalledMessageChunk(text: 'chunk a', messageIds: ['m1']),
        ],
        sourceWindowVisibleMessageIds: {'m1'},
      );
      expect(effectiveRecalledMessagesContent(payload), isNull);
    });

    test('disableSourceWindowExclusion bypasses filtering', () {
      final payload = _payloadWith(
        chunks: [
          const RecalledMessageChunk(text: 'visible chunk', messageIds: ['m1']),
        ],
        sourceWindowVisibleMessageIds: {'m1'},
        disableSourceWindowExclusion: true,
      );
      final result = effectiveRecalledMessagesContent(payload)!;
      expect(result, contains('visible chunk'));
    });
  });
}
