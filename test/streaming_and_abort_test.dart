import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/bridge/chat_message_mapper.dart';

void main() {
  group('ChatMessageMapper - Payload Optimization', () {
    final context = ChatMessageMapperContext(
      currentCharName: 'Test Character',
      currentCharColor: '#FF5733',
      currentPersonaName: 'Test User',
      charAvatarDataUrl: 'data:image/png;base64,LARGE_AVATAR_DATA_HERE',
      personaAvatarDataUrl: 'data:image/png;base64,USER_AVATAR_DATA_HERE',
      isGenerating: false,
    );

    test('should not include avatarUrl in message payload', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello world',
      );

      final map = ChatMessageMapper.toMap(
        message,
        context,
        isStreamingUpdate: false,
      );

      expect(map.containsKey('avatarUrl'), isFalse);
    });

    test('should NOT include avatarUrl when isStreamingUpdate is true', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello world',
      );

      final map = ChatMessageMapper.toMap(
        message,
        context,
        isStreamingUpdate: true,
      );

      expect(map.containsKey('avatarUrl'), isFalse);
    });

    test('should not include persona avatarUrl in message payload', () {
      final message = ChatMessage(id: 'msg1', role: 'user', content: 'Hello');

      final map = ChatMessageMapper.toMap(
        message,
        context,
        isStreamingUpdate: false,
      );

      expect(map.containsKey('avatarUrl'), isFalse);
    });

    test(
      'should NOT include persona avatarUrl for user messages when streaming',
      () {
        final message = ChatMessage(id: 'msg1', role: 'user', content: 'Hello');

        final map = ChatMessageMapper.toMap(
          message,
          context,
          isStreamingUpdate: true,
        );

        expect(map.containsKey('avatarUrl'), isFalse);
      },
    );
  });

  group('ChatMessageMapper - Avatar Optimization', () {
    test('avatarUrl should be null when context has no avatar data', () {
      final contextNoAvatar = ChatMessageMapperContext(
        currentCharName: 'Test',
        isGenerating: false,
      );

      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
      );

      final map = ChatMessageMapper.toMap(message, contextNoAvatar);

      expect(map.containsKey('avatarUrl'), isFalse);
    });

    test('avatarColor should be included for assistant when present', () {
      final context = ChatMessageMapperContext(
        currentCharName: 'Test',
        currentCharColor: '#FF5733',
        isGenerating: false,
      );

      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['avatarColor'], equals('#FF5733'));
    });

    test('avatarColor should NOT be included for user messages', () {
      final context = ChatMessageMapperContext(
        currentCharName: 'Test',
        currentCharColor: '#FF5733',
        currentPersonaName: 'User',
        isGenerating: false,
      );

      final message = ChatMessage(id: 'msg1', role: 'user', content: 'Hello');

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['avatarColor'], isNull);
    });
  });

  group('ChatMessageMapper - Basic Fields', () {
    final context = ChatMessageMapperContext(
      currentCharName: 'Char',
      currentPersonaName: 'User',
      isGenerating: false,
    );

    test('should include all basic fields', () {
      final message = ChatMessage(
        id: 'msg123',
        role: 'assistant',
        content: 'Test message',
        timestamp: 1234567890,
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['id'], equals('msg123'));
      expect(map['role'], equals('assistant'));
      expect(map['text'], equals('Test message'));
      expect(map['timestamp'], equals(1234567890));
      expect(map['isAssistant'], isTrue);
      expect(map['isUser'], isFalse);
    });

    test('should set isUser=true for user messages', () {
      final message = ChatMessage(id: 'msg1', role: 'user', content: 'Hello');

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['isUser'], isTrue);
      expect(map['isAssistant'], isFalse);
    });

    test('should use currentCharName for assistant displayName', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['displayName'], equals('Char'));
    });

    test('should use currentPersonaName for user displayName', () {
      final message = ChatMessage(id: 'msg1', role: 'user', content: 'Hello');

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['displayName'], equals('User'));
    });

    test('should ignore legacy default You personaName for user messages', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'user',
        content: 'Hello',
        personaName: 'You',
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['displayName'], equals('User'));
      expect(map.containsKey('personaName'), isFalse);
    });
  });

  group('ChatMessageMapper - Optional Fields', () {
    final context = ChatMessageMapperContext(isGenerating: false);

    test('should include swipes when present', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
        swipes: ['Response 1', 'Response 2', 'Response 3'],
        swipeId: 1,
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['swipeTotal'], equals(3));
      expect(map['swipeIndex'], equals(1));
    });

    test('should include genTime when present', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
        genTime: '2.5s',
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['genTime'], equals('2.5s'));
    });

    test('should include tokens when present', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
        tokens: 150,
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['tokens'], equals(150));
    });

    test('should include reasoning when present', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
        reasoning: 'Thinking process...',
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['reasoning'], equals('Thinking process...'));
    });

    test('should include isTyping when true', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
        isTyping: true,
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['isTyping'], isTrue);
    });

    test('should NOT include isTyping when false', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
        isTyping: false,
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['isTyping'], isNull);
    });

    test('should include isError when true', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
        isError: true,
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['isError'], isTrue);
    });

    test('should NOT include isError when false', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
        isError: false,
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['isError'], isFalse);
    });
  });

  group('ChatMessageMapper - Special Flags', () {
    final context = ChatMessageMapperContext(isGenerating: false);

    test('should include isLast when true', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
      );

      final map = ChatMessageMapper.toMap(message, context, isLast: true);

      expect(map['isLast'], isTrue);
    });

    test('should NOT include isLast when false', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
      );

      final map = ChatMessageMapper.toMap(message, context, isLast: false);

      expect(map['isLast'], isNull);
    });

    test('should include messageIndex when provided', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
      );

      final map = ChatMessageMapper.toMap(message, context, messageIndex: 5);

      expect(map['messageIndex'], equals(5));
    });

    test('should NOT include messageIndex when null', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
      );

      final map = ChatMessageMapper.toMap(message, context, messageIndex: null);

      expect(map['messageIndex'], isNull);
    });

    test('should include isGenerating from context', () {
      final contextGenerating = ChatMessageMapperContext(isGenerating: true);

      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
      );

      final map = ChatMessageMapper.toMap(message, contextGenerating);

      expect(map['isGenerating'], isTrue);
    });

    test('keeps post-gen state separate from stream generation state', () {
      const postGenContext = ChatMessageMapperContext(
        isGenerating: false,
        isPostGenRunning: true,
      );
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
      );

      final map = ChatMessageMapper.toMap(message, postGenContext);

      expect(map['isGenerating'], isFalse);
      expect(map['isPostGenRunning'], isTrue);
    });
  });

  group('ChatMessageMapper - Memory Coverage', () {
    test('should include memoryStatus when present', () {
      final context = ChatMessageMapperContext(
        isGenerating: false,
        coveredMemoryIds: {'msg1'},
      );

      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
        memoryCoverage: {'status': 'covered'},
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['memoryStatus'], equals('MEM'));
    });

    test('should NOT include memoryStatus when empty', () {
      final context = ChatMessageMapperContext(isGenerating: false);

      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
        memoryCoverage: {},
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['memoryStatus'], isNull);
    });
  });

  group('ChatMessageMapper - Triggered Content', () {
    final context = ChatMessageMapperContext(isGenerating: false);

    test('should include triggeredLorebooks when present', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
        triggeredLorebooks: [
          TriggeredEntry(id: 'lb1', name: 'Book 1'),
          TriggeredEntry(id: 'lb2', name: 'Book 2'),
        ],
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['triggeredLorebooks'], isNotNull);
      expect(map['triggeredLorebooks'].length, equals(2));
    });

    test('should include triggeredMemories when present', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
        triggeredMemories: [TriggeredEntry(id: 'mem1', name: 'Memory 1')],
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map['triggeredMemories'], isNotNull);
      expect(map['triggeredMemories'].length, equals(1));
    });
  });

  group('ChatMessageMapper - Typing Indicator Fix', () {
    final context = ChatMessageMapperContext(isGenerating: true);

    test('isTyping should be properly preserved in output', () {
      final messageTyping = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
        isTyping: true,
      );

      final map = ChatMessageMapper.toMap(messageTyping, context);

      // Critical: isTyping must be present when true
      expect(map['isTyping'], isTrue);
    });

    test('should handle rapid isTyping state changes', () {
      final message1 = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello',
        isTyping: true,
      );

      final map1 = ChatMessageMapper.toMap(message1, context);
      expect(map1['isTyping'], isTrue);

      final message2 = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Hello world',
        isTyping: false,
      );

      final map2 = ChatMessageMapper.toMap(message2, context);
      expect(map2['isTyping'], isNull);
    });
  });

  group('ChatMessageMapper - Badge Data in Final Update', () {
    final context = ChatMessageMapperContext(
      currentCharName: 'Test Character',
      currentCharColor: '#FF5733',
      currentPersonaName: 'Test User',
      charAvatarDataUrl: 'data:image/png;base64,LARGE_AVATAR',
      personaAvatarDataUrl: 'data:image/png;base64,USER_AVATAR',
      isGenerating: false,
    );

    test(
      'final update includes all badge fields: genTime, tokens, triggeredLorebooks, triggeredMemories',
      () {
        final message = ChatMessage(
          id: 'msg1',
          role: 'assistant',
          content: 'Generated response',
          isTyping: false,
          genTime: '2.5s',
          tokens: 150,
          triggeredLorebooks: [
            TriggeredEntry(
              id: 'lb1',
              name: 'Character Lore',
              lorebookName: 'World Book',
              lorebookId: 'wb1',
              source: 'keyword',
            ),
          ],
          triggeredMemories: [
            TriggeredEntry(id: 'mem1', name: 'Past Event', source: 'keyword'),
          ],
        );

        final map = ChatMessageMapper.toMap(message, context);

        expect(map['genTime'], equals('2.5s'));
        expect(map['tokens'], equals(150));
        expect(map['isTyping'], isNull);

        final lbList = map['triggeredLorebooks'] as List;
        expect(lbList.length, equals(1));
        final lbJson = lbList.first as Map<String, dynamic>;
        expect(lbJson['id'], equals('lb1'));
        expect(lbJson['name'], equals('Character Lore'));
        expect(lbJson['lorebookName'], equals('World Book'));
        expect(lbJson['lorebookId'], equals('wb1'));
        expect(lbJson['source'], equals('keyword'));

        final memList = map['triggeredMemories'] as List;
        expect(memList.length, equals(1));
        final memJson = memList.first as Map<String, dynamic>;
        expect(memJson['id'], equals('mem1'));
        expect(memJson['name'], equals('Past Event'));
        expect(memJson['lorebookName'], equals(''));
        expect(memJson['source'], equals('keyword'));
      },
    );

    test('streaming update includes badge data but excludes avatarUrl', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Partial...',
        isTyping: true,
        genTime: null,
        tokens: null,
        triggeredLorebooks: [TriggeredEntry(id: 'lb1', name: 'Lore Entry')],
        triggeredMemories: [],
      );

      final map = ChatMessageMapper.toMap(
        message,
        context,
        isStreamingUpdate: true,
      );

      expect(map.containsKey('avatarUrl'), isFalse);
      expect(map['genTime'], isNull);
      expect(map['tokens'], isNull);
      expect(map['isTyping'], isTrue);
      expect(map['triggeredLorebooks'], isNotNull);
      expect((map['triggeredLorebooks'] as List).length, equals(1));
      expect(map.containsKey('triggeredMemories'), isFalse);
    });

    test(
      'genTime and tokens reflect current generation, not stale swipe data',
      () {
        final previousSwipeMessage = ChatMessage(
          id: 'msg1',
          role: 'assistant',
          content: 'Old swipe text',
          genTime: '10.0s',
          tokens: 500,
          swipes: ['Old swipe text'],
          swipeId: 0,
        );

        final newGeneration = previousSwipeMessage.copyWith(
          content: 'New generation',
          genTime: '1.2s',
          tokens: 42,
          isTyping: false,
          swipeId: 1,
        );

        final oldMap = ChatMessageMapper.toMap(previousSwipeMessage, context);
        expect(oldMap['genTime'], equals('10.0s'));
        expect(oldMap['tokens'], equals(500));
        expect(oldMap['swipeIndex'], equals(0));

        final newMap = ChatMessageMapper.toMap(newGeneration, context);
        expect(newMap['genTime'], equals('1.2s'));
        expect(newMap['tokens'], equals(42));
        expect(newMap['swipeIndex'], equals(1));
      },
    );

    test('TriggeredEntry toJson roundtrip', () {
      const entry = TriggeredEntry(
        id: 'entry1',
        name: 'Test Entry',
        lorebookName: 'Test Book',
        lorebookId: 'book1',
        source: 'vector',
      );

      final json = entry.toJson();
      expect(json['id'], equals('entry1'));
      expect(json['name'], equals('Test Entry'));
      expect(json['lorebookName'], equals('Test Book'));
      expect(json['lorebookId'], equals('book1'));
      expect(json['source'], equals('vector'));

      final restored = TriggeredEntry.fromJson(json);
      expect(restored.id, equals('entry1'));
      expect(restored.name, equals('Test Entry'));
      expect(restored.source, equals('vector'));
    });

    test('no badges rendered when all badge fields absent', () {
      final message = ChatMessage(
        id: 'msg1',
        role: 'assistant',
        content: 'Plain text',
      );

      final map = ChatMessageMapper.toMap(message, context);

      expect(map.containsKey('genTime'), isFalse);
      expect(map.containsKey('tokens'), isFalse);
      expect(map.containsKey('triggeredLorebooks'), isFalse);
      expect(map.containsKey('triggeredMemories'), isFalse);
      expect(map.containsKey('memoryStatus'), isFalse);
    });
  });
}
