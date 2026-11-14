import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/memory_provenance_key_builder.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';

void main() {
  group('MemoryProvenanceKeyBuilder (Track 1.3)', () {
    test('uses session.id for both sessionId and branchId', () {
      final key = MemoryProvenanceKeyBuilder.build(
        sessionId: 'char1_0',
        settings: const MemoryGlobalSettings(),
        book: null,
        history: const [],
      );
      expect(key.sessionId, 'char1_0');
      expect(key.branchId, 'char1_0');
    });

    test('uses regenTargetId as anchor for regen', () {
      final history = [
        ChatMessage(id: 'msg1', role: 'user', content: 'hello'),
      ];
      final key = MemoryProvenanceKeyBuilder.build(
        sessionId: 's1',
        regenTargetId: 'assistant_msg',
        previousSwipeId: 2,
        settings: const MemoryGlobalSettings(),
        book: null,
        history: history,
      );
      expect(key.anchorMessageId, 'assistant_msg');
      expect(key.anchorSwipeId, 2);
    });

    test('uses last history message as anchor for new gen', () {
      final history = [
        ChatMessage(id: 'msg1', role: 'user', content: 'hello'),
        ChatMessage(id: 'msg2', role: 'assistant', content: 'hi', swipeId: 1),
      ];
      final key = MemoryProvenanceKeyBuilder.build(
        sessionId: 's1',
        settings: const MemoryGlobalSettings(),
        book: null,
        history: history,
      );
      expect(key.anchorMessageId, 'msg2');
      expect(key.anchorSwipeId, 1);
    });

    test('uses book.updatedAt for memoryRevision', () {
      final book = MemoryBook(
        id: 'mb1',
        sessionId: 's1',
        updatedAt: 12345,
      );
      final key = MemoryProvenanceKeyBuilder.build(
        sessionId: 's1',
        settings: const MemoryGlobalSettings(),
        book: book,
        history: const [],
      );
      expect(key.memoryRevision, '12345');
    });

    test('historyRevision includes length, last id, and swipeId', () {
      final history = [
        ChatMessage(id: 'msg1', role: 'user', content: 'hello'),
        ChatMessage(id: 'msg2', role: 'assistant', content: 'hi', swipeId: 3),
      ];
      final key = MemoryProvenanceKeyBuilder.build(
        sessionId: 's1',
        settings: const MemoryGlobalSettings(),
        book: null,
        history: history,
      );
      expect(key.historyRevision, '2:msg2:3');
    });

    test('empty history produces stable default revision', () {
      final key = MemoryProvenanceKeyBuilder.build(
        sessionId: 's1',
        settings: const MemoryGlobalSettings(),
        book: null,
        history: const [],
      );
      expect(key.historyRevision, '0');
      expect(key.anchorMessageId, 's1');
      expect(key.anchorSwipeId, 0);
    });

    test('different settings produce different settingsRevision', () {
      final key1 = MemoryProvenanceKeyBuilder.build(
        sessionId: 's1',
        settings: const MemoryGlobalSettings(memoryMode: 'fast'),
        book: null,
        history: const [],
      );
      final key2 = MemoryProvenanceKeyBuilder.build(
        sessionId: 's1',
        settings: const MemoryGlobalSettings(memoryMode: 'deep'),
        book: null,
        history: const [],
      );
      expect(key1.settingsRevision, isNot(equals(key2.settingsRevision)));
    });
  });
}
